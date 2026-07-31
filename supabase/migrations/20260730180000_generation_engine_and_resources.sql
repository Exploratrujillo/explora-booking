-- Explora Booking
-- Entregable 3: motor de generación inteligente y control de recursos
-- Fecha: 2026-07-30
-- Archivo: 20260730180000_generation_engine_and_resources.sql
--
-- Dependencias:
--   20260730114350_initial_explora_booking_schema.sql
--   20260730150000_schedules_and_departures.sql
--
-- Objetivos:
--   1) registrar cada ejecución del generador;
--   2) detectar conflictos antes de crear salidas;
--   3) permitir varias salidas simultáneas con recursos diferentes;
--   4) exigir inicialmente 150 minutos entre inicios para una misma guía;
--   5) preparar recursos futuros: guías, vehículos, equipos y espacios;
--   6) mantener compatibilidad con departures.guide_id;
--   7) no generar salidas automáticamente al aplicar la migración.

begin;

-- =========================================================
-- 1. TIPOS
-- =========================================================

do $$
begin
  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'resource_kind'
      and n.nspname = 'public'
  ) then
    create type public.resource_kind as enum (
      'guide',
      'vehicle',
      'equipment',
      'venue',
      'other'
    );
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'resource_status'
      and n.nspname = 'public'
  ) then
    create type public.resource_status as enum (
      'active',
      'inactive',
      'archived'
    );
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'generation_mode'
      and n.nspname = 'public'
  ) then
    create type public.generation_mode as enum (
      'preview',
      'only_new',
      'update_unbooked',
      'force'
    );
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'generation_run_status'
      and n.nspname = 'public'
  ) then
    create type public.generation_run_status as enum (
      'running',
      'completed',
      'completed_with_conflicts',
      'failed'
    );
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'generation_conflict_type'
      and n.nspname = 'public'
  ) then
    create type public.generation_conflict_type as enum (
      'existing_departure',
      'resource_conflict',
      'overlapping_schedule',
      'protected_departure',
      'invalid_configuration'
    );
  end if;
end
$$;

-- =========================================================
-- 2. AJUSTES DE PERFILES Y PROGRAMACIONES
-- =========================================================

alter table public.profiles
  add column if not exists minimum_start_gap_minutes integer
  not null default 150;

alter table public.profiles
  drop constraint if exists profiles_minimum_start_gap_valid;

alter table public.profiles
  add constraint profiles_minimum_start_gap_valid
  check (minimum_start_gap_minutes >= 0);

comment on column public.profiles.minimum_start_gap_minutes is
  'Separación mínima entre el inicio de dos visitas asignadas a esta guía. Valor inicial: 150 minutos.';

alter table public.schedules
  add column if not exists default_guide_id uuid
  references public.profiles(id) on delete set null;

comment on column public.schedules.default_guide_id is
  'Guía predeterminada para las nuevas salidas. Puede quedar vacía y asignarse después.';

create index if not exists idx_schedules_default_guide
  on public.schedules(default_guide_id);

-- Campos de control y anulación expresa en salidas.
alter table public.departures
  add column if not exists conflict_override boolean
  not null default false;

alter table public.departures
  add column if not exists conflict_override_reason text;

alter table public.departures
  add column if not exists conflict_override_by uuid
  references public.profiles(id) on delete set null;

alter table public.departures
  add column if not exists conflict_override_at timestamptz;

alter table public.departures
  drop constraint if exists departures_conflict_override_reason_required;

alter table public.departures
  add constraint departures_conflict_override_reason_required
  check (
    conflict_override = false
    or length(trim(coalesce(conflict_override_reason, ''))) >= 10
  );

-- =========================================================
-- 3. RECURSOS
-- =========================================================

create table if not exists public.resources (
  id uuid primary key default gen_random_uuid(),

  kind public.resource_kind not null,
  name text not null,
  status public.resource_status not null default 'active',

  -- Solo para recursos de tipo guía vinculados a un usuario.
  profile_id uuid references public.profiles(id) on delete set null,

  -- Separación entre inicios. Una guía comienza con 150 minutos.
  minimum_start_gap_minutes integer not null default 0,

  internal_notes text,

  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint resources_name_not_blank
    check (length(trim(name)) > 0),

  constraint resources_gap_valid
    check (minimum_start_gap_minutes >= 0),

  constraint resources_profile_only_for_guide
    check (profile_id is null or kind = 'guide')
);

