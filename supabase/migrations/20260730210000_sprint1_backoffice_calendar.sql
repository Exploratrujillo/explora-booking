-- Explora Booking
-- Sprint 1 Backoffice: calendario operativo
-- Fecha: 2026-07-30
-- Archivo: 20260730210000_sprint1_backoffice_calendar.sql
--
-- Añade una API SQL segura para:
--   - consultar salidas por periodo;
--   - crear salidas manuales;
--   - mover salidas;
--   - cambiar su estado;
--   - asignar una guía;
--   - consultar experiencias y guías activas.
--
-- No crea salidas automáticamente.

begin;

-- =========================================================
-- 1. EXPERIENCIAS DISPONIBLES PARA EL BACKOFFICE
-- =========================================================

create or replace function public.list_backoffice_experiences()
returns table (
  id uuid,
  code text,
  name text,
  duration_minutes integer,
  default_capacity integer,
  minimum_adults integer
)
language sql
stable
security invoker
set search_path = public
as $$
  select
    e.id,
    e.code::text,
    e.name,
    e.duration_minutes,
    e.capacity,
    e.minimum_adults
  from public.experiences e
  where e.status = 'active'::public.experience_status
order by e.display_order, e.name;
$$;

revoke all on function public.list_backoffice_experiences()
from public, anon;

grant execute on function public.list_backoffice_experiences()
to authenticated;

-- =========================================================
-- 2. GUÍAS ACTIVAS
-- =========================================================

create or replace function public.list_active_guides()
returns table (
  resource_id uuid,
  profile_id uuid,
  name text,
  minimum_start_gap_minutes integer
)
language sql
stable
security invoker
set search_path = public
as $$
  select
    r.id,
    r.profile_id,
    r.name,
    r.minimum_start_gap_minutes
  from public.resources r
  where r.kind = 'guide'::public.resource_kind
    and r.status = 'active'::public.resource_status
  order by r.name;
$$;

revoke all on function public.list_active_guides()
from public, anon;

grant execute on function public.list_active_guides()
to authenticated;

-- =========================================================
-- 3. CONSULTA DEL CALENDARIO
-- =========================================================

create or replace function public.list_calendar_departures(
  p_from timestamptz,
  p_until timestamptz
)
returns table (
  id uuid,
  experience_id uuid,
  experience_code text,
  experience_name text,
  starts_at timestamptz,
  ends_at timestamptz,
  status public.departure_status,
  is_public boolean,
  capacity integer,
  minimum_adults integer,
  guide_profile_id uuid,
  guide_resource_id uuid,
  guide_name text,
  schedule_id uuid,
  is_manual boolean,
  conflict_override boolean
)
language sql
stable
security invoker
set search_path = public
as $$
  select
    d.id,
    d.experience_id,
    e.code::text,
    e.name,
    d.starts_at,
    d.ends_at,
    d.status,
    d.is_public,
    d.capacity,
    d.minimum_adults,
    r.profile_id,
    r.id,
    r.name,
    d.schedule_id,
    (d.schedule_id is null),
    d.conflict_override
  from public.departures d
  join public.experiences e
    on e.id = d.experience_id
  left join lateral (
    select
      rr.id,
      rr.profile_id,
      rr.name
    from public.departure_resources dr
    join public.resources rr
      on rr.id = dr.resource_id
    where dr.departure_id = d.id
      and rr.kind = 'guide'::public.resource_kind
    order by dr.is_primary desc, dr.created_at
    limit 1
  ) r on true
  where d.starts_at >= p_from
    and d.starts_at < p_until
  order by d.starts_at, e.name;
$$;

revoke all on function public.list_calendar_departures(
  timestamptz,
  timestamptz
) from public, anon;

grant execute on function public.list_calendar_departures(
  timestamptz,
  timestamptz
) to authenticated;

-- =========================================================
-- 4. CREAR UNA SALIDA MANUAL
-- =========================================================

