-- Explora Booking
-- Entregable 2: motor de programaciones y salidas
-- Fecha: 2026-07-30
-- Archivo: 20260730150000_schedules_and_departures.sql
-- Dependencia: 20260730114350_initial_explora_booking_schema.sql

begin;

-- =========================================================
-- 1. TIPOS ENUMERADOS
-- =========================================================

do $$
begin
  if not exists (
    select 1 from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'schedule_status' and n.nspname = 'public'
  ) then
    create type public.schedule_status as enum ('draft','active','paused','archived');
  end if;

  if not exists (
    select 1 from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'recurrence_type' and n.nspname = 'public'
  ) then
    create type public.recurrence_type as enum ('daily','weekly','specific_dates');
  end if;

  if not exists (
    select 1 from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'schedule_exception_action' and n.nspname = 'public'
  ) then
    create type public.schedule_exception_action as enum ('skip','add','override');
  end if;

  if not exists (
    select 1 from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'departure_status' and n.nspname = 'public'
  ) then
    create type public.departure_status as enum ('scheduled','full','closed','cancelled','completed');
  end if;
end
$$;

-- =========================================================
-- 2. PROGRAMACIONES
-- =========================================================

create table if not exists public.schedules (
  id uuid primary key default gen_random_uuid(),
  experience_id uuid not null references public.experiences(id) on delete cascade,
  name text not null,
  status public.schedule_status not null default 'draft',
  valid_from date not null,
  valid_until date not null,
  recurrence_type public.recurrence_type not null default 'weekly',
  weekdays smallint[] not null default array[]::smallint[],
  specific_dates date[] not null default array[]::date[],
  timezone text not null default 'Europe/Madrid',
  capacity_override integer,
  minimum_adults_override integer,
  booking_cutoff_if_minimum_not_met_minutes_override integer,
  booking_cutoff_if_minimum_met_minutes_override integer,
  waitlist_enabled_override boolean,
  internal_notes text,
  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint schedules_name_not_blank check (length(trim(name)) > 0),
  constraint schedules_dates_valid check (valid_from <= valid_until),
  constraint schedules_capacity_override_valid check (capacity_override is null or capacity_override > 0),
  constraint schedules_minimum_adults_override_valid check (minimum_adults_override is null or minimum_adults_override >= 0),
  constraint schedules_minimum_within_capacity check (
    capacity_override is null or minimum_adults_override is null or minimum_adults_override <= capacity_override
  ),
  constraint schedules_cutoff_not_met_override_valid check (
    booking_cutoff_if_minimum_not_met_minutes_override is null
    or booking_cutoff_if_minimum_not_met_minutes_override >= 0
  ),
  constraint schedules_cutoff_met_override_valid check (
    booking_cutoff_if_minimum_met_minutes_override is null
    or booking_cutoff_if_minimum_met_minutes_override >= 0
  ),
  constraint schedules_weekdays_values_valid check (
    weekdays <@ array[1,2,3,4,5,6,7]::smallint[]
  ),
  constraint schedules_recurrence_configuration_valid check (
    (recurrence_type = 'daily' and cardinality(weekdays) = 0 and cardinality(specific_dates) = 0)
    or
    (recurrence_type = 'weekly' and cardinality(weekdays) > 0 and cardinality(specific_dates) = 0)
    or
    (recurrence_type = 'specific_dates' and cardinality(weekdays) = 0 and cardinality(specific_dates) > 0)
  )
);

comment on table public.schedules is
  'Reglas editables que describen cuándo opera una experiencia. No son salidas reales.';
comment on column public.schedules.weekdays is
  'Días ISO para recurrencia semanal: lunes=1 y domingo=7.';
comment on column public.schedules.capacity_override is
  'Si es null, las nuevas salidas heredan la capacidad de la experiencia.';

drop trigger if exists trg_schedules_set_updated_at on public.schedules;
create trigger trg_schedules_set_updated_at
before update on public.schedules
for each row execute function public.set_updated_at();

create index if not exists idx_schedules_experience on public.schedules(experience_id);
create index if not exists idx_schedules_status_period on public.schedules(status, valid_from, valid_until);

-- =========================================================
-- 3. HORARIOS DE CADA PROGRAMACIÓN
-- =========================================================

create table if not exists public.schedule_times (
  id uuid primary key default gen_random_uuid(),
  schedule_id uuid not null references public.schedules(id) on delete cascade,
  start_time time without time zone not null,
  display_order integer not null default 0,
  is_active boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint schedule_times_unique unique (schedule_id, start_time)
);