comment on table public.resources is
  'Recursos asignables a salidas: guías, vehículos, equipos, espacios u otros.';

create unique index if not exists uq_resources_guide_profile
  on public.resources(profile_id)
  where profile_id is not null and kind = 'guide';

create index if not exists idx_resources_kind_status
  on public.resources(kind, status);

drop trigger if exists trg_resources_set_updated_at on public.resources;
create trigger trg_resources_set_updated_at
before update on public.resources
for each row execute function public.set_updated_at();

-- Recursos que una programación asignará por defecto.
create table if not exists public.schedule_resources (
  id uuid primary key default gen_random_uuid(),

  schedule_id uuid not null
    references public.schedules(id) on delete cascade,

  resource_id uuid not null
    references public.resources(id) on delete restrict,

  is_primary boolean not null default false,

  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),

  constraint schedule_resources_unique
    unique (schedule_id, resource_id)
);

comment on table public.schedule_resources is
  'Recursos predeterminados que se copiarán a las salidas generadas por una programación.';

create index if not exists idx_schedule_resources_schedule
  on public.schedule_resources(schedule_id);

-- Recursos realmente asignados a una salida.
create table if not exists public.departure_resources (
  id uuid primary key default gen_random_uuid(),

  departure_id uuid not null
    references public.departures(id) on delete cascade,

  resource_id uuid not null
    references public.resources(id) on delete restrict,

  is_primary boolean not null default false,

  conflict_override boolean not null default false,
  conflict_override_reason text,
  conflict_override_by uuid references public.profiles(id) on delete set null,
  conflict_override_at timestamptz,

  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),

  constraint departure_resources_unique
    unique (departure_id, resource_id),

  constraint departure_resources_override_reason_required
    check (
      conflict_override = false
      or length(trim(coalesce(conflict_override_reason, ''))) >= 10
    )
);

comment on table public.departure_resources is
  'Recursos asignados a una salida. La comprobación de conflictos se realiza por recurso.';

create index if not exists idx_departure_resources_resource
  on public.departure_resources(resource_id, departure_id);

create index if not exists idx_departure_resources_departure
  on public.departure_resources(departure_id);

-- =========================================================
-- 4. HISTORIAL DE GENERACIÓN
-- =========================================================

create table if not exists public.generation_runs (
  id uuid primary key default gen_random_uuid(),

  schedule_id uuid not null
    references public.schedules(id) on delete restrict,

  requested_by uuid references public.profiles(id) on delete set null,

  mode public.generation_mode not null,
  status public.generation_run_status not null default 'running',

  requested_from date not null,
  requested_until date not null,

  candidate_count integer not null default 0,
  inserted_count integer not null default 0,
  updated_count integer not null default 0,
  skipped_existing_count integer not null default 0,
  conflict_count integer not null default 0,
  error_count integer not null default 0,

  started_at timestamptz not null default now(),
  finished_at timestamptz,
  duration_ms integer,

  error_message text,
  metadata jsonb not null default '{}'::jsonb,

  constraint generation_runs_dates_valid
    check (requested_from <= requested_until),

  constraint generation_runs_counts_valid
    check (
      candidate_count >= 0
      and inserted_count >= 0
      and updated_count >= 0
      and skipped_existing_count >= 0
      and conflict_count >= 0
      and error_count >= 0
    ),

  constraint generation_runs_duration_valid
    check (duration_ms is null or duration_ms >= 0)
);

comment on table public.generation_runs is
  'Historial de vistas previas y generaciones ejecutadas desde el backoffice.';

create index if not exists idx_generation_runs_schedule_started
  on public.generation_runs(schedule_id, started_at desc);

create index if not exists idx_generation_runs_status
  on public.generation_runs(status, started_at desc);

create table if not exists public.generation_conflicts (
  id uuid primary key default gen_random_uuid(),

  generation_run_id uuid not null
    references public.generation_runs(id) on delete cascade,

  conflict_type public.generation_conflict_type not null,

  candidate_starts_at timestamptz,
  experience_id uuid references public.experiences(id) on delete set null,
  resource_id uuid references public.resources(id) on delete set null,
  conflicting_departure_id uuid references public.departures(id) on delete set null,

  message text not null,
  details jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default now(),

  constraint generation_conflicts_message_not_blank
    check (length(trim(message)) > 0)
);

