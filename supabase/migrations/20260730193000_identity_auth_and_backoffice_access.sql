-- Explora Booking
-- Entregable 4: identidad, autenticación y acceso protegido
-- Fecha: 2026-07-30
-- Archivo: 20260730193000_identity_auth_and_backoffice_access.sql
--
-- Dependencias:
--   20260730114350_initial_explora_booking_schema.sql
--   20260730150000_schedules_and_departures.sql
--   20260730180000_generation_engine_and_resources.sql
--
-- Principios:
--   - auth.users es la identidad.
--   - public.profiles es el perfil operativo.
--   - Todo usuario nuevo entra como viewer e inactivo para operaciones.
--   - El primer propietario se promueve expresamente mediante una función
--     de bootstrap ejecutada desde SQL Editor.
--   - Nunca se acepta un rol enviado por el navegador.
--   - La migración no crea usuarios ni contraseñas.

begin;

-- =========================================================
-- 1. CAMPOS DE IDENTIDAD OPERATIVA
-- =========================================================

alter table public.profiles
  add column if not exists display_name text;

alter table public.profiles
  add column if not exists phone text;

alter table public.profiles
  add column if not exists avatar_url text;

alter table public.profiles
  add column if not exists invited_by uuid
  references public.profiles(id) on delete set null;

alter table public.profiles
  add column if not exists invited_at timestamptz;

alter table public.profiles
  add column if not exists accepted_at timestamptz;

alter table public.profiles
  add column if not exists last_seen_at timestamptz;

alter table public.profiles
  add column if not exists onboarding_completed_at timestamptz;

alter table public.profiles
  add column if not exists auth_metadata jsonb
  not null default '{}'::jsonb;

comment on column public.profiles.auth_metadata is
  'Metadatos no sensibles copiados desde auth.users. Nunca se usa para autorizar roles.';

update public.profiles
set display_name = coalesce(
  nullif(trim(display_name), ''),
  nullif(trim(full_name), ''),
  email
)
where display_name is null
   or trim(display_name) = '';

-- =========================================================
-- 2. CREACIÓN AUTOMÁTICA DE PROFILES DESDE AUTH.USERS
-- =========================================================

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text;
begin
  v_name := coalesce(
    nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''),
    nullif(trim(new.raw_user_meta_data ->> 'name'), ''),
    split_part(coalesce(new.email, ''), '@', 1),
    'Usuario'
  );

  insert into public.profiles (
    id,
    email,
    full_name,
    display_name,
    role,
    is_active,
    invited_at,
    accepted_at,
    auth_metadata
  )
  values (
    new.id,
    new.email,
    v_name,
    v_name,
    'viewer'::public.app_role,
    false,
    case when new.invited_at is not null then new.invited_at else null end,
    case when new.email_confirmed_at is not null then now() else null end,
    jsonb_build_object(
      'provider', new.raw_app_meta_data ->> 'provider',
      'providers', coalesce(new.raw_app_meta_data -> 'providers', '[]'::jsonb)
    )
  )
  on conflict (id) do update
  set
    email = excluded.email,
    full_name = coalesce(
      nullif(trim(public.profiles.full_name), ''),
      excluded.full_name
    ),
    display_name = coalesce(
      nullif(trim(public.profiles.display_name), ''),
      excluded.display_name
    ),
    accepted_at = coalesce(
      public.profiles.accepted_at,
      excluded.accepted_at
    ),
    auth_metadata = excluded.auth_metadata;

  return new;
end;
$$;

comment on function public.handle_new_auth_user() is
  'Crea el perfil operativo de forma segura. El rol siempre comienza como viewer.';

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_auth_user();

-- Mantiene correo, confirmación y metadatos sincronizados.
create or replace function public.handle_updated_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.profiles
  set
    email = new.email,
    accepted_at = coalesce(
      public.profiles.accepted_at,
      case when new.email_confirmed_at is not null then now() else null end
    ),
    auth_metadata = jsonb_build_object(
      'provider', new.raw_app_meta_data ->> 'provider',
      'providers', coalesce(new.raw_app_meta_data -> 'providers', '[]'::jsonb)
    )
  where id = new.id;

  return new;
end;
$$;

drop trigger if exists on_auth_user_updated on auth.users;
create trigger on_auth_user_updated
after update of email, email_confirmed_at, raw_app_meta_data
on auth.users
for each row execute function public.handle_updated_auth_user();