comment on table public.schedule_times is
  'Uno o varios horarios diarios para una programación.';

drop trigger if exists trg_schedule_times_set_updated_at on public.schedule_times;
create trigger trg_schedule_times_set_updated_at
before update on public.schedule_times
for each row execute function public.set_updated_at();

create index if not exists idx_schedule_times_schedule
  on public.schedule_times(schedule_id, is_active, start_time);

-- =========================================================
-- 4. EXCEPCIONES DE PROGRAMACIÓN
-- =========================================================

create table if not exists public.schedule_exceptions (
  id uuid primary key default gen_random_uuid(),
  schedule_id uuid not null references public.schedules(id) on delete cascade,
  exception_date date not null,
  action public.schedule_exception_action not null,
  target_time time without time zone,
  override_new_time time without time zone,
  capacity_override integer,
  minimum_adults_override integer,
  departure_status_override public.departure_status,
  public_note text,
  internal_note text,
  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint schedule_exceptions_capacity_valid check (capacity_override is null or capacity_override > 0),
  constraint schedule_exceptions_minimum_valid check (
    minimum_adults_override is null or minimum_adults_override >= 0
  ),
  constraint schedule_exceptions_minimum_within_capacity check (
    capacity_override is null or minimum_adults_override is null or minimum_adults_override <= capacity_override
  ),
  constraint schedule_exceptions_action_fields_valid check (
    (action = 'skip' and override_new_time is null)
    or (action = 'add' and override_new_time is not null)
    or (action = 'override' and target_time is not null)
  )
);

comment on table public.schedule_exceptions is
  'Cambios puntuales: suprimir, añadir o modificar horarios de una fecha concreta.';

drop trigger if exists trg_schedule_exceptions_set_updated_at on public.schedule_exceptions;
create trigger trg_schedule_exceptions_set_updated_at
before update on public.schedule_exceptions
for each row execute function public.set_updated_at();

create index if not exists idx_schedule_exceptions_schedule_date
  on public.schedule_exceptions(schedule_id, exception_date);

create unique index if not exists uq_schedule_exception_identity
  on public.schedule_exceptions(
    schedule_id,
    exception_date,
    action,
    coalesce(target_time, time '00:00:00'),
    coalesce(override_new_time, time '00:00:00')
  );

-- =========================================================
-- 5. SALIDAS REALES
-- =========================================================

create table if not exists public.departures (
  id uuid primary key default gen_random_uuid(),
  experience_id uuid not null references public.experiences(id) on delete restrict,
  schedule_id uuid references public.schedules(id) on delete set null,
  schedule_time_id uuid references public.schedule_times(id) on delete set null,
  starts_at timestamptz not null,
  ends_at timestamptz,
  status public.departure_status not null default 'scheduled',
  is_public boolean not null default true,
  capacity integer,
  minimum_adults integer not null default 0,
  booking_cutoff_if_minimum_not_met_minutes integer not null default 60,
  booking_cutoff_if_minimum_met_minutes integer not null default 1,
  waitlist_enabled boolean not null default true,
  occupied_capacity integer not null default 0,
  adult_minimum_count integer not null default 0,
  guide_id uuid references public.profiles(id) on delete set null,
  public_note text,
  internal_note text,
  generated_from_exception_id uuid references public.schedule_exceptions(id) on delete set null,
  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint departures_ends_after_start check (ends_at is null or ends_at > starts_at),
  constraint departures_capacity_valid check (capacity is null or capacity > 0),
  constraint departures_minimum_adults_valid check (
    minimum_adults >= 0 and (capacity is null or minimum_adults <= capacity)
  ),
  constraint departures_cutoff_not_met_valid check (booking_cutoff_if_minimum_not_met_minutes >= 0),
  constraint departures_cutoff_met_valid check (booking_cutoff_if_minimum_met_minutes >= 0),
  constraint departures_occupied_capacity_valid check (
    occupied_capacity >= 0 and (capacity is null or occupied_capacity <= capacity)
  ),
  constraint departures_adult_minimum_count_valid check (adult_minimum_count >= 0)
);

comment on table public.departures is
  'Ejecuciones concretas de una experiencia en una fecha y hora.';
comment on column public.departures.capacity is
  'Capacidad fotografiada al generar la salida; cambios posteriores en la experiencia no alteran esta salida.';

drop trigger if exists trg_departures_set_updated_at on public.departures;
create trigger trg_departures_set_updated_at
before update on public.departures
for each row execute function public.set_updated_at();