comment on table public.generation_conflicts is
  'Detalle de conflictos detectados durante una ejecución del generador.';

create index if not exists idx_generation_conflicts_run
  on public.generation_conflicts(generation_run_id);

-- =========================================================
-- 5. CREACIÓN AUTOMÁTICA DE RECURSOS-GUÍA
-- =========================================================

create or replace function public.ensure_guide_resource_for_profile()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.is_active = true
     and new.role in (
       'owner'::public.app_role,
       'admin'::public.app_role,
       'manager'::public.app_role,
       'guide'::public.app_role
     )
  then
    insert into public.resources (
      kind,
      name,
      status,
      profile_id,
      minimum_start_gap_minutes,
      created_by,
      updated_by
    )
    values (
      'guide'::public.resource_kind,
      coalesce(nullif(trim(new.full_name), ''), new.email),
      'active'::public.resource_status,
      new.id,
      new.minimum_start_gap_minutes,
      new.id,
      new.id
    )
    on conflict (profile_id) where profile_id is not null and kind = 'guide'
    do update set
      name = excluded.name,
      status = excluded.status,
      minimum_start_gap_minutes = excluded.minimum_start_gap_minutes,
      updated_at = now();
  else
    update public.resources
    set
      status = 'inactive'::public.resource_status,
      updated_at = now()
    where profile_id = new.id
      and kind = 'guide'::public.resource_kind;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_profiles_ensure_guide_resource on public.profiles;
create trigger trg_profiles_ensure_guide_resource
after insert or update of full_name, email, role, is_active, minimum_start_gap_minutes
on public.profiles
for each row execute function public.ensure_guide_resource_for_profile();

-- Crea recursos para perfiles existentes.
insert into public.resources (
  kind,
  name,
  status,
  profile_id,
  minimum_start_gap_minutes,
  created_by,
  updated_by
)
select
  'guide'::public.resource_kind,
  coalesce(nullif(trim(p.full_name), ''), p.email),
  case
    when p.is_active then 'active'::public.resource_status
    else 'inactive'::public.resource_status
  end,
  p.id,
  p.minimum_start_gap_minutes,
  p.id,
  p.id
from public.profiles p
where p.role in (
  'owner'::public.app_role,
  'admin'::public.app_role,
  'manager'::public.app_role,
  'guide'::public.app_role
)
on conflict (profile_id) where profile_id is not null and kind = 'guide'
do update set
  name = excluded.name,
  status = excluded.status,
  minimum_start_gap_minutes = excluded.minimum_start_gap_minutes,
  updated_at = now();

-- Si existe exactamente un perfil operativo activo, se usa como guía
-- predeterminada de la programación inicial.
update public.schedules s
set
  default_guide_id = (
    select p.id
    from public.profiles p
    where p.is_active = true
      and p.role in (
        'owner'::public.app_role,
        'admin'::public.app_role,
        'manager'::public.app_role,
        'guide'::public.app_role
      )
    order by
      case p.role
        when 'owner'::public.app_role then 1
        when 'admin'::public.app_role then 2
        when 'manager'::public.app_role then 3
        else 4
      end,
      p.created_at
    limit 1
  )
where s.name = 'Operativa inicial 2026'
  and s.default_guide_id is null
  and 1 = (
    select count(*)
    from public.profiles p
    where p.is_active = true
      and p.role in (
        'owner'::public.app_role,
        'admin'::public.app_role,
        'manager'::public.app_role,
        'guide'::public.app_role
      )
  );

-- Copia la guía predeterminada a schedule_resources.
insert into public.schedule_resources (
  schedule_id,
  resource_id,
  is_primary,
  created_by
)
select
  s.id,
  r.id,
  true,
  s.default_guide_id
from public.schedules s
join public.resources r
  on r.profile_id = s.default_guide_id
 and r.kind = 'guide'::public.resource_kind
where s.default_guide_id is not null
on conflict (schedule_id, resource_id) do update
set is_primary = true;

-- =========================================================
-- 6. DETECCIÓN DE CONFLICTOS
-- =========================================================