-- Recupera usuarios que pudieran existir antes de esta migración.
insert into public.profiles (
  id,
  email,
  full_name,
  display_name,
  role,
  is_active,
  invited_at,
  accepted_at,
  auth_metadata
)
select
  u.id,
  u.email,
  coalesce(
    nullif(trim(u.raw_user_meta_data ->> 'full_name'), ''),
    nullif(trim(u.raw_user_meta_data ->> 'name'), ''),
    split_part(coalesce(u.email, ''), '@', 1),
    'Usuario'
  ),
  coalesce(
    nullif(trim(u.raw_user_meta_data ->> 'full_name'), ''),
    nullif(trim(u.raw_user_meta_data ->> 'name'), ''),
    split_part(coalesce(u.email, ''), '@', 1),
    'Usuario'
  ),
  'viewer'::public.app_role,
  false,
  u.invited_at,
  case when u.email_confirmed_at is not null then now() else null end,
  jsonb_build_object(
    'provider', u.raw_app_meta_data ->> 'provider',
    'providers', coalesce(u.raw_app_meta_data -> 'providers', '[]'::jsonb)
  )
from auth.users u
on conflict (id) do nothing;

-- =========================================================
-- 3. FUNCIONES DE SESIÓN
-- =========================================================

create or replace function public.get_my_backoffice_profile()
returns table (
  id uuid,
  email text,
  full_name text,
  display_name text,
  role public.app_role,
  is_active boolean,
  phone text,
  avatar_url text,
  minimum_start_gap_minutes integer,
  onboarding_completed_at timestamptz
)
language sql
stable
security invoker
set search_path = public
as $$
  select
    p.id,
    p.email,
    p.full_name,
    p.display_name,
    p.role,
    p.is_active,
    p.phone,
    p.avatar_url,
    p.minimum_start_gap_minutes,
    p.onboarding_completed_at
  from public.profiles p
  where p.id = auth.uid();
$$;

grant execute on function public.get_my_backoffice_profile()
to authenticated;

create or replace function public.touch_my_last_seen()
returns void
language sql
volatile
security invoker
set search_path = public
as $$
  update public.profiles
  set last_seen_at = now()
  where id = auth.uid();
$$;

grant execute on function public.touch_my_last_seen()
to authenticated;

create or replace function public.update_my_profile(
  p_full_name text,
  p_phone text default null,
  p_avatar_url text default null
)
returns public.profiles
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_profile public.profiles;
begin
  if auth.uid() is null then
    raise exception 'Sesión no válida';
  end if;

  if length(trim(coalesce(p_full_name, ''))) < 2 then
    raise exception 'El nombre debe tener al menos 2 caracteres';
  end if;

  update public.profiles
  set
    full_name = trim(p_full_name),
    display_name = trim(p_full_name),
    phone = nullif(trim(coalesce(p_phone, '')), ''),
    avatar_url = nullif(trim(coalesce(p_avatar_url, '')), ''),
    onboarding_completed_at = coalesce(onboarding_completed_at, now())
  where id = auth.uid()
  returning * into v_profile;

  return v_profile;
end;
$$;

grant execute on function public.update_my_profile(text, text, text)
to authenticated;

-- =========================================================
-- 4. BOOTSTRAP SEGURO DEL PRIMER PROPIETARIO
-- =========================================================

create or replace function public.bootstrap_initial_owner(
  p_email text,
  p_full_name text default 'Esmeralda Gamino'
)
returns table (
  profile_id uuid,
  profile_email text,
  assigned_role public.app_role,
  guide_resource_id uuid,
  schedules_assigned integer
)
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_user auth.users%rowtype;
  v_resource_id uuid;
  v_schedules integer := 0;
