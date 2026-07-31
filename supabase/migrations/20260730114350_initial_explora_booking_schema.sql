-- Explora Booking
-- Migración inicial: cimientos funcionales
-- Fecha: 2026-07-30
-- Archivo: 20260730114350_initial_explora_booking_schema.sql

begin;

-- =========================================================
-- 1. EXTENSIONES
-- =========================================================

create extension if not exists pgcrypto;

-- =========================================================
-- 2. TIPOS ENUMERADOS
-- =========================================================

do $$
begin
  if not exists (select 1 from pg_type where typname = 'app_role') then
    create type public.app_role as enum (
      'owner',
      'admin',
      'manager',
      'guide',
      'viewer'
    );
  end if;

  if not exists (select 1 from pg_type where typname = 'experience_status') then
    create type public.experience_status as enum (
      'draft',
      'active',
      'inactive',
      'archived'
    );
  end if;

  if not exists (select 1 from pg_type where typname = 'participant_category') then
    create type public.participant_category as enum (
      'adult',
      'child',
      'infant',
      'senior',
      'student',
      'other'
    );
  end if;

  if not exists (select 1 from pg_type where typname = 'pricing_mode') then
    create type public.pricing_mode as enum (
      'per_person',
      'per_group',
      'on_request'
    );
  end if;
end
$$;

-- =========================================================
-- 3. FUNCIONES COMUNES
-- =========================================================

create or replace function public.set_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- =========================================================
-- 4. PERFILES Y USUARIOS DEL BACKOFFICE
-- =========================================================

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  full_name text,
  role public.app_role not null default 'viewer',
  is_active boolean not null default true,
  last_login_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint profiles_email_not_blank
    check (length(trim(email)) > 0)
);

comment on table public.profiles is
  'Usuarios autorizados para acceder al backoffice de Explora Booking.';

comment on column public.profiles.role is
  'Rol interno del usuario. owner tiene el máximo nivel de permisos.';

drop trigger if exists trg_profiles_set_updated_at on public.profiles;
create trigger trg_profiles_set_updated_at
before update on public.profiles
for each row execute function public.set_updated_at();

create or replace function public.current_user_has_role(allowed_roles public.app_role[])
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.is_active = true
      and p.role = any(allowed_roles)
  );
$$;

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (
    id,
    email,
    full_name,
    role,
    is_active
  )
  values (
    new.id,
    coalesce(new.email, ''),
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    'viewer',
    true
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_auth_user();

-- =========================================================
-- 5. EXPERIENCIAS
-- =========================================================

create table if not exists public.experiences (
  id uuid primary key default gen_random_uuid(),

  -- Identificación estable
  code text not null unique,
  slug text not null unique,

  -- Contenido comercial
  name text not null,
  short_description text,
  long_description text,
  main_image_url text,

  -- Operativa
  status public.experience_status not null default 'draft',
  pricing_mode public.pricing_mode not null default 'per_person',
  duration_minutes integer,
  meeting_point text,
  capacity integer,
  minimum_adults integer not null default 0,

  -- Reglas de reserva
  booking_cutoff_if_minimum_not_met_minutes integer not null default 60,
  booking_cutoff_if_minimum_met_minutes integer not null default 1,
  waitlist_enabled boolean not null default true,
  promotions_enabled boolean not null default true,
  manual_payment_enabled boolean not null default true,

  -- Visibilidad y orden
  is_featured boolean not null default false,
  display_order integer not null default 0,

  -- Control
  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint experiences_code_format
    check (code ~ '^[A-Z0-9]{3,12}$'),

  constraint experiences_slug_format
    check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),

  constraint experiences_name_not_blank
    check (length(trim(name)) > 0),

  constraint experiences_duration_positive
    check (duration_minutes is null or duration_minutes > 0),

  constraint experiences_capacity_positive
    check (capacity is null or capacity > 0),

  constraint experiences_minimum_adults_valid
    check (
      minimum_adults >= 0
      and (capacity is null or minimum_adults <= capacity)
    ),

  constraint experiences_cutoff_not_met_valid
    check (booking_cutoff_if_minimum_not_met_minutes >= 0),

  constraint experiences_cutoff_met_valid
    check (booking_cutoff_if_minimum_met_minutes >= 0)
);

comment on table public.experiences is
  'Ficha maestra de cada experiencia. El frontend y el backoffice leen de esta tabla.';

comment on column public.experiences.code is
  'Código interno estable utilizado, entre otras cosas, para el localizador de reserva.';

comment on column public.experiences.pricing_mode is
  'Indica si el precio es por persona, por grupo o bajo consulta.';

