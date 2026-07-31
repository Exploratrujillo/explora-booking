-- Explora Booking
-- Sprint 1.1.1: corrige permisos de las RPC de Agenda y Operativa
-- Mantiene el acceso a las tablas exclusivamente dentro de funciones SQL seguras.

begin;

create or replace function public.list_agenda_departures(
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
  occupied_capacity integer,
  adult_minimum_count integer,
  guide_profile_id uuid,
  guide_resource_id uuid,
  guide_name text,
  schedule_id uuid,
  is_manual boolean,
  conflict_override boolean,
  kind public.departure_kind,
  source public.departure_source,
  publication public.publication_status
)
language sql
stable
security definer
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
    d.occupied_capacity,
    d.adult_minimum_count,
    r.profile_id,
    r.id,
    r.name,
    d.schedule_id,
    (d.schedule_id is null),
    d.conflict_override,
    d.kind,
    d.source,
    d.publication
  from public.departures d
  join public.experiences e on e.id = d.experience_id
  left join lateral (
    select rr.id, rr.profile_id, rr.name
    from public.departure_resources dr
    join public.resources rr on rr.id = dr.resource_id
    where dr.departure_id = d.id
      and rr.kind = 'guide'::public.resource_kind
    order by dr.is_primary desc, dr.created_at
    limit 1
  ) r on true
  where public.current_user_has_role(
      array['owner','admin','manager','guide','viewer']::public.app_role[]
    )
    and d.starts_at >= p_from
    and d.starts_at < p_until
    and d.status <> 'cancelled'::public.departure_status
    and (
      d.kind <> 'commercial'::public.departure_kind
      or d.occupied_capacity > 0
    )
  order by d.starts_at, e.name;
$$;

create or replace function public.list_operational_departures(
  p_from timestamptz,
  p_until timestamptz,
  p_experience_id uuid default null
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
  occupied_capacity integer,
  adult_minimum_count integer,
  guide_profile_id uuid,
  guide_resource_id uuid,
  guide_name text,
  schedule_id uuid,
  is_manual boolean,
  conflict_override boolean,
  kind public.departure_kind,
  source public.departure_source,
  publication public.publication_status
)
language sql
stable
security definer
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
    d.occupied_capacity,
    d.adult_minimum_count,
    r.profile_id,
    r.id,
    r.name,
    d.schedule_id,
    (d.schedule_id is null),
    d.conflict_override,
    d.kind,
    d.source,
    d.publication
  from public.departures d
  join public.experiences e on e.id = d.experience_id
  left join lateral (
    select rr.id, rr.profile_id, rr.name
    from public.departure_resources dr
    join public.resources rr on rr.id = dr.resource_id
    where dr.departure_id = d.id
      and rr.kind = 'guide'::public.resource_kind
    order by dr.is_primary desc, dr.created_at
    limit 1
  ) r on true
  where public.current_user_has_role(
      array['owner','admin','manager','guide','viewer']::public.app_role[]
    )
    and d.starts_at >= p_from
    and d.starts_at < p_until
    and d.kind = 'commercial'::public.departure_kind
    and (p_experience_id is null or d.experience_id = p_experience_id)
  order by d.starts_at, e.name;
$$;

revoke all on function public.list_agenda_departures(timestamptz, timestamptz)
from public, anon;
grant execute on function public.list_agenda_departures(timestamptz, timestamptz)
to authenticated;

revoke all on function public.list_operational_departures(timestamptz, timestamptz, uuid)
from public, anon;
grant execute on function public.list_operational_departures(timestamptz, timestamptz, uuid)
to authenticated;

commit;