create or replace function public.create_manual_departure(
  p_experience_id uuid,
  p_starts_at timestamptz,
  p_guide_profile_id uuid default null,
  p_capacity integer default null,
  p_minimum_adults integer default null,
  p_is_public boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_experience public.experiences%rowtype;
  v_departure_id uuid;
  v_resource_id uuid;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para crear salidas';
  end if;

  if p_starts_at is null then
    raise exception 'La fecha y hora son obligatorias';
  end if;

  select *
  into v_experience
  from public.experiences
  where id = p_experience_id
    and status = 'active'::public.experience_status;

  if not found then
    raise exception 'Experiencia no encontrada o no activa';
  end if;

  if coalesce(p_capacity, v_experience.capacity) <= 0 then
    raise exception 'La capacidad debe ser mayor que cero';
  end if;

  if coalesce(p_minimum_adults, v_experience.minimum_adults, 0) < 0 then
    raise exception 'El mínimo de adultos no puede ser negativo';
  end if;

  insert into public.departures (
    experience_id,
    schedule_id,
    starts_at,
    ends_at,
    status,
    is_public,
    capacity,
    minimum_adults,
    booking_cutoff_if_minimum_not_met_minutes,
    booking_cutoff_if_minimum_met_minutes,
    waitlist_enabled,
    guide_id,
    created_by,
    updated_by
  )
  values (
    v_experience.id,
    null,
    p_starts_at,
    case
      when v_experience.duration_minutes is null then null
      else p_starts_at
        + make_interval(mins => v_experience.duration_minutes)
    end,
    'scheduled'::public.departure_status,
    p_is_public,
    coalesce(p_capacity, v_experience.capacity),
    coalesce(p_minimum_adults, v_experience.minimum_adults, 0),
    v_experience.booking_cutoff_if_minimum_not_met_minutes,
    v_experience.booking_cutoff_if_minimum_met_minutes,
    v_experience.waitlist_enabled,
    p_guide_profile_id,
    auth.uid(),
    auth.uid()
  )
  returning id into v_departure_id;

  if p_guide_profile_id is not null then
    select r.id
    into v_resource_id
    from public.resources r
    where r.profile_id = p_guide_profile_id
      and r.kind = 'guide'::public.resource_kind
      and r.status = 'active'::public.resource_status
    limit 1;

    if v_resource_id is null then
      raise exception 'La guía seleccionada no tiene un recurso activo';
    end if;

    insert into public.departure_resources (
      departure_id,
      resource_id,
      is_primary,
      created_by
    )
    values (
      v_departure_id,
      v_resource_id,
      true,
      auth.uid()
    );
  end if;

  return v_departure_id;
end;
$$;

revoke all on function public.create_manual_departure(
  uuid,
  timestamptz,
  uuid,
  integer,
  integer,
  boolean
) from public, anon;

grant execute on function public.create_manual_departure(
  uuid,
  timestamptz,
  uuid,
  integer,
  integer,
  boolean
) to authenticated;

-- =========================================================
-- 5. CAMBIAR ESTADO
-- =========================================================

create or replace function public.set_departure_status(
  p_departure_id uuid,
  p_status text
)
returns public.departures
language plpgsql
security definer
set search_path = public
as $$
declare
  v_departure public.departures;
  v_status public.departure_status;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para cambiar el estado';
  end if;

  begin
    v_status := p_status::public.departure_status;
  exception
    when invalid_text_representation then
      raise exception 'Estado de salida no válido: %', p_status;
  end;

  update public.departures
  set
    status = v_status,
    updated_by = auth.uid()
  where id = p_departure_id
  returning * into v_departure;

  if v_departure.id is null then
    raise exception 'Salida no encontrada';
  end if;

  return v_departure;
end;
$$;

revoke all on function public.set_departure_status(uuid, text)
from public, anon;

grant execute on function public.set_departure_status(uuid, text)
to authenticated;

-- =========================================================
-- 6. MOVER UNA SALIDA
-- =========================================================

create or replace function public.move_departure(
  p_departure_id uuid,
  p_starts_at timestamptz
)
returns public.departures
language plpgsql
security definer
set search_path = public
as $$
declare
  v_departure public.departures;
  v_duration integer;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para mover salidas';
  end if;

  select e.duration_minutes
  into v_duration
  from public.departures d
  join public.experiences e on e.id = d.experience_id
  where d.id = p_departure_id;

  if not found then
    raise exception 'Salida no encontrada';
  end if;

  update public.departures
  set
    starts_at = p_starts_at,
    ends_at = case
      when v_duration is null then null
      else p_starts_at + make_interval(mins => v_duration)
    end,
    updated_by = auth.uid()
  where id = p_departure_id
  returning * into v_departure;

  return v_departure;
end;
$$;

revoke all on function public.move_departure(uuid, timestamptz)
from public, anon;

grant execute on function public.move_departure(uuid, timestamptz)
to authenticated;

-- =========================================================
-- 7. ASIGNAR O CAMBIAR GUÍA
-- =========================================================

create or replace function public.assign_departure_guide(
  p_departure_id uuid,
  p_guide_profile_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resource_id uuid;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para asignar guías';
  end if;

  if not exists (
    select 1
    from public.departures
    where id = p_departure_id
  ) then
    raise exception 'Salida no encontrada';
  end if;

  select r.id
  into v_resource_id
  from public.resources r
  where r.profile_id = p_guide_profile_id
    and r.kind = 'guide'::public.resource_kind
    and r.status = 'active'::public.resource_status
  limit 1;

  if v_resource_id is null then
    raise exception 'La guía seleccionada no tiene un recurso activo';
  end if;

  delete from public.departure_resources dr
  using public.resources r
  where dr.departure_id = p_departure_id
    and r.id = dr.resource_id
    and r.kind = 'guide'::public.resource_kind;

  insert into public.departure_resources (
    departure_id,
    resource_id,
    is_primary,
    created_by
  )
  values (
    p_departure_id,
    v_resource_id,
    true,
    auth.uid()
  );

  update public.departures
  set
    guide_id = p_guide_profile_id,
    updated_by = auth.uid()
  where id = p_departure_id;

  return v_resource_id;
end;
$$;

revoke all on function public.assign_departure_guide(uuid, uuid)
from public, anon;

grant execute on function public.assign_departure_guide(uuid, uuid)
to authenticated;

commit;