create unique index if not exists uq_departures_experience_starts_at
  on public.departures(experience_id, starts_at);
create index if not exists idx_departures_starts_at on public.departures(starts_at);
create index if not exists idx_departures_experience_starts_at on public.departures(experience_id, starts_at);
create index if not exists idx_departures_public_calendar on public.departures(is_public, status, starts_at);
create index if not exists idx_departures_schedule on public.departures(schedule_id, starts_at);

-- =========================================================
-- 6. FUNCIONES AUXILIARES
-- =========================================================

create or replace function public.schedule_occurs_on_date(
  p_schedule public.schedules,
  p_date date
)
returns boolean
language sql
immutable
set search_path = public
as $$
  select
    p_date between p_schedule.valid_from and p_schedule.valid_until
    and (
      p_schedule.recurrence_type = 'daily'
      or (
        p_schedule.recurrence_type = 'weekly'
        and extract(isodow from p_date)::smallint = any(p_schedule.weekdays)
      )
      or (
        p_schedule.recurrence_type = 'specific_dates'
        and p_date = any(p_schedule.specific_dates)
      )
    );
$$;

create or replace function public.preview_schedule_departures(
  p_schedule_id uuid,
  p_from date default null,
  p_until date default null
)
returns table (
  departure_date date,
  start_time time without time zone,
  starts_at timestamptz,
  source_kind text,
  exception_id uuid,
  capacity integer,
  minimum_adults integer,
  status public.departure_status,
  already_exists boolean
)
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_schedule public.schedules%rowtype;
  v_experience public.experiences%rowtype;
  v_from date;
  v_until date;
  v_date date;
  v_time record;
  v_exception public.schedule_exceptions%rowtype;
  v_override public.schedule_exceptions%rowtype;
  v_start timestamptz;
  v_skip boolean;
begin
  select * into v_schedule from public.schedules where id = p_schedule_id;
  if not found then
    raise exception 'Programación no encontrada: %', p_schedule_id;
  end if;

  select * into v_experience from public.experiences where id = v_schedule.experience_id;
  if not found then
    raise exception 'Experiencia no encontrada para la programación: %', p_schedule_id;
  end if;

  v_from := greatest(coalesce(p_from, v_schedule.valid_from), v_schedule.valid_from);
  v_until := least(coalesce(p_until, v_schedule.valid_until), v_schedule.valid_until);
  if v_from > v_until then return; end if;

  for v_date in select generate_series(v_from, v_until, interval '1 day')::date
  loop
    if public.schedule_occurs_on_date(v_schedule, v_date) then
      for v_time in
        select st.id, st.start_time
        from public.schedule_times st
        where st.schedule_id = v_schedule.id and st.is_active = true
        order by st.display_order, st.start_time
      loop
        v_skip := exists (
          select 1 from public.schedule_exceptions se
          where se.schedule_id = v_schedule.id
            and se.exception_date = v_date
            and se.action = 'skip'
            and (se.target_time is null or se.target_time = v_time.start_time)
        );
        if v_skip then continue; end if;

        v_override := null;
        select se.* into v_override
        from public.schedule_exceptions se
        where se.schedule_id = v_schedule.id
          and se.exception_date = v_date
          and se.action = 'override'
          and se.target_time = v_time.start_time
        order by se.created_at desc
        limit 1;

        v_start := (
          v_date + coalesce(v_override.override_new_time, v_time.start_time)
        ) at time zone v_schedule.timezone;

        departure_date := v_date;
        start_time := coalesce(v_override.override_new_time, v_time.start_time);
        starts_at := v_start;
        source_kind := case when v_override.id is null then 'schedule' else 'override' end;
        exception_id := v_override.id;
        capacity := coalesce(v_override.capacity_override, v_schedule.capacity_override, v_experience.capacity);
        minimum_adults := coalesce(v_override.minimum_adults_override, v_schedule.minimum_adults_override, v_experience.minimum_adults);
        status := coalesce(v_override.departure_status_override, 'scheduled'::public.departure_status);
        already_exists := exists (
          select 1 from public.departures d
          where d.experience_id = v_schedule.experience_id and d.starts_at = v_start
        );
        return next;
      end loop;
    end if;

    for v_exception in
      select se.* from public.schedule_exceptions se
      where se.schedule_id = v_schedule.id
        and se.exception_date = v_date
        and se.action = 'add'
      order by se.override_new_time
    loop
      v_start := (v_date + v_exception.override_new_time) at time zone v_schedule.timezone;
      departure_date := v_date;
      start_time := v_exception.override_new_time;
      starts_at := v_start;
      source_kind := 'add';
      exception_id := v_exception.id;
      capacity := coalesce(v_exception.capacity_override, v_schedule.capacity_override, v_experience.capacity);
      minimum_adults := coalesce(v_exception.minimum_adults_override, v_schedule.minimum_adults_override, v_experience.minimum_adults);
      status := coalesce(v_exception.departure_status_override, 'scheduled'::public.departure_status);
      already_exists := exists (
        select 1 from public.departures d
        where d.experience_id = v_schedule.experience_id and d.starts_at = v_start
      );
      return next;
    end loop;
  end loop;
