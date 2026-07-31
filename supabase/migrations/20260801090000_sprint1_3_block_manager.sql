-- Explora Booking
-- Sprint 1.3: Gestor de bloques de planificación
-- Archivo: 20260801090000_sprint1_3_block_manager.sql

begin;

create index if not exists idx_departures_schedule_status_starts_at
  on public.departures(schedule_id, status, starts_at)
  where schedule_id is not null;

create index if not exists idx_schedule_resources_primary
  on public.schedule_resources(schedule_id, is_primary);

create or replace view public.schedule_block_manager
with (security_invoker = true)
as
select
  s.id as schedule_id,
  s.experience_id,
  e.name as experience_name,
  e.code as experience_code,
  s.name as block_name,
  s.status,
  s.valid_from,
  s.valid_until,
  s.recurrence_type,
  s.weekdays,
  coalesce(
    (
      select array_agg(st.start_time order by st.display_order, st.start_time)
      from public.schedule_times st
      where st.schedule_id = s.id
        and st.is_active = true
    ),
    array[]::time without time zone[]
  ) as times,
  s.timezone,
  s.capacity_override,
  s.minimum_adults_override,
  s.default_guide_id,
  guide.resource_id as primary_guide_resource_id,
  guide.resource_name as primary_guide_name,
  coalesce(stats.departure_count, 0)::integer as departure_count,
  coalesce(stats.future_departure_count, 0)::integer as future_departure_count,
  coalesce(stats.completed_departure_count, 0)::integer as completed_departure_count,
  coalesce(stats.cancelled_departure_count, 0)::integer as cancelled_departure_count,
  stats.first_departure_at,
  stats.last_departure_at,
  s.created_at,
  s.updated_at
from public.schedules s
join public.experiences e on e.id = s.experience_id
left join lateral (
  select r.id as resource_id, r.name as resource_name
  from public.schedule_resources sr
  join public.resources r on r.id = sr.resource_id
  where sr.schedule_id = s.id
    and r.kind = 'guide'::public.resource_kind
  order by sr.is_primary desc, sr.created_at, r.name
  limit 1
) guide on true
left join lateral (
  select
    count(*)::integer as departure_count,
    count(*) filter (
      where d.starts_at >= now()
        and d.status not in (
          'cancelled'::public.departure_status,
          'completed'::public.departure_status
        )
    )::integer as future_departure_count,
    count(*) filter (
      where d.status = 'completed'::public.departure_status
    )::integer as completed_departure_count,
    count(*) filter (
      where d.status = 'cancelled'::public.departure_status
    )::integer as cancelled_departure_count,
    min(d.starts_at) as first_departure_at,
    max(d.starts_at) as last_departure_at
  from public.departures d
  where d.schedule_id = s.id
) stats on true;

grant select on public.schedule_block_manager to authenticated;

create or replace function public.get_schedule_blocks(
  p_status public.schedule_status default null,
  p_experience_id uuid default null,
  p_include_archived boolean default false
)
returns setof public.schedule_block_manager
language sql
stable
security invoker
set search_path = public
as $$
  select b.*
  from public.schedule_block_manager b
  where (p_status is null or b.status = p_status)
    and (p_experience_id is null or b.experience_id = p_experience_id)
    and (p_include_archived or b.status <> 'archived'::public.schedule_status)
  order by
    case b.status
      when 'active'::public.schedule_status then 1
      when 'draft'::public.schedule_status then 2
      when 'paused'::public.schedule_status then 3
      else 4
    end,
    b.valid_from desc,
    b.block_name;
$$;

revoke all on function public.get_schedule_blocks(
  public.schedule_status, uuid, boolean
) from public, anon;
grant execute on function public.get_schedule_blocks(
  public.schedule_status, uuid, boolean
) to authenticated;

