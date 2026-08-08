-- Explora Booking
-- Arquitectura funcional v1
-- Migración F: Disponibilidad de recursos
-- Fecha: 2026-08-08
--
-- OBJETIVO
-- -------
-- Añadir disponibilidad/indisponibilidad al sistema de resources ya existente.
--
-- DECISIÓN DE ARQUITECTURA
-- -----------------------
-- No se crea ninguna tabla nueva de "colaboradores" ni de "proveedores operativos".
--
-- Motivo:
--   resources ya permite crear una guía con profile_id = NULL.
--   Eso cubre correctamente una guía externa que trabaja en una salida
--   pero no tiene usuario de acceso a Explora Booking.
--
-- VOCABULARIO RESERVADO
-- ---------------------
-- COLABORADORES:
--   hoteles, apartamentos, alojamientos, comercios, oficinas u otros negocios
--   que recomiendan/derivan clientes a Explora Trujillo.
--   Se modelarán en un módulo comercial específico posterior.
--
-- USUARIOS:
--   profiles, personas con acceso al sistema.
--
-- RECURSOS:
--   guías, vehículos, equipos, espacios u otros elementos asignables a salidas.
--
-- PRINCIPIOS
-- ----------
-- - No se duplica resources.
-- - No se duplica profiles.
-- - Una guía externa puede ser resources(kind='guide', profile_id=NULL).
-- - departure_resources sigue siendo la asignación real a una salida.
-- - Se reutiliza conflict_override para excepciones justificadas.
-- - Los costes imputables se modelarán en una migración posterior.
-- - Los colaboradores comerciales se modelarán en una migración posterior.

begin;


-- =========================================================
-- 1. TIPO DE MOTIVO DE INDISPONIBILIDAD
-- =========================================================

do $$
begin
  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'unavailability_reason'
      and n.nspname = 'public'
  ) then
    create type public.unavailability_reason as enum (
      'personal',
      'other_work',
      'holiday',
      'medical',
      'maintenance',
      'blocked',
      'other'
    );
  end if;
end
$$;


-- =========================================================
-- 2. INDISPONIBILIDAD DE RECURSOS
-- =========================================================
--
-- Se aplica a cualquier resource:
--   guide / vehicle / equipment / venue / other.
--
-- Puede representar unas horas, un día o varios días.

create table if not exists public.resource_unavailability (
  id uuid primary key default gen_random_uuid(),

  resource_id uuid not null
    references public.resources(id) on delete cascade,

  starts_at timestamptz not null,
  ends_at timestamptz not null,

  reason public.unavailability_reason not null default 'blocked',
  note text,

  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint resource_unavailability_valid_range
    check (ends_at > starts_at)
);

create index if not exists idx_resource_unavailability_resource_range
  on public.resource_unavailability(resource_id, starts_at, ends_at);

drop trigger if exists trg_resource_unavailability_set_updated_at
  on public.resource_unavailability;

create trigger trg_resource_unavailability_set_updated_at
before update on public.resource_unavailability
for each row execute function public.set_updated_at();

comment on table public.resource_unavailability is
  'Periodos en los que un recurso no está disponible para nuevas asignaciones.';


-- =========================================================
-- 3. CONSULTAR INDISPONIBILIDAD
-- =========================================================

create or replace function public.find_resource_unavailability_v1(
  p_resource_id uuid,
  p_starts_at timestamptz,
  p_ends_at timestamptz default null
)
returns table (
  unavailability_id uuid,
  unavailable_from timestamptz,
  unavailable_until timestamptz,
  reason public.unavailability_reason,
  note text
)
language sql
stable
security invoker
set search_path = public
as $$
  select
    u.id,
    u.starts_at,
    u.ends_at,
    u.reason,
    u.note
  from public.resource_unavailability u
  where u.resource_id = p_resource_id
    and tstzrange(
      u.starts_at,
      u.ends_at,
      '[)'
    ) && tstzrange(
      p_starts_at,
      coalesce(
        p_ends_at,
        p_starts_at + interval '1 minute'
      ),
      '[)'
    )
  order by u.starts_at;
$$;


-- =========================================================
-- 4. IMPEDIR ASIGNAR RECURSO NO DISPONIBLE
-- =========================================================
--
-- Si departure_resources.conflict_override = true, se permite
-- la excepción usando el mecanismo ya existente de justificación.

create or replace function public.prevent_unavailable_departure_resource_v1()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_departure public.departures%rowtype;
  v_unavailability record;
begin
  select *
  into v_departure
  from public.departures
  where id = new.departure_id;

  if not found then
    raise exception 'Salida no encontrada';
  end if;

  select *
  into v_unavailability
  from public.find_resource_unavailability_v1(
    new.resource_id,
    v_departure.starts_at,
    v_departure.ends_at
  )
  limit 1;

  if v_unavailability.unavailability_id is not null
     and coalesce(new.conflict_override, false) = false
  then
    raise exception using
      errcode = '23514',
      message = format(
        'El recurso no está disponible entre %s y %s',
        v_unavailability.unavailable_from,
        v_unavailability.unavailable_until
      );
  end if;

  return new;