begin
  -- Solo debe ejecutarse desde SQL Editor o con una credencial administrativa.
  if current_user not in (
    'postgres',
    'supabase_admin',
    'service_role'
  ) then
    raise exception 'Esta función solo puede ejecutarse administrativamente';
  end if;

  if exists (
    select 1
    from public.profiles
    where role = 'owner'::public.app_role
      and is_active = true
  ) then
    raise exception 'Ya existe un propietario activo. El bootstrap está cerrado.';
  end if;

  select *
  into v_user
  from auth.users
  where lower(email) = lower(trim(p_email))
  limit 1;

  if not found then
    raise exception
      'No existe un usuario de Auth con el correo %. Créalo primero en Authentication > Users.',
      p_email;
  end if;

  insert into public.profiles (
    id,
    email,
    full_name,
    display_name,
    role,
    is_active,
    accepted_at,
    onboarding_completed_at
  )
  values (
    v_user.id,
    v_user.email,
    trim(p_full_name),
    trim(p_full_name),
    'owner'::public.app_role,
    true,
    coalesce(v_user.email_confirmed_at, now()),
    now()
  )
  on conflict (id) do update
  set
    email = excluded.email,
    full_name = excluded.full_name,
    display_name = excluded.display_name,
    role = 'owner'::public.app_role,
    is_active = true,
    accepted_at = coalesce(public.profiles.accepted_at, excluded.accepted_at),
    onboarding_completed_at = coalesce(
      public.profiles.onboarding_completed_at,
      excluded.onboarding_completed_at
    );

  -- El trigger del Entregable 3 crea el recurso guía al cambiar el perfil.
  select r.id
  into v_resource_id
  from public.resources r
  where r.profile_id = v_user.id
    and r.kind = 'guide'::public.resource_kind
  limit 1;

  -- Salvaguarda por si el trigger no hubiera sido ejecutado todavía.
  if v_resource_id is null then
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
      trim(p_full_name),
      'active'::public.resource_status,
      v_user.id,
      150,
      v_user.id,
      v_user.id
    )
    returning id into v_resource_id;
  end if;

  -- Asigna la guía inicial a programaciones activas que aún no tengan guía.
  update public.schedules
  set default_guide_id = v_user.id
  where status = 'active'::public.schedule_status
    and default_guide_id is null;

  get diagnostics v_schedules = row_count;

  insert into public.schedule_resources (
    schedule_id,
    resource_id,
    is_primary,
    created_by
  )
  select
    s.id,
    v_resource_id,
    true,
    v_user.id
  from public.schedules s
  where s.default_guide_id = v_user.id
  on conflict (schedule_id, resource_id)
  do update set is_primary = true;

  return query
  select
    v_user.id,
    v_user.email,
    'owner'::public.app_role,
    v_resource_id,
    v_schedules;
end;
$$;

revoke all on function public.bootstrap_initial_owner(text, text)
from public, anon, authenticated;

comment on function public.bootstrap_initial_owner(text, text) is
  'Promueve una única cuenta de Auth como primer owner, crea su recurso guía y la asigna a programaciones activas sin guía.';

-- =========================================================
-- 5. GESTIÓN DE PERSONAL
-- =========================================================

create or replace function public.set_staff_access(
  p_profile_id uuid,
  p_role public.app_role,
  p_is_active boolean
)
returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  v_target public.profiles;
begin
  if not public.current_user_has_role(
    array['owner','admin']::public.app_role[]
  ) then
    raise exception 'Solo owner o admin pueden cambiar accesos';
  end if;

  if p_role = 'owner'::public.app_role
     and not public.current_user_has_role(
       array['owner']::public.app_role[]
     )
  then
    raise exception 'Solo un owner puede nombrar a otro owner';
  end if;

  if p_profile_id = auth.uid()
     and p_is_active = false
  then
    raise exception 'No puedes desactivar tu propia cuenta';
  end if;

  update public.profiles
  set
    role = p_role,
    is_active = p_is_active
  where id = p_profile_id
  returning * into v_target;

  if v_target.id is null then
    raise exception 'Perfil no encontrado';
  end if;

  return v_target;
end;
$$;

revoke all on function public.set_staff_access(uuid, public.app_role, boolean)
from public, anon;

grant execute on function public.set_staff_access(
  uuid,
  public.app_role,
  boolean
) to authenticated;

-- =========================================================
-- 6. RLS DE PROFILES
-- =========================================================

alter table public.profiles enable row level security;

drop policy if exists profiles_read_own on public.profiles;
create policy profiles_read_own
on public.profiles
for select
to authenticated
using (id = auth.uid());

drop policy if exists profiles_staff_directory_read on public.profiles;
create policy profiles_staff_directory_read
on public.profiles
for select
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  )
);

drop policy if exists profiles_update_own_safe_fields on public.profiles;
-- Las actualizaciones del propio perfil se hacen mediante update_my_profile().
-- No se concede UPDATE directo para impedir cambios de role/is_active.

drop policy if exists profiles_admin_write on public.profiles;
create policy profiles_admin_write
on public.profiles
for update
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin']::public.app_role[]
  )
)
with check (
  public.current_user_has_role(
    array['owner','admin']::public.app_role[]
  )
);

-- =========================================================
-- 7. VISTA SEGURA DEL DIRECTORIO
-- =========================================================

create or replace view public.staff_directory
with (security_invoker = true)
as
select
  p.id,
  p.email,
  p.full_name,
  p.display_name,
  p.phone,
  p.avatar_url,
  p.role,
  p.is_active,
  p.minimum_start_gap_minutes,
  p.invited_at,
  p.accepted_at,
  p.last_seen_at,
  r.id as guide_resource_id,
  r.status as resource_status
from public.profiles p
left join public.resources r
  on r.profile_id = p.id
 and r.kind = 'guide'::public.resource_kind;

grant select on public.staff_directory to authenticated;

commit;
