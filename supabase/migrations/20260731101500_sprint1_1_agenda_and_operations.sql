-- Explora Booking
-- Sprint 1.1: separación entre Agenda y Operativa por producto
-- Fecha: 2026-07-31
-- Mantiene compatibilidad con Sprint 1.

begin;

do $$
begin
  if not exists (
    select 1 from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'departure_kind' and n.nspname = 'public'
  ) then
    create type public.departure_kind as enum (
      'commercial',
      'private_group',
      'school',
      'agency',
      'private_tour',
      'meeting',
      'travel',
      'blocked',
      'personal',
      'other'
    );
  end if;

  if not exists (
    select 1 from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'departure_source' and n.nspname = 'public'
  ) then
    create type public.departure_source as enum (
      'schedule',
      'manual',
      'reservation',
      'external'
    );
  end if;

  if not exists (
    select 1 from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'publication_status' and n.nspname = 'public'
  ) then
    create type public.publication_status as enum (
      'public',
      'internal',
      'hidden'
    );
  end if;
end
$$;

alter table public.departures
  add column if not exists kind public.departure_kind not null default 'commercial';

alter table public.departures
  add column if not exists source public.departure_source not null default 'manual';

alter table public.departures
  add column if not exists publication public.publication_status not null default 'public';

update public.departures
set
  source = case when schedule_id is null then 'manual'::public.departure_source
                else 'schedule'::public.departure_source end,
  publication = case when is_public then 'public'::public.publication_status
                     else 'internal'::public.publication_status end
where true;

create index if not exists idx_departures_agenda
  on public.departures(kind, starts_at, occupied_capacity);

create index if not exists idx_departures_operational
  on public.departures(experience_id, starts_at, status);

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
  where d.starts_at >= p_from
    and d.starts_at < p_until
    and d.status <> 'cancelled'::public.departure_status
    and (
      d.kind <> 'commercial'::public.departure_kind
      or d.occupied_capacity > 0
    )
  order by d.starts_at, e.name;
$$;

revoke all on function public.list_agenda_departures(timestamptz, timestamptz)
from public, anon;
grant execute on function public.list_agenda_departures(timestamptz, timestamptz)
to authenticated;

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
  where d.starts_at >= p_from
    and d.starts_at < p_until
    and d.kind = 'commercial'::public.departure_kind
    and (p_experience_id is null or d.experience_id = p_experience_id)
  order by d.starts_at, e.name;
$$;

revoke all on function public.list_operational_departures(timestamptz, timestamptz, uuid)
from public, anon;
grant execute on function public.list_operational_departures(timestamptz, timestamptz, uuid)
to authenticated;

commit;