drop trigger if exists trg_experiences_set_updated_at on public.experiences;
create trigger trg_experiences_set_updated_at
before update on public.experiences
for each row execute function public.set_updated_at();

create index if not exists idx_experiences_status
  on public.experiences(status);

create index if not exists idx_experiences_display_order
  on public.experiences(display_order, name);

-- =========================================================
-- 6. TARIFAS Y REGLAS DE EDAD
-- =========================================================

create table if not exists public.experience_price_rules (
  id uuid primary key default gen_random_uuid(),
  experience_id uuid not null
    references public.experiences(id) on delete cascade,

  -- Qué tipo de participante cubre
  category public.participant_category not null,
  label text not null,
  min_age integer,
  max_age integer,

  -- Precio
  price_cents integer not null default 0,
  currency char(3) not null default 'EUR',

  -- Inventario y mínimos
  counts_towards_capacity boolean not null default true,
  counts_as_adult_for_minimum boolean not null default false,

  -- Vigencia
  valid_from date,
  valid_until date,
  is_active boolean not null default true,
  display_order integer not null default 0,

  -- Control
  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint experience_price_rules_label_not_blank
    check (length(trim(label)) > 0),

  constraint experience_price_rules_age_min_valid
    check (min_age is null or min_age >= 0),

  constraint experience_price_rules_age_max_valid
    check (max_age is null or max_age >= 0),

  constraint experience_price_rules_age_range_valid
    check (
      min_age is null
      or max_age is null
      or min_age <= max_age
    ),

  constraint experience_price_rules_price_valid
    check (price_cents >= 0),

  constraint experience_price_rules_currency_format
    check (currency ~ '^[A-Z]{3}$'),

  constraint experience_price_rules_dates_valid
    check (
      valid_from is null
      or valid_until is null
      or valid_from <= valid_until
    )
);

comment on table public.experience_price_rules is
  'Tarifas configurables por experiencia, categoría, edad y periodo de vigencia.';

comment on column public.experience_price_rules.price_cents is
  'Precio expresado en céntimos para evitar errores de redondeo. Ejemplo: 950 = 9,50 €.';

comment on column public.experience_price_rules.counts_towards_capacity is
  'Indica si este participante consume una plaza del inventario.';

comment on column public.experience_price_rules.counts_as_adult_for_minimum is
  'Indica si este participante computa para alcanzar el mínimo de adultos.';

drop trigger if exists trg_experience_price_rules_set_updated_at
  on public.experience_price_rules;

create trigger trg_experience_price_rules_set_updated_at
before update on public.experience_price_rules
for each row execute function public.set_updated_at();

create index if not exists idx_experience_price_rules_experience
  on public.experience_price_rules(experience_id);

create index if not exists idx_experience_price_rules_active
  on public.experience_price_rules(experience_id, is_active);

create unique index if not exists uq_experience_price_rule_identity
  on public.experience_price_rules(
    experience_id,
    category,
    coalesce(min_age, -1),
    coalesce(max_age, -1),
    coalesce(valid_from, date '1900-01-01'),
    coalesce(valid_until, date '9999-12-31')
  );

-- =========================================================
-- 7. HISTORIAL DE CAMBIOS / AUDITORÍA
-- =========================================================

create table if not exists public.audit_log (
  id bigint generated always as identity primary key,
  table_name text not null,
  record_id text not null,
  action text not null,
  old_data jsonb,
  new_data jsonb,
  changed_by uuid references public.profiles(id) on delete set null,
  changed_at timestamptz not null default now(),

  constraint audit_log_action_valid
    check (action in ('INSERT', 'UPDATE', 'DELETE'))
);

comment on table public.audit_log is
  'Historial técnico de altas, modificaciones y eliminaciones de registros importantes.';

create index if not exists idx_audit_log_record
  on public.audit_log(table_name, record_id);

create index if not exists idx_audit_log_changed_at
  on public.audit_log(changed_at desc);

create or replace function public.write_audit_log()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_record_id text;
begin
  if tg_op = 'DELETE' then
    v_record_id := old.id::text;

    insert into public.audit_log (
      table_name,
      record_id,
      action,
      old_data,
      new_data,
      changed_by
    )
    values (
      tg_table_name,
      v_record_id,
      tg_op,
      to_jsonb(old),
      null,
      auth.uid()
    );

    return old;
  end if;

  v_record_id := new.id::text;

  insert into public.audit_log (
    table_name,
    record_id,
    action,
    old_data,
    new_data,
    changed_by
  )
  values (
    tg_table_name,
    v_record_id,
    tg_op,
    case when tg_op = 'UPDATE' then to_jsonb(old) else null end,
    to_jsonb(new),
    auth.uid()
  );

  return new;