create or replace function public.find_resource_conflicts(
  p_resource_id uuid,
  p_starts_at timestamptz,
  p_exclude_departure_id uuid default null
)
returns table (
  conflicting_departure_id uuid,
  conflicting_starts_at timestamptz,
  conflicting_experience_id uuid,
  conflicting_experience_name text,
  gap_minutes integer,
  required_gap_minutes integer
)
language sql
stable
security invoker
set search_path = public
as $$
  select
    d.id,
    d.starts_at,
    d.experience_id,
    e.name,
    abs(extract(epoch from (d.starts_at - p_starts_at)) / 60)::integer,
    r.minimum_start_gap_minutes
  from public.resources r
  join public.departure_resources dr
    on dr.resource_id = r.id
  join public.departures d
    on d.id = dr.departure_id
  join public.experiences e
    on e.id = d.experience_id
  where r.id = p_resource_id
    and r.status = 'active'::public.resource_status
    and (p_exclude_departure_id is null or d.id <> p_exclude_departure_id)
    and d.status not in (
      'cancelled'::public.departure_status,
      'completed'::public.departure_status
    )
    and abs(extract(epoch from (d.starts_at - p_starts_at)) / 60)
        < r.minimum_start_gap_minutes
  order by d.starts_at;
$$;

comment on function public.find_resource_conflicts(uuid, timestamptz, uuid) is
  'Detecta salidas del mismo recurso cuyo inicio está separado por menos del margen configurado.';

create or replace function public.prevent_departure_resource_conflict()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_departure public.departures%rowtype;
  v_resource public.resources%rowtype;
  v_conflict record;
begin
  select *
  into v_departure
  from public.departures
  where id = new.departure_id;

  select *
  into v_resource
  from public.resources
  where id = new.resource_id;

  if not found then
    raise exception 'Recurso no encontrado: %', new.resource_id;
  end if;

  select *
  into v_conflict
  from public.find_resource_conflicts(
    new.resource_id,
    v_departure.starts_at,
    new.departure_id
  )
  limit 1;

  if v_conflict.conflicting_departure_id is not null then
    if new.conflict_override = false then
      raise exception using
        errcode = '23514',
        message = format(
          'Conflicto de recurso: %s ya está asignado a %s a las %s. Separación: %s min; mínimo requerido: %s min.',
          v_resource.name,
          v_conflict.conflicting_experience_name,
          v_conflict.conflicting_starts_at,
          v_conflict.gap_minutes,
          v_conflict.required_gap_minutes
        );
    end if;

    if not public.current_user_has_role(
      array['owner','admin']::public.app_role[]
    ) then
      raise exception 'Solo owner o admin pueden forzar un conflicto de recurso';
    end if;

    if length(trim(coalesce(new.conflict_override_reason, ''))) < 10 then
      raise exception 'Debe indicar un motivo de al menos 10 caracteres para forzar el conflicto';
    end if;

    new.conflict_override_by := auth.uid();
    new.conflict_override_at := now();
  else
    new.conflict_override := false;
    new.conflict_override_reason := null;
    new.conflict_override_by := null;
    new.conflict_override_at := null;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_prevent_departure_resource_conflict
  on public.departure_resources;

create trigger trg_prevent_departure_resource_conflict
before insert or update of departure_id, resource_id, conflict_override, conflict_override_reason
on public.departure_resources
for each row execute function public.prevent_departure_resource_conflict();

-- Si cambia la hora de una salida, vuelve a comprobar todos sus recursos.
create or replace function public.prevent_departure_time_conflict()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_assignment record;
  v_conflict record;
begin
  if new.starts_at is not distinct from old.starts_at then
    return new;
  end if;

  for v_assignment in
    select dr.*, r.name
    from public.departure_resources dr
    join public.resources r on r.id = dr.resource_id
    where dr.departure_id = new.id
  loop
    select *
    into v_conflict
    from public.find_resource_conflicts(
      v_assignment.resource_id,
      new.starts_at,
      new.id
    )
    limit 1;

    if v_conflict.conflicting_departure_id is not null
       and v_assignment.conflict_override = false
    then
      raise exception using
        errcode = '23514',
        message = format(
          'No se puede cambiar la hora: el recurso %s entra en conflicto con %s a las %s.',
          v_assignment.name,
          v_conflict.conflicting_experience_name,
          v_conflict.conflicting_starts_at
        );
    end if;
  end loop;

  return new;
end;
$$;

drop trigger if exists trg_prevent_departure_time_conflict
  on public.departures;

create trigger trg_prevent_departure_time_conflict
before update of starts_at
on public.departures
for each row execute function public.prevent_departure_time_conflict();