create or replace function public.update_schedule_block(
  p_schedule_id uuid,
  p_name text,
  p_valid_from date,
  p_valid_until date,
  p_weekdays smallint[],
  p_times time without time zone[],
  p_capacity integer default null,
  p_minimum_adults integer default null,
  p_guide_profile_id uuid default null
)
returns public.schedule_block_manager
language plpgsql
security definer
set search_path = public
as $$
declare
  v_schedule public.schedules%rowtype;
  v_resource_id uuid;
  v_result public.schedule_block_manager%rowtype;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para editar bloques';
  end if;

  select * into v_schedule
  from public.schedules
  where id = p_schedule_id
  for update;

  if not found then
    raise exception 'Bloque de planificación no encontrado';
  end if;

  if v_schedule.status = 'archived'::public.schedule_status then
    raise exception 'Un bloque archivado no se puede editar';
  end if;

  if p_valid_from is null or p_valid_until is null or p_valid_from > p_valid_until then
    raise exception 'El periodo del bloque no es válido';
  end if;

  if coalesce(cardinality(p_weekdays), 0) = 0
     or not (p_weekdays <@ array[1,2,3,4,5,6,7]::smallint[]) then
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

  if p_capacity is not null
     and p_minimum_adults is not null
     and p_minimum_adults > p_capacity then
    raise exception 'El mínimo de adultos no puede superar la capacidad';
  end if;

  if p_guide_profile_id is not null then
    select r.id into v_resource_id
    from public.resources r
    where r.profile_id = p_guide_profile_id
      and r.kind = 'guide'::public.resource_kind
      and r.status = 'active'::public.resource_status
    limit 1;

    if v_resource_id is null then
      raise exception 'La guía seleccionada no está disponible como recurso activo';
    end if;
  end if;

  update public.schedules
  set
    name = coalesce(nullif(trim(p_name), ''), name),
    valid_from = p_valid_from,
    valid_until = p_valid_until,
    recurrence_type = 'weekly'::public.recurrence_type,
    weekdays = p_weekdays,
    specific_dates = array[]::date[],
    capacity_override = p_capacity,
    minimum_adults_override = p_minimum_adults,
    default_guide_id = p_guide_profile_id,
    updated_by = auth.uid()
  where id = p_schedule_id;

  delete from public.schedule_times
  where schedule_id = p_schedule_id;

  insert into public.schedule_times (
    schedule_id, start_time, display_order, is_active, created_by, updated_by
  )
  select
    p_schedule_id,
    item.start_time,
    row_number() over (order by item.start_time)::integer - 1,
    true,
    auth.uid(),
    auth.uid()
  from (
    select distinct unnest(p_times) as start_time
  ) item
  order by item.start_time;

  delete from public.schedule_resources
  where schedule_id = p_schedule_id
    and resource_id in (
      select r.id
      from public.resources r
      where r.kind = 'guide'::public.resource_kind
    );

  if v_resource_id is not null then
    insert into public.schedule_resources (
      schedule_id, resource_id, is_primary, created_by
    )
    values (
      p_schedule_id, v_resource_id, true, auth.uid()
    );
  end if;

  select * into v_result
  from public.schedule_block_manager b
  where b.schedule_id = p_schedule_id;

  return v_result;
end;
$$;

revoke all on function public.update_schedule_block(
  uuid, text, date, date, smallint[], time without time zone[],
  integer, integer, uuid
) from public, anon;
grant execute on function public.update_schedule_block(
  uuid, text, date, date, smallint[], time without time zone[],
  integer, integer, uuid
) to authenticated;