end;
$$;

drop trigger if exists trg_audit_experiences on public.experiences;
create trigger trg_audit_experiences
after insert or update or delete on public.experiences
for each row execute function public.write_audit_log();

drop trigger if exists trg_audit_experience_price_rules
  on public.experience_price_rules;

create trigger trg_audit_experience_price_rules
after insert or update or delete on public.experience_price_rules
for each row execute function public.write_audit_log();

drop trigger if exists trg_audit_profiles on public.profiles;
create trigger trg_audit_profiles
after update or delete on public.profiles
for each row execute function public.write_audit_log();

-- =========================================================
-- 8. ROW LEVEL SECURITY
-- =========================================================

alter table public.profiles enable row level security;
alter table public.experiences enable row level security;
alter table public.experience_price_rules enable row level security;
alter table public.audit_log enable row level security;

-- Perfiles: cada usuario puede leer su propio perfil.
drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own
on public.profiles
for select
to authenticated
using (id = auth.uid());

-- Propietarios y administradores pueden consultar todos los perfiles.
drop policy if exists profiles_select_admin on public.profiles;
create policy profiles_select_admin
on public.profiles
for select
to authenticated
using (
  public.current_user_has_role(
    array['owner', 'admin']::public.app_role[]
  )
);

-- Propietarios pueden administrar perfiles.
drop policy if exists profiles_all_owner on public.profiles;
create policy profiles_all_owner
on public.profiles
for all
to authenticated
using (
  public.current_user_has_role(
    array['owner']::public.app_role[]
  )
)
with check (
  public.current_user_has_role(
    array['owner']::public.app_role[]
  )
);

-- El público puede leer únicamente experiencias activas.
drop policy if exists experiences_public_read_active on public.experiences;
create policy experiences_public_read_active
on public.experiences
for select
to anon, authenticated
using (status = 'active');

-- El backoffice puede leer todas las experiencias.
drop policy if exists experiences_staff_read_all on public.experiences;
create policy experiences_staff_read_all
on public.experiences
for select
to authenticated
using (
  public.current_user_has_role(
    array['owner', 'admin', 'manager', 'guide', 'viewer']::public.app_role[]
  )
);

-- Propietario, administrador y gestor pueden crear/modificar/eliminar experiencias.
drop policy if exists experiences_staff_write on public.experiences;
create policy experiences_staff_write
on public.experiences
for all
to authenticated
using (
  public.current_user_has_role(
    array['owner', 'admin', 'manager']::public.app_role[]
  )
)
with check (
  public.current_user_has_role(
    array['owner', 'admin', 'manager']::public.app_role[]
  )
);

-- El público puede leer tarifas activas, vigentes y pertenecientes a experiencias activas.
drop policy if exists price_rules_public_read_active
  on public.experience_price_rules;

create policy price_rules_public_read_active
on public.experience_price_rules
for select
to anon, authenticated
using (
  is_active = true
  and (valid_from is null or valid_from <= current_date)
  and (valid_until is null or valid_until >= current_date)
  and exists (
    select 1
    from public.experiences e
    where e.id = experience_price_rules.experience_id
      and e.status = 'active'
  )
);

-- El backoffice puede leer todas las tarifas.
drop policy if exists price_rules_staff_read_all
  on public.experience_price_rules;

create policy price_rules_staff_read_all
on public.experience_price_rules
for select
to authenticated
using (
  public.current_user_has_role(
    array['owner', 'admin', 'manager', 'guide', 'viewer']::public.app_role[]
  )
);

-- Propietario, administrador y gestor pueden administrar tarifas.
drop policy if exists price_rules_staff_write
  on public.experience_price_rules;

create policy price_rules_staff_write
on public.experience_price_rules
for all
to authenticated
using (
  public.current_user_has_role(
    array['owner', 'admin', 'manager']::public.app_role[]
  )
)
with check (
  public.current_user_has_role(
    array['owner', 'admin', 'manager']::public.app_role[]
  )
);

-- Auditoría visible únicamente para propietario y administrador.
drop policy if exists audit_log_admin_read on public.audit_log;
create policy audit_log_admin_read
on public.audit_log
for select
to authenticated
using (
  public.current_user_has_role(
    array['owner', 'admin']::public.app_role[]
  )
);

-- No se crean políticas INSERT/UPDATE/DELETE para audit_log.
-- Los registros se escriben exclusivamente mediante la función de auditoría.

-- =========================================================
-- 9. DATOS INICIALES DE EXPERIENCIAS
-- =========================================================