-- Mantiene guide_id para compatibilidad con el modelo ya creado.
create or replace function public.sync_departure_guide_from_resource()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile_id uuid;
begin
  if tg_op = 'DELETE' then
    select r.profile_id
    into v_profile_id
    from public.resources r
    where r.id = old.resource_id
      and r.kind = 'guide'::public.resource_kind;

    if v_profile_id is not null then
      update public.departures d
      set guide_id = (
        select r2.profile_id
        from public.departure_resources dr2
        join public.resources r2 on r2.id = dr2.resource_id
        where dr2.departure_id = old.departure_id
          and r2.kind = 'guide'::public.resource_kind
          and dr2.id <> old.id
        order by dr2.is_primary desc, dr2.created_at
        limit 1
      )
      where d.id = old.departure_id;
    end if;

    return old;
  end if;

  select r.profile_id
  into v_profile_id
  from public.resources r
  where r.id = new.resource_id
    and r.kind = 'guide'::public.resource_kind;

  if v_profile_id is not null and new.is_primary = true then
    update public.departures
    set guide_id = v_profile_id
    where id = new.departure_id;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_sync_departure_guide_from_resource
  on public.departure_resources;

create trigger trg_sync_departure_guide_from_resource
after insert or update or delete
on public.departure_resources
for each row execute function public.sync_departure_guide_from_resource();

-- =========================================================
-- 7. VISTA PREVIA ENRIQUECIDA
-- =========================================================

create or replace function public.preview_schedule_generation(
  p_schedule_id uuid,
  p_from date default null,
  p_until date default null
)
returns table (
  departure_date date,
  start_time time without time zone,
  starts_at timestamptz,
  source_kind text,
  capacity integer,
  minimum_adults integer,
  status public.departure_status,

  existing_departure_id uuid,
  is_existing boolean,

  primary_guide_resource_id uuid,
  primary_guide_name text,
  guide_assigned boolean,

  has_resource_conflict boolean,
  conflicting_departure_id uuid,
  conflict_message text,

  action_result text
)
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_candidate record;
  v_schedule public.schedules%rowtype;
  v_resource public.resources%rowtype;
  v_conflict record;
begin
  select *
  into v_schedule
  from public.schedules
  where id = p_schedule_id;

  if not found then
    raise exception 'Programación no encontrada: %', p_schedule_id;
  end if;

  select r.*
  into v_resource
  from public.schedule_resources sr
  join public.resources r on r.id = sr.resource_id
  where sr.schedule_id = p_schedule_id
    and r.kind = 'guide'::public.resource_kind
    and r.status = 'active'::public.resource_status
  order by sr.is_primary desc, sr.created_at
  limit 1;

  if v_resource.id is null and v_schedule.default_guide_id is not null then
    select r.*
    into v_resource
    from public.resources r
    where r.profile_id = v_schedule.default_guide_id
      and r.kind = 'guide'::public.resource_kind
      and r.status = 'active'::public.resource_status
    limit 1;
  end if;

  for v_candidate in
    select *
    from public.preview_schedule_departures(
      p_schedule_id,
      p_from,
      p_until
    )
    order by starts_at
  loop
    select d.id
    into existing_departure_id
    from public.departures d
    where d.experience_id = v_schedule.experience_id
      and d.starts_at = v_candidate.starts_at
    limit 1;

    is_existing := existing_departure_id is not null;

    primary_guide_resource_id := v_resource.id;
    primary_guide_name := v_resource.name;
    guide_assigned := v_resource.id is not null;

    has_resource_conflict := false;
    conflicting_departure_id := null;
    conflict_message := null;

    if not is_existing and v_resource.id is not null then
      select *
      into v_conflict
      from public.find_resource_conflicts(
        v_resource.id,
        v_candidate.starts_at,
        null
      )
      limit 1;

      if v_conflict.conflicting_departure_id is not null then
        has_resource_conflict := true;
        conflicting_departure_id := v_conflict.conflicting_departure_id;
        conflict_message := format(
          '%s entra en conflicto con %s: separación %s min, mínimo %s min.',
          v_resource.name,
          v_conflict.conflicting_experience_name,
          v_conflict.gap_minutes,
          v_conflict.required_gap_minutes
        );
      end if;
    end if;

    departure_date := v_candidate.departure_date;
    start_time := v_candidate.start_time;
    starts_at := v_candidate.starts_at;
    source_kind := v_candidate.source_kind;
    capacity := v_candidate.capacity;
    minimum_adults := v_candidate.minimum_adults;
    status := v_candidate.status;

    action_result := case
      when is_existing then 'existing'
      when has_resource_conflict then 'conflict'
      when not guide_assigned then 'new_unassigned'
      else 'new'
    end;

    return next;
  end loop;