end;
$$;

drop trigger if exists trg_prevent_unavailable_departure_resource
  on public.departure_resources;

create trigger trg_prevent_unavailable_departure_resource
before insert or update of departure_id, resource_id, conflict_override
on public.departure_resources
for each row execute function public.prevent_unavailable_departure_resource_v1();


-- =========================================================
-- 5. IMPEDIR MOVER UNA SALIDA A UN PERIODO NO DISPONIBLE
-- =========================================================

create or replace function public.prevent_departure_move_into_unavailability_v1()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_assignment record;
  v_unavailability record;
begin
  if new.starts_at is not distinct from old.starts_at
     and new.ends_at is not distinct from old.ends_at
  then
    return new;
  end if;

  for v_assignment in
    select dr.*
    from public.departure_resources dr
    where dr.departure_id = new.id
  loop
    select *
    into v_unavailability
    from public.find_resource_unavailability_v1(
      v_assignment.resource_id,
      new.starts_at,
      new.ends_at
    )
    limit 1;

    if v_unavailability.unavailability_id is not null
       and coalesce(v_assignment.conflict_override, false) = false
    then
      raise exception using
        errcode = '23514',
        message = format(
          'No se puede mover la salida: un recurso asignado no está disponible entre %s y %s',
          v_unavailability.unavailable_from,
          v_unavailability.unavailable_until
        );
    end if;
  end loop;

  return new;
end;
$$;

drop trigger if exists trg_prevent_departure_move_into_unavailability
  on public.departures;

create trigger trg_prevent_departure_move_into_unavailability
before update of starts_at, ends_at
on public.departures
for each row execute function public.prevent_departure_move_into_unavailability_v1();


-- =========================================================
-- 6. VISTA OPERATIVA
-- =========================================================

create or replace view public.resource_unavailability_v1
with (security_invoker = true)
as
select
  u.id as unavailability_id,
  u.resource_id,
  r.name as resource_name,
  r.kind as resource_kind,
  r.status as resource_status,

  u.starts_at,
  u.ends_at,
  u.reason,
  u.note,

  u.created_at,
  u.updated_at

from public.resource_unavailability u
join public.resources r
  on r.id = u.resource_id;

grant select on public.resource_unavailability_v1
to authenticated;


-- =========================================================
-- 7. RPC: CREAR BLOQUEO DE DISPONIBILIDAD
-- =========================================================

create or replace function public.create_resource_unavailability_v1(
  p_resource_id uuid,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_reason public.unavailability_reason default 'blocked',
  p_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para modificar disponibilidad';
  end if;

  if not exists (
    select 1
    from public.resources
    where id = p_resource_id
  ) then
    raise exception 'Recurso no encontrado';
  end if;

  if p_starts_at is null
     or p_ends_at is null
     or p_ends_at <= p_starts_at
  then
    raise exception 'El periodo de indisponibilidad no es válido';
  end if;

  insert into public.resource_unavailability (
    resource_id,
    starts_at,
    ends_at,
    reason,
    note,
    created_by,
    updated_by
  )
  values (
    p_resource_id,
    p_starts_at,
    p_ends_at,
    p_reason,
    nullif(trim(coalesce(p_note, '')), ''),
    auth.uid(),
    auth.uid()
  )
  returning id into v_id;

  return v_id;
end;
$$;


-- =========================================================
-- 8. RPC: ELIMINAR BLOQUEO DE DISPONIBILIDAD
-- =========================================================

create or replace function public.delete_resource_unavailability_v1(
  p_unavailability_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para modificar disponibilidad';
  end if;

  if not exists (
    select 1
    from public.resource_unavailability
    where id = p_unavailability_id
  ) then
    raise exception 'Bloqueo de disponibilidad no encontrado';
  end if;

  delete from public.resource_unavailability
  where id = p_unavailability_id;

  return p_unavailability_id;
end;
$$;


-- =========================================================
-- 9. AUDITORÍA
-- =========================================================

drop trigger if exists trg_audit_resource_unavailability
  on public.resource_unavailability;

create trigger trg_audit_resource_unavailability
after insert or update or delete on public.resource_unavailability
for each row execute function public.write_audit_log();


-- =========================================================
-- 10. RLS
-- =========================================================

alter table public.resource_unavailability enable row level security;

drop policy if exists resource_unavailability_staff_read
  on public.resource_unavailability;

create policy resource_unavailability_staff_read
on public.resource_unavailability
for select
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager','guide']::public.app_role[]
  )
);


-- =========================================================
-- 11. PERMISOS RPC
-- =========================================================

revoke all on function public.create_resource_unavailability_v1(
  uuid,
  timestamptz,
  timestamptz,
  public.unavailability_reason,
  text
) from public, anon;

grant execute on function public.create_resource_unavailability_v1(
  uuid,
  timestamptz,
  timestamptz,
  public.unavailability_reason,
  text
) to authenticated;


revoke all on function public.delete_resource_unavailability_v1(uuid)
from public, anon;

grant execute on function public.delete_resource_unavailability_v1(uuid)
to authenticated;


commit;
