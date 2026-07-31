-- Explora Booking
-- Sprint 1.2.2: corrección de referencia ambigua schedule_id

begin;

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
    on conflict on constraint schedule_resources_unique do update
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


commit;