end;
$$;

comment on function public.preview_schedule_generation(uuid, date, date) is
  'Vista previa enriquecida: existentes, guía asignada, conflictos y acción prevista.';

grant execute on function public.preview_schedule_generation(uuid, date, date)
  to authenticated;

-- =========================================================
-- 8. GENERADOR INTELIGENTE
-- =========================================================

create or replace function public.run_schedule_generation(
  p_schedule_id uuid,
  p_from date,
  p_until date,
  p_mode public.generation_mode default 'only_new'
)
returns table (
  generation_run_id uuid,
  candidate_count integer,
  inserted_count integer,
  updated_count integer,
  skipped_existing_count integer,
  conflict_count integer,
  status public.generation_run_status
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_run_id uuid;
  v_started_at timestamptz := clock_timestamp();
  v_schedule public.schedules%rowtype;
  v_experience public.experiences%rowtype;
  v_candidate record;
  v_departure_id uuid;
  v_inserted integer := 0;
  v_updated integer := 0;
  v_skipped integer := 0;
  v_conflicts integer := 0;
  v_candidates integer := 0;
  v_final_status public.generation_run_status;
  v_duration interval;
  v_resource record;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para ejecutar el generador';
  end if;

  if p_from is null or p_until is null or p_from > p_until then
    raise exception 'Periodo de generación no válido';
  end if;

  if p_mode in (
    'update_unbooked'::public.generation_mode,
    'force'::public.generation_mode
  ) then
    raise exception
      'El modo % se activará cuando exista el módulo de reservas. Por ahora use preview u only_new.',
      p_mode;
  end if;

  select *
  into v_schedule
  from public.schedules
  where id = p_schedule_id
  for update;

  if not found then
    raise exception 'Programación no encontrada: %', p_schedule_id;
  end if;

  if v_schedule.status <> 'active'::public.schedule_status then
    raise exception 'Solo se pueden procesar programaciones activas';
  end if;

  select *
  into v_experience
  from public.experiences
  where id = v_schedule.experience_id;

  insert into public.generation_runs (
    schedule_id,
    requested_by,
    mode,
    status,
    requested_from,
    requested_until,
    started_at
  )
  values (
    p_schedule_id,
    auth.uid(),
    p_mode,
    'running'::public.generation_run_status,
    p_from,
    p_until,
    v_started_at
  )
  returning id into v_run_id;

  for v_candidate in
    select *
    from public.preview_schedule_generation(
      p_schedule_id,
      p_from,
      p_until
    )
    order by starts_at
  loop
    v_candidates := v_candidates + 1;

    if v_candidate.is_existing then
      v_skipped := v_skipped + 1;

      insert into public.generation_conflicts (
        generation_run_id,
        conflict_type,
        candidate_starts_at,
        experience_id,
        conflicting_departure_id,
        message
      )
      values (
        v_run_id,
        'existing_departure'::public.generation_conflict_type,
        v_candidate.starts_at,
        v_schedule.experience_id,
        v_candidate.existing_departure_id,
        'La salida ya existe y se ha omitido.'
      );

      continue;
    end if;

    if v_candidate.has_resource_conflict then
      v_conflicts := v_conflicts + 1;

      insert into public.generation_conflicts (
        generation_run_id,
        conflict_type,
        candidate_starts_at,
        experience_id,
        resource_id,
        conflicting_departure_id,
        message
      )
      values (
        v_run_id,
        'resource_conflict'::public.generation_conflict_type,
        v_candidate.starts_at,
        v_schedule.experience_id,
        v_candidate.primary_guide_resource_id,
        v_candidate.conflicting_departure_id,
        v_candidate.conflict_message
      );

      continue;
    end if;

    if p_mode = 'preview'::public.generation_mode then
      continue;
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
      v_schedule.experience_id,
      v_schedule.id,
      v_candidate.starts_at,
      case
        when v_experience.duration_minutes is null then null
        else v_candidate.starts_at
          + make_interval(mins => v_experience.duration_minutes)
      end,
      v_candidate.status,
      true,
      v_candidate.capacity,
      v_candidate.minimum_adults,
      coalesce(
        v_schedule.booking_cutoff_if_minimum_not_met_minutes_override,
        v_experience.booking_cutoff_if_minimum_not_met_minutes
      ),
      coalesce(
        v_schedule.booking_cutoff_if_minimum_met_minutes_override,
        v_experience.booking_cutoff_if_minimum_met_minutes
      ),
      coalesce(
        v_schedule.waitlist_enabled_override,
        v_experience.waitlist_enabled
      ),
      v_schedule.default_guide_id,
      auth.uid(),
      auth.uid()
    )
    on conflict (experience_id, starts_at) do nothing
    returning id into v_departure_id;

    if v_departure_id is null then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    -- Copia todos los recursos predeterminados.
    for v_resource in
      select sr.resource_id, sr.is_primary
      from public.schedule_resources sr
      join public.resources r on r.id = sr.resource_id
      where sr.schedule_id = v_schedule.id
        and r.status = 'active'::public.resource_status
      order by sr.is_primary desc, sr.created_at
    loop
      insert into public.departure_resources (
        departure_id,
        resource_id,
        is_primary,
        created_by
      )
      values (
        v_departure_id,
        v_resource.resource_id,
        v_resource.is_primary,
        auth.uid()
      );
    end loop;

    v_inserted := v_inserted + 1;
    v_departure_id := null;
  end loop;

  v_final_status := case
    when v_conflicts > 0
      then 'completed_with_conflicts'::public.generation_run_status
    else 'completed'::public.generation_run_status
  end;

  update public.generation_runs
  set
    status = v_final_status,
    candidate_count = v_candidates,
    inserted_count = v_inserted,
    updated_count = v_updated,
    skipped_existing_count = v_skipped,
    conflict_count = v_conflicts,
    finished_at = clock_timestamp(),
    duration_ms = greatest(
      0,
      round(
        extract(epoch from (clock_timestamp() - v_started_at)) * 1000
      )::integer
    )
  where id = v_run_id;

  generation_run_id := v_run_id;
  candidate_count := v_candidates;
  inserted_count := v_inserted;
  updated_count := v_updated;
  skipped_existing_count := v_skipped;
  conflict_count := v_conflicts;
  status := v_final_status;

  return next;