insert into public.experiences (
  code,
  slug,
  name,
  short_description,
  status,
  pricing_mode,
  duration_minutes,
  meeting_point,
  capacity,
  minimum_adults,
  booking_cutoff_if_minimum_not_met_minutes,
  booking_cutoff_if_minimum_met_minutes,
  waitlist_enabled,
  promotions_enabled,
  manual_payment_enabled,
  display_order
)
values
  (
    'ETES',
    'trujillo-esencial',
    'Trujillo Esencial',
    'Visita guiada esencial por el patrimonio histórico de Trujillo.',
    'active',
    'per_person',
    120,
    'Plaza Mayor',
    25,
    4,
    60,
    1,
    true,
    true,
    true,
    10
  ),
  (
    'ETNC',
    'a-la-luz-del-candil',
    'A la luz del Candil',
    'Experiencia nocturna para descubrir Trujillo bajo otra luz.',
    'active',
    'per_person',
    null,
    'Por determinar',
    25,
    0,
    60,
    1,
    true,
    true,
    true,
    20
  ),
  (
    'ETPE',
    'pequenos-exploradores',
    'Pequeños Exploradores',
    'Visita participativa para descubrir Trujillo en familia.',
    'active',
    'per_person',
    null,
    'Plaza Mayor',
    25,
    4,
    60,
    1,
    true,
    true,
    true,
    30
  ),
  (
    'ETPV',
    'visita-privada',
    'Visita privada',
    'Experiencia privada personalizada.',
    'active',
    'on_request',
    null,
    'Por determinar',
    null,
    0,
    60,
    1,
    false,
    false,
    true,
    40
  )
on conflict (code) do update
set
  slug = excluded.slug,
  name = excluded.name,
  short_description = excluded.short_description,
  status = excluded.status,
  pricing_mode = excluded.pricing_mode,
  duration_minutes = excluded.duration_minutes,
  meeting_point = excluded.meeting_point,
  capacity = excluded.capacity,
  minimum_adults = excluded.minimum_adults,
  booking_cutoff_if_minimum_not_met_minutes =
    excluded.booking_cutoff_if_minimum_not_met_minutes,
  booking_cutoff_if_minimum_met_minutes =
    excluded.booking_cutoff_if_minimum_met_minutes,
  waitlist_enabled = excluded.waitlist_enabled,
  promotions_enabled = excluded.promotions_enabled,
  manual_payment_enabled = excluded.manual_payment_enabled,
  display_order = excluded.display_order,
  updated_at = now();

-- Tarifas iniciales. Podrán editarse posteriormente desde el backoffice.

insert into public.experience_price_rules (
  experience_id,
  category,
  label,
  min_age,
  max_age,
  price_cents,
  currency,
  counts_towards_capacity,
  counts_as_adult_for_minimum,
  is_active,
  display_order
)
select
  e.id,
  v.category::public.participant_category,
  v.label,
  v.min_age,
  v.max_age,
  v.price_cents,
  'EUR',
  v.counts_towards_capacity,
  v.counts_as_adult_for_minimum,
  true,
  v.display_order
from public.experiences e
join (
  values
    ('ETES', 'child',  'Niños de 0 a 11 años',       0, 11,    0, false, false, 10),
    ('ETES', 'adult',  'Adultos desde 12 años',      12, null, 950, true,  true,  20),

    ('ETNC', 'adult',  'Adultos desde 12 años',      12, null, 1000, true, true, 10),

    ('ETPE', 'infant', 'Menores de 0 a 3 años',       0, 3,     0, false, false, 10),
    ('ETPE', 'child',  'Niños de 4 a 14 años',        4, 14,  600, true,  false, 20),
    ('ETPE', 'adult',  'Adultos desde 15 años',       15, null, 1000, true, true, 30)
) as v(
  experience_code,
  category,
  label,
  min_age,
  max_age,
  price_cents,
  counts_towards_capacity,
  counts_as_adult_for_minimum,
  display_order
)
  on e.code = v.experience_code
on conflict (
  experience_id,
  category,
  coalesce(min_age, -1),
  coalesce(max_age, -1),
  coalesce(valid_from, date '1900-01-01'),
  coalesce(valid_until, date '9999-12-31')
)
do update
set
  label = excluded.label,
  price_cents = excluded.price_cents,
  currency = excluded.currency,
  counts_towards_capacity = excluded.counts_towards_capacity,
  counts_as_adult_for_minimum = excluded.counts_as_adult_for_minimum,
  is_active = excluded.is_active,
  display_order = excluded.display_order,
  updated_at = now();

commit;