end;
$$;

comment on function public.preview_schedule_departures(uuid, date, date) is
  'Devuelve una vista previa de las salidas que generaría una programación, señalando duplicados.';

create or replace function public.generate_schedule_departures(
  p_schedule_id uuid,
  p_from date default null,
  p_until date default null
)
returns table (inserted_count integer, skipped_existing_count integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_schedule public.schedules%rowtype;
  v_experience public.experiences%rowtype;
  v_preview record;
  v_inserted integer := 0;
  v_skipped integer := 0;
  v_duration interval;
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

  if not found then raise exception 'Programación no encontrada: %', p_schedule_id; end if;
  if v_schedule.status <> 'active' then
    raise exception 'Solo se pueden generar salidas desde una programación activa';
  end if;

  if not exists (
    select 1 from public.schedule_times st
    where st.schedule_id = v_schedule.id and st.is_active = true
  ) and not exists (
    select 1 from public.schedule_exceptions se
    where se.schedule_id = v_schedule.id and se.action = 'add'
  ) then
    raise exception 'La programación no tiene horarios activos';
  end if;

  select * into v_experience from public.experiences where id = v_schedule.experience_id;
  v_duration := case
    when v_experience.duration_minutes is null then null
    else make_interval(mins => v_experience.duration_minutes)
  end;

  for v_preview in
    select * from public.preview_schedule_departures(p_schedule_id, p_from, p_until)
    order by starts_at
  loop
    if v_preview.already_exists then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    insert into public.departures (
      experience_id, schedule_id, schedule_time_id, starts_at, ends_at,
      status, is_public, capacity, minimum_adults,
      booking_cutoff_if_minimum_not_met_minutes,
      booking_cutoff_if_minimum_met_minutes,
      waitlist_enabled, generated_from_exception_id, created_by, updated_by
    )
    values (
      v_schedule.experience_id,
      v_schedule.id,
      case when v_preview.source_kind = 'schedule' then (
        select st.id from public.schedule_times st
        where st.schedule_id = v_schedule.id
          and st.start_time = v_preview.start_time
        limit 1
      ) else null end,
      v_preview.starts_at,
      case when v_duration is null then null else v_preview.starts_at + v_duration end,
      v_preview.status,
      true,
      v_preview.capacity,
      v_preview.minimum_adults,
      coalesce(
        v_schedule.booking_cutoff_if_minimum_not_met_minutes_override,
        v_experience.booking_cutoff_if_minimum_not_met_minutes
      ),
      coalesce(
        v_schedule.booking_cutoff_if_minimum_met_minutes_override,
        v_experience.booking_cutoff_if_minimum_met_minutes
      ),
      coalesce(v_schedule.waitlist_enabled_override, v_experience.waitlist_enabled),
      v_preview.exception_id,
      auth.uid(),
      auth.uid()
    )
    on conflict (experience_id, starts_at) do nothing;

    if found then v_inserted := v_inserted + 1;
    else v_skipped := v_skipped + 1;
    end if;
  end loop;

  inserted_count := v_inserted;
  skipped_existing_count := v_skipped;
  return next;
end;
$$;

comment on function public.generate_schedule_departures(uuid, date, date) is
  'Genera salidas de forma segura. No modifica las existentes ni crea duplicados.';

revoke all on function public.generate_schedule_departures(uuid, date, date) from public, anon;
grant execute on function public.generate_schedule_departures(uuid, date, date) to authenticated;
grant execute on function public.preview_schedule_departures(uuid, date, date) to authenticated;

-- =========================================================
-- 7. AUDITORÍA
-- =========================================================

drop trigger if exists trg_audit_schedules on public.schedules;
create trigger trg_audit_schedules
after insert or update or delete on public.schedules
for each row execute function public.write_audit_log();

drop trigger if exists trg_audit_schedule_times on public.schedule_times;
create trigger trg_audit_schedule_times
after insert or update or delete on public.schedule_times
for each row execute function public.write_audit_log();

drop trigger if exists trg_audit_schedule_exceptions on public.schedule_exceptions;
create trigger trg_audit_schedule_exceptions
after insert or update or delete on public.schedule_exceptions
for each row execute function public.write_audit_log();

drop trigger if exists trg_audit_departures on public.departures;
create trigger trg_audit_departures
after insert or update or delete on public.departures
for each row execute function public.write_audit_log();

-- =========================================================
-- 8. ROW LEVEL SECURITY
-- =========================================================

alter table public.schedules enable row level security;
alter table public.schedule_times enable row level security;
alter table public.schedule_exceptions enable row level security;
alter table public.departures enable row level security;

drop policy if exists schedules_staff_read on public.schedules;
create policy schedules_staff_read on public.schedules for select to authenticated
using (public.current_user_has_role(array['owner','admin','manager','guide','viewer']::public.app_role[]));

drop policy if exists schedules_staff_write on public.schedules;
create policy schedules_staff_write on public.schedules for all to authenticated
using (public.current_user_has_role(array['owner','admin','manager']::public.app_role[]))
with check (public.current_user_has_role(array['owner','admin','manager']::public.app_role[]));

drop policy if exists schedule_times_staff_read on public.schedule_times;
create policy schedule_times_staff_read on public.schedule_times for select to authenticated
using (public.current_user_has_role(array['owner','admin','manager','guide','viewer']::public.app_role[]));

drop policy if exists schedule_times_staff_write on public.schedule_times;
create policy schedule_times_staff_write on public.schedule_times for all to authenticated
using (public.current_user_has_role(array['owner','admin','manager']::public.app_role[]))
with check (public.current_user_has_role(array['owner','admin','manager']::public.app_role[]));

drop policy if exists schedule_exceptions_staff_read on public.schedule_exceptions;
create policy schedule_exceptions_staff_read on public.schedule_exceptions for select to authenticated
using (public.current_user_has_role(array['owner','admin','manager','guide','viewer']::public.app_role[]));

drop policy if exists schedule_exceptions_staff_write on public.schedule_exceptions;
create policy schedule_exceptions_staff_write on public.schedule_exceptions for all to authenticated
using (public.current_user_has_role(array['owner','admin','manager']::public.app_role[]))
with check (public.current_user_has_role(array['owner','admin','manager']::public.app_role[]));

drop policy if exists departures_public_read on public.departures;
create policy departures_public_read on public.departures for select to anon, authenticated
using (
  is_public = true
  and starts_at >= now()
  and status in ('scheduled'::public.departure_status,'full'::public.departure_status,'closed'::public.departure_status)
  and exists (
    select 1 from public.experiences e
    where e.id = departures.experience_id and e.status = 'active'
  )
);

drop policy if exists departures_staff_read on public.departures;
create policy departures_staff_read on public.departures for select to authenticated
using (public.current_user_has_role(array['owner','admin','manager','guide','viewer']::public.app_role[]));

drop policy if exists departures_staff_write on public.departures;
create policy departures_staff_write on public.departures for all to authenticated
using (public.current_user_has_role(array['owner','admin','manager']::public.app_role[]))
with check (public.current_user_has_role(array['owner','admin','manager']::public.app_role[]));

-- =========================================================
-- 9. PROGRAMACIÓN INICIAL: TRUJILLO ESENCIAL
-- =========================================================

insert into public.schedules (
  experience_id, name, status, valid_from, valid_until,
  recurrence_type, weekdays, specific_dates, timezone,
  capacity_override, minimum_adults_override, internal_notes
)
select
  e.id,
  'Operativa inicial 2026',
  'active'::public.schedule_status,
  date '2026-01-01',
  date '2026-12-31',
  'weekly'::public.recurrence_type,
  array[1,2,3,4,5]::smallint[],
  array[]::date[],
  'Europe/Madrid',
  null,
  null,
  'Programación inicial editable. No presupone temporadas de verano o invierno.'
from public.experiences e
where e.code = 'ETES'
  and not exists (
    select 1 from public.schedules s
    where s.experience_id = e.id and s.name = 'Operativa inicial 2026'
  );

insert into public.schedule_times (schedule_id, start_time, display_order, is_active)
select s.id, time '11:30', 10, true
from public.schedules s
join public.experiences e on e.id = s.experience_id
where e.code = 'ETES' and s.name = 'Operativa inicial 2026'
on conflict (schedule_id, start_time) do update
set is_active = true, display_order = excluded.display_order, updated_at = now();

commit;