exception
  when others then
    if v_run_id is not null then
      update public.generation_runs
      set
        status = 'failed'::public.generation_run_status,
        error_count = 1,
        error_message = sqlerrm,
        finished_at = clock_timestamp(),
        duration_ms = greatest(
          0,
          round(
            extract(epoch from (clock_timestamp() - v_started_at)) * 1000
          )::integer
        )
      where id = v_run_id;
    end if;

    raise;
end;
$$;

comment on function public.run_schedule_generation(uuid, date, date, public.generation_mode) is
  'Registra y ejecuta la vista previa o generación solo de nuevas salidas. Omite existentes y conflictos.';

revoke all on function public.run_schedule_generation(
  uuid,
  date,
  date,
  public.generation_mode
) from public, anon;

grant execute on function public.run_schedule_generation(
  uuid,
  date,
  date,
  public.generation_mode
) to authenticated;

-- =========================================================
-- 9. ESTADO DEL CALENDARIO
-- =========================================================

create or replace view public.schedule_generation_status
with (security_invoker = true)
as
select
  s.id as schedule_id,
  s.experience_id,
  e.code as experience_code,
  e.name as experience_name,
  s.name as schedule_name,
  s.status as schedule_status,
  s.valid_from,
  s.valid_until,

  max(gr.finished_at) filter (
    where gr.status in (
      'completed'::public.generation_run_status,
      'completed_with_conflicts'::public.generation_run_status
    )
  ) as last_generation_at,

  max(gr.requested_until) filter (
    where gr.mode = 'only_new'::public.generation_mode
      and gr.status in (
        'completed'::public.generation_run_status,
        'completed_with_conflicts'::public.generation_run_status
      )
  ) as generated_until,

  count(distinct d.id) as existing_departures,

  count(distinct gc.id) filter (
    where gc.conflict_type = 'resource_conflict'::public.generation_conflict_type
  ) as recorded_resource_conflicts,

  case
    when count(distinct d.id) = 0 then 'red'
    when max(gr.requested_until) filter (
      where gr.mode = 'only_new'::public.generation_mode
        and gr.status in (
          'completed'::public.generation_run_status,
          'completed_with_conflicts'::public.generation_run_status
        )
    ) >= s.valid_until
      and count(distinct gc.id) filter (
        where gc.conflict_type = 'resource_conflict'::public.generation_conflict_type
      ) = 0
      then 'green'
    when count(distinct gc.id) filter (
      where gc.conflict_type = 'resource_conflict'::public.generation_conflict_type
    ) > 0
      then 'warning'
    else 'yellow'
  end as calendar_indicator
