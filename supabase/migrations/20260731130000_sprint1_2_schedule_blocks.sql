-- Explora Booking
-- Sprint 1.2: creación y generación de salidas por bloques

begin;

-- Mantiene automáticamente la clasificación de las salidas según su origen.
create or replace function public.sync_departure_classification()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.schedule_id is not null then
    new.source := 'schedule'::public.departure_source;
  elsif new.source is null then
    new.source := 'manual'::public.departure_source;
  end if;

  new.publication := case
    when new.is_public then 'public'::public.publication_status
    else 'internal'::public.publication_status
  end;

  return new;
end;
$$;

drop trigger if exists trg_sync_departure_classification on public.departures;
create trigger trg_sync_departure_classification
before insert or update of schedule_id, is_public, source
on public.departures
for each row execute function public.sync_departure_classification();

-- Crea un bloque en borrador y devuelve la vista previa de lo que generará.
create or replace function public.create_schedule_block_draft(
  p_experience_id uuid,
  p_name text,
  p_valid_from date,
  p_valid_until date,
  p_weekdays smallint[],
  p_times time without time zone[],
  p_capacity integer default null,
  p_minimum_adults integer default null,
  p_guide_profile_id uuid default null
)
returns table (
  schedule_id uuid,
  candidate_count integer,
  existing_count integer,
  conflict_count integer,
  first_start timestamptz,
  last_start timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_schedule_id uuid;
  v_resource_id uuid;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para crear bloques de planificación';
  end if;

  if p_experience_id is null then
    raise exception 'Debe seleccionar una experiencia';
  end if;

  if not exists (
    select 1 from public.experiences e
    where e.id = p_experience_id
      and e.status <> 'archived'::public.experience_status
  ) then
    raise exception 'La experiencia seleccionada no existe o está archivada';
  end if;

  if p_valid_from is null or p_valid_until is null or p_valid_from > p_valid_until then
    raise exception 'El periodo del bloque no es válido';
  end if;

  if coalesce(cardinality(p_weekdays), 0) = 0 then
    raise exception 'Debe seleccionar al menos un día de la semana';
  end if;

  if not (p_weekdays <@ array[1,2,3,4,5,6,7]::smallint[]) then
    raise exception 'Los días de la semana no son válidos';
  end if;

  if coalesce(cardinality(p_times), 0) = 0 then
    raise exception 'Debe indicar al menos una hora';
  end if;

  if p_capacity is not null and p_capacity <= 0 then
    raise exception 'La capacidad debe ser mayor que cero';
  end if;

  if p_minimum_adults is not null and p_minimum_adults < 0 then
    raise exception 'El mínimo de adultos no puede ser negativo';
  end if;

  if p_capacity is not null and p_minimum_adults is not null
     and p_minimum_adults > p_capacity then
    raise exception 'El mínimo de adultos no puede superar la capacidad';
  end if;

  insert into public.schedules (
    experience_id,
    name,
    status,
    valid_from,
    valid_until,
    recurrence_type,
    weekdays,
    capacity_override,
    minimum_adults_override,
    default_guide_id,
    created_by,
    updated_by
  )
  values (
    p_experience_id,
    coalesce(nullif(trim(p_name), ''), 'Bloque de planificación'),
    'draft'::public.schedule_status,
    p_valid_from,
    p_valid_until,
    'weekly'::public.recurrence_type,
    p_weekdays,
    p_capacity,
    p_minimum_adults,
    p_guide_profile_id,
    auth.uid(),
    auth.uid()
  )
  returning id into v_schedule_id;

  insert into public.schedule_times (
    schedule_id,
    start_time,
    display_order,
    is_active,
    created_by,
    updated_by
  )
  select
    v_schedule_id,
    t.start_time,
    row_number() over (order by t.start_time)::integer - 1,
    true,
    auth.uid(),
    auth.uid()
  from (
    select distinct unnest(p_times) as start_time
  ) t
  order by t.start_time;

  if p_guide_profile_id is not null then
    select r.id
    into v_resource_id
    from public.resources r
    where r.profile_id = p_guide_profile_id
      and r.kind = 'guide'::public.resource_kind
      and r.status = 'active'::public.resource_status
    limit 1;

    if v_resource_id is null then
      raise exception 'La guía seleccionada no está disponible como recurso activo';
    end if;

    insert into public.schedule_resources (
      schedule_id,
      resource_id,
      is_primary,
      created_by
    )
    values (
      v_schedule_id,
      v_resource_id,
      true,
      auth.uid()
    )
    on conflict (schedule_id, resource_id) do update
      set is_primary = true;
  end if;

  return query
  select
    v_schedule_id,
    count(*)::integer,
    count(*) filter (where p.is_existing)::integer,
    count(*) filter (where p.has_resource_conflict)::integer,
    min(p.starts_at),
    max(p.starts_at)
  from public.preview_schedule_generation(
    v_schedule_id,
    p_valid_from,
    p_valid_until
  ) p;
end;
$$;

-- Activa el bloque y genera únicamente las salidas que todavía no existen.
create or replace function public.activate_and_generate_schedule_block(
  p_schedule_id uuid
)
returns table (
  generation_run_id uuid,
  candidate_count integer,
  inserted_count integer,
  skipped_existing_count integer,
  conflict_count integer,
  generation_status public.generation_run_status
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_schedule public.schedules%rowtype;
  v_result record;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para generar salidas';
  end if;

  select * into v_schedule
  from public.schedules
  where id = p_schedule_id
  for update;

  if not found then
    raise exception 'Bloque de planificación no encontrado';
  end if;

  if v_schedule.status not in (
    'draft'::public.schedule_status,
    'active'::public.schedule_status
  ) then
    raise exception 'Este bloque no se puede generar en su estado actual';
  end if;

  update public.schedules
  set status = 'active'::public.schedule_status,
      updated_by = auth.uid()
  where id = p_schedule_id;

  select * into v_result
  from public.run_schedule_generation(
    p_schedule_id,
    v_schedule.valid_from,
    v_schedule.valid_until,
    'only_new'::public.generation_mode
  );

  return query select
    v_result.generation_run_id,
    v_result.candidate_count,
    v_result.inserted_count,
    v_result.skipped_existing_count,
    v_result.conflict_count,
    v_result.status;
end;
$$;

-- Elimina un borrador que el usuario decidió no confirmar.
create or replace function public.discard_schedule_block_draft(
  p_schedule_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para descartar bloques';
  end if;

  delete from public.schedules s
  where s.id = p_schedule_id
    and s.status = 'draft'::public.schedule_status
    and not exists (
      select 1 from public.departures d where d.schedule_id = s.id
    );

  return found;
end;
$$;

revoke all on function public.create_schedule_block_draft(
  uuid, text, date, date, smallint[], time without time zone[], integer, integer, uuid
) from public, anon;
grant execute on function public.create_schedule_block_draft(
  uuid, text, date, date, smallint[], time without time zone[], integer, integer, uuid
) to authenticated;

revoke all on function public.activate_and_generate_schedule_block(uuid)
from public, anon;
grant execute on function public.activate_and_generate_schedule_block(uuid)
to authenticated;

revoke all on function public.discard_schedule_block_draft(uuid)
from public, anon;
grant execute on function public.discard_schedule_block_draft(uuid)
to authenticated;

commit;