create or replace function public.duplicate_schedule_block(
  p_schedule_id uuid,
  p_name text default null,
  p_valid_from date default null,
  p_valid_until date default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_source public.schedules%rowtype;
  v_new_id uuid;
  v_from date;
  v_until date;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para duplicar bloques';
  end if;

  select * into v_source
  from public.schedules
  where id = p_schedule_id;

  if not found then
    raise exception 'Bloque de planificación no encontrado';
  end if;

  v_from := coalesce(p_valid_from, v_source.valid_from);
  v_until := coalesce(p_valid_until, v_source.valid_until);

  if v_from > v_until then
    raise exception 'El periodo del nuevo bloque no es válido';
  end if;

  insert into public.schedules (
    experience_id, name, status, valid_from, valid_until,
    recurrence_type, weekdays, specific_dates, timezone,
    capacity_override, minimum_adults_override,
    booking_cutoff_if_minimum_not_met_minutes_override,
    booking_cutoff_if_minimum_met_minutes_override,
    waitlist_enabled_override, internal_notes, default_guide_id,
    created_by, updated_by
  )
  values (
    v_source.experience_id,
    coalesce(nullif(trim(p_name), ''), v_source.name || ' · Copia'),
    'draft'::public.schedule_status,
    v_from,
    v_until,
    v_source.recurrence_type,
    v_source.weekdays,
    v_source.specific_dates,
    v_source.timezone,
    v_source.capacity_override,
    v_source.minimum_adults_override,
    v_source.booking_cutoff_if_minimum_not_met_minutes_override,
    v_source.booking_cutoff_if_minimum_met_minutes_override,
    v_source.waitlist_enabled_override,
    v_source.internal_notes,
    v_source.default_guide_id,
    auth.uid(),
    auth.uid()
  )
  returning id into v_new_id;

  insert into public.schedule_times (
    schedule_id, start_time, display_order, is_active, created_by, updated_by
  )
  select
    v_new_id, st.start_time, st.display_order, st.is_active, auth.uid(), auth.uid()
  from public.schedule_times st
  where st.schedule_id = p_schedule_id;

  insert into public.schedule_resources (
    schedule_id, resource_id, is_primary, created_by
  )
  select
    v_new_id, sr.resource_id, sr.is_primary, auth.uid()
  from public.schedule_resources sr
  where sr.schedule_id = p_schedule_id;

  return v_new_id;
end;
$$;

revoke all on function public.duplicate_schedule_block(
  uuid, text, date, date
) from public, anon;
grant execute on function public.duplicate_schedule_block(
  uuid, text, date, date
) to authenticated;

create or replace function public.archive_schedule_block(
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
    raise exception 'No autorizado para archivar bloques';
  end if;

  update public.schedules
  set
    status = 'archived'::public.schedule_status,
    updated_by = auth.uid()
  where id = p_schedule_id
    and status <> 'archived'::public.schedule_status;

  return found;
end;
$$;

revoke all on function public.archive_schedule_block(uuid) from public, anon;
grant execute on function public.archive_schedule_block(uuid) to authenticated;

create or replace function public.restore_schedule_block(
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
    raise exception 'No autorizado para reactivar bloques';
  end if;

  update public.schedules
  set
    status = 'draft'::public.schedule_status,
    updated_by = auth.uid()
  where id = p_schedule_id
    and status in (
      'archived'::public.schedule_status,
      'paused'::public.schedule_status
    );

  return found;
end;
$$;

revoke all on function public.restore_schedule_block(uuid) from public, anon;
grant execute on function public.restore_schedule_block(uuid) to authenticated;

create or replace function public.regenerate_schedule_block(
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
    raise exception 'No autorizado para regenerar bloques';
  end if;

  select * into v_schedule
  from public.schedules
  where id = p_schedule_id
  for update;

  if not found then
    raise exception 'Bloque de planificación no encontrado';
  end if;

  if v_schedule.status = 'archived'::public.schedule_status then
    raise exception 'Un bloque archivado no se puede regenerar';
  end if;

  update public.schedules
  set
    status = 'active'::public.schedule_status,
    updated_by = auth.uid()
  where id = p_schedule_id;

  select * into v_result
  from public.run_schedule_generation(
    p_schedule_id,
    v_schedule.valid_from,
    v_schedule.valid_until,
    'only_new'::public.generation_mode
  );

  return query
  select
    v_result.generation_run_id,
    v_result.candidate_count,
    v_result.inserted_count,
    v_result.skipped_existing_count,
    v_result.conflict_count,
    v_result.status;
end;
$$;

revoke all on function public.regenerate_schedule_block(uuid) from public, anon;
grant execute on function public.regenerate_schedule_block(uuid) to authenticated;

commit;