from public.schedules s
join public.experiences e on e.id = s.experience_id
left join public.generation_runs gr on gr.schedule_id = s.id
left join public.generation_conflicts gc on gc.generation_run_id = gr.id
left join public.departures d on d.schedule_id = s.id
group by
  s.id,
  s.experience_id,
  e.code,
  e.name,
  s.name,
  s.status,
  s.valid_from,
  s.valid_until;

comment on view public.schedule_generation_status is
  'Resumen para el semáforo del backoffice: última generación, alcance, salidas y conflictos.';

grant select on public.schedule_generation_status to authenticated;

-- =========================================================
-- 10. AUDITORÍA
-- =========================================================

drop trigger if exists trg_audit_resources on public.resources;
create trigger trg_audit_resources
after insert or update or delete on public.resources
for each row execute function public.write_audit_log();

drop trigger if exists trg_audit_schedule_resources
  on public.schedule_resources;

create trigger trg_audit_schedule_resources
after insert or update or delete on public.schedule_resources
for each row execute function public.write_audit_log();

drop trigger if exists trg_audit_departure_resources
  on public.departure_resources;

create trigger trg_audit_departure_resources
after insert or update or delete on public.departure_resources
for each row execute function public.write_audit_log();

drop trigger if exists trg_audit_generation_runs
  on public.generation_runs;

create trigger trg_audit_generation_runs
after insert or update or delete on public.generation_runs
for each row execute function public.write_audit_log();

drop trigger if exists trg_audit_generation_conflicts
  on public.generation_conflicts;

create trigger trg_audit_generation_conflicts
after insert or update or delete on public.generation_conflicts
for each row execute function public.write_audit_log();

-- =========================================================
-- 11. RLS
-- =========================================================

alter table public.resources enable row level security;
alter table public.schedule_resources enable row level security;
alter table public.departure_resources enable row level security;
alter table public.generation_runs enable row level security;
alter table public.generation_conflicts enable row level security;

drop policy if exists resources_staff_read on public.resources;
create policy resources_staff_read
on public.resources
for select
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager','guide','viewer']::public.app_role[]
  )
);

drop policy if exists resources_management_write on public.resources;
create policy resources_management_write
on public.resources
for all
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  )
)
with check (
  public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  )
);

drop policy if exists schedule_resources_staff_read
  on public.schedule_resources;

create policy schedule_resources_staff_read
on public.schedule_resources
for select
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager','guide','viewer']::public.app_role[]
  )
);

drop policy if exists schedule_resources_management_write
  on public.schedule_resources;

create policy schedule_resources_management_write
on public.schedule_resources
for all
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  )
)
with check (
  public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  )
);

drop policy if exists departure_resources_staff_read
  on public.departure_resources;

create policy departure_resources_staff_read
on public.departure_resources
for select
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager','guide','viewer']::public.app_role[]
  )
);

drop policy if exists departure_resources_management_write
  on public.departure_resources;

create policy departure_resources_management_write
on public.departure_resources
for all
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  )
)
with check (
  public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  )
);

drop policy if exists generation_runs_staff_read
  on public.generation_runs;

create policy generation_runs_staff_read
on public.generation_runs
for select
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager','guide','viewer']::public.app_role[]
  )
);

drop policy if exists generation_runs_management_write
  on public.generation_runs;

create policy generation_runs_management_write
on public.generation_runs
for all
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  )
)
with check (
  public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  )
);

drop policy if exists generation_conflicts_staff_read
  on public.generation_conflicts;

create policy generation_conflicts_staff_read
on public.generation_conflicts
for select
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager','guide','viewer']::public.app_role[]
  )
);

drop policy if exists generation_conflicts_management_write
  on public.generation_conflicts;

create policy generation_conflicts_management_write
on public.generation_conflicts
for all
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  )
)
with check (
  public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  )
);

commit;
