-- Explora Booking
-- Arquitectura funcional v1
-- Migración H: Colaboradores comerciales y atribución de reservas
-- Fecha: 2026-08-08
--
-- OBJETIVO
-- -------
-- Crear el módulo comercial de COLABORADORES:
-- hoteles, apartamentos, alojamientos, oficinas, comercios u otros
-- prescriptores que recomiendan o derivan clientes a Explora Trujillo.
--
-- PRINCIPIOS
-- ----------
-- - COLABORADOR COMERCIAL != usuario (profiles).
-- - COLABORADOR COMERCIAL != guía/recurso (resources).
-- - COLABORADOR COMERCIAL != proveedor de inventario (inventory_suppliers).
-- - COLABORADOR COMERCIAL != canal de venta (sales_channels).
-- - Una reserva puede tener un canal (WEB, PHONE, CIVITATIS...) y,
--   además, estar atribuida a un colaborador comercial.
-- - La atribución queda fotografiada en el momento de la reserva.
-- - Las condiciones comerciales pueden existir, pero esta migración NO
--   calcula liquidaciones ni pagos al colaborador.
-- - Las liquidaciones/comisiones efectivas se construirán después.
-- - Los informes futuros serán de solo lectura sobre estos datos.

begin;

-- =========================================================
-- 1. TIPOS ENUMERADOS
-- =========================================================

do $$
begin
  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'commercial_collaborator_kind'
      and n.nspname = 'public'
  ) then
    create type public.commercial_collaborator_kind as enum (
      'hotel',
      'apartment',
      'accommodation',
      'tourism_office',
      'restaurant',
      'shop',
      'agency',
      'other'
    );
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'commercial_collaborator_status'
      and n.nspname = 'public'
  ) then
    create type public.commercial_collaborator_status as enum (
      'active',
      'inactive',
      'archived'
    );
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'commercial_commission_type'
      and n.nspname = 'public'
  ) then
    create type public.commercial_commission_type as enum (
      'none',
      'fixed_per_booking',
      'fixed_per_participant',
      'percentage'
    );
  end if;
end
$$;

-- =========================================================
-- 2. COLABORADORES COMERCIALES
-- =========================================================

create table if not exists public.commercial_collaborators (
  id uuid primary key default gen_random_uuid(),
  code text not null,
  name text not null,
  kind public.commercial_collaborator_kind not null default 'other',
  status public.commercial_collaborator_status not null default 'active',
  contact_name text,
  email text,
  phone text,
  website text,
  address_text text,
  locality text,
  internal_notes text,
  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint commercial_collaborators_code_not_blank
    check (length(trim(code)) > 0),
  constraint commercial_collaborators_name_not_blank
    check (length(trim(name)) > 0)
);

create unique index if not exists uq_commercial_collaborators_code_ci
  on public.commercial_collaborators(lower(code));

create index if not exists idx_commercial_collaborators_status_kind
  on public.commercial_collaborators(status, kind, name);

drop trigger if exists trg_commercial_collaborators_set_updated_at
  on public.commercial_collaborators;

create trigger trg_commercial_collaborators_set_updated_at
before update on public.commercial_collaborators
for each row execute function public.set_updated_at();

comment on table public.commercial_collaborators is
  'Hoteles, apartamentos, alojamientos, oficinas, comercios u otros prescriptores que derivan clientes. No son canales de venta ni usuarios.';

-- =========================================================
-- 3. CONDICIONES COMERCIALES
-- =========================================================

create table if not exists public.commercial_collaborator_terms (
  id uuid primary key default gen_random_uuid(),
  collaborator_id uuid not null
    references public.commercial_collaborators(id) on delete cascade,
  commission_type public.commercial_commission_type
    not null default 'none',
  fixed_amount_cents integer,
  percentage_basis_points integer,
  currency char(3) not null default 'EUR',
  valid_from date,
  valid_until date,
  is_active boolean not null default true,
  notes text,
  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint commercial_terms_fixed_valid
    check (fixed_amount_cents is null or fixed_amount_cents >= 0),
  constraint commercial_terms_percentage_valid
    check (
      percentage_basis_points is null
      or (percentage_basis_points >= 0 and percentage_basis_points <= 10000)
    ),
  constraint commercial_terms_currency_format
    check (currency ~ '^[A-Z]{3}$'),
  constraint commercial_terms_dates_valid
    check (valid_from is null or valid_until is null or valid_from <= valid_until),
  constraint commercial_terms_values_consistent
    check (
      (commission_type = 'none'::public.commercial_commission_type
        and fixed_amount_cents is null
        and percentage_basis_points is null)
      or
      (commission_type in (
          'fixed_per_booking'::public.commercial_commission_type,
          'fixed_per_participant'::public.commercial_commission_type
        )
        and fixed_amount_cents is not null
        and percentage_basis_points is null)
      or
      (commission_type = 'percentage'::public.commercial_commission_type
        and percentage_basis_points is not null
        and fixed_amount_cents is null)
    )
);

create index if not exists idx_commercial_terms_collaborator_active
  on public.commercial_collaborator_terms(collaborator_id, is_active, valid_from, valid_until);

drop trigger if exists trg_commercial_collaborator_terms_set_updated_at
  on public.commercial_collaborator_terms;

create trigger trg_commercial_collaborator_terms_set_updated_at
before update on public.commercial_collaborator_terms
for each row execute function public.set_updated_at();

-- =========================================================
-- 4. ATRIBUCIÓN DE RESERVA A COLABORADOR
-- =========================================================

create table if not exists public.booking_commercial_attributions (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null
    references public.bookings(id) on delete cascade,
  collaborator_id uuid not null
    references public.commercial_collaborators(id) on delete restrict,
  collaborator_code_snapshot text not null,
  collaborator_name_snapshot text not null,
  terms_id uuid
    references public.commercial_collaborator_terms(id) on delete set null,
  commission_type_snapshot public.commercial_commission_type
    not null default 'none',
  fixed_amount_cents_snapshot integer,
  percentage_basis_points_snapshot integer,
  currency_snapshot char(3) not null default 'EUR',
  referral_note text,
  attributed_at timestamptz not null default now(),
  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint booking_commercial_attributions_booking_unique unique (booking_id),
  constraint booking_commercial_attributions_code_not_blank
    check (length(trim(collaborator_code_snapshot)) > 0),
  constraint booking_commercial_attributions_name_not_blank
    check (length(trim(collaborator_name_snapshot)) > 0),
  constraint booking_commercial_attributions_fixed_valid
    check (fixed_amount_cents_snapshot is null or fixed_amount_cents_snapshot >= 0),
  constraint booking_commercial_attributions_percentage_valid
    check (
      percentage_basis_points_snapshot is null
      or (percentage_basis_points_snapshot >= 0 and percentage_basis_points_snapshot <= 10000)
    ),
  constraint booking_commercial_attributions_currency_format
    check (currency_snapshot ~ '^[A-Z]{3}$')
);

create index if not exists idx_booking_commercial_attributions_collaborator
  on public.booking_commercial_attributions(collaborator_id, attributed_at desc);

drop trigger if exists trg_booking_commercial_attributions_set_updated_at
  on public.booking_commercial_attributions;

create trigger trg_booking_commercial_attributions_set_updated_at
before update on public.booking_commercial_attributions
for each row execute function public.set_updated_at();

comment on table public.booking_commercial_attributions is
  'Atribución de una Reserva a un colaborador comercial. Canal de venta y colaborador son dimensiones independientes.';

-- =========================================================
-- 5. FUNCIÓN AUXILIAR: CONDICIÓN VIGENTE
-- =========================================================

create or replace function public.get_active_collaborator_terms_v1(
  p_collaborator_id uuid,
  p_reference_date date default current_date
)
returns table (
  terms_id uuid,
  commission_type public.commercial_commission_type,
  fixed_amount_cents integer,
  percentage_basis_points integer,
  currency char(3)
)
language sql
stable
security invoker
set search_path = public
as $$
  select
    t.id,
    t.commission_type,
    t.fixed_amount_cents,
    t.percentage_basis_points,
    t.currency
  from public.commercial_collaborator_terms t
  where t.collaborator_id = p_collaborator_id
    and t.is_active = true
    and (t.valid_from is null or t.valid_from <= p_reference_date)
    and (t.valid_until is null or t.valid_until >= p_reference_date)
  order by t.valid_from desc nulls last, t.created_at desc
  limit 1;
$$;

-- =========================================================
-- 6. RPC: CREAR COLABORADOR COMERCIAL
-- =========================================================

create or replace function public.create_commercial_collaborator_v1(
  p_code text,
  p_name text,
  p_kind public.commercial_collaborator_kind default 'other',
  p_contact_name text default null,
  p_email text default null,
  p_phone text default null,
  p_website text default null,
  p_address_text text default null,
  p_locality text default null,
  p_internal_notes text default null
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
    raise exception 'No autorizado para crear colaboradores comerciales';
  end if;

  if p_code is null or length(trim(p_code)) = 0 then
    raise exception 'El código del colaborador es obligatorio';
  end if;

  if p_name is null or length(trim(p_name)) < 2 then
    raise exception 'El nombre del colaborador debe tener al menos 2 caracteres';
  end if;

  insert into public.commercial_collaborators (
    code, name, kind, contact_name, email, phone, website,
    address_text, locality, internal_notes, created_by, updated_by
  )
  values (
    upper(trim(p_code)),
    trim(p_name),
    p_kind,
    nullif(trim(coalesce(p_contact_name, '')), ''),
    nullif(trim(coalesce(p_email, '')), ''),
    nullif(trim(coalesce(p_phone, '')), ''),
    nullif(trim(coalesce(p_website, '')), ''),
    nullif(trim(coalesce(p_address_text, '')), ''),
    nullif(trim(coalesce(p_locality, '')), ''),
    nullif(trim(coalesce(p_internal_notes, '')), ''),
    auth.uid(),
    auth.uid()
  )
  returning id into v_id;

  return v_id;
end;
$$;

-- =========================================================
-- 7. RPC: ATRIBUIR RESERVA A COLABORADOR
-- =========================================================

create or replace function public.assign_booking_collaborator_v1(
  p_booking_id uuid,
  p_collaborator_id uuid,
  p_referral_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings%rowtype;
  v_collaborator public.commercial_collaborators%rowtype;
  v_terms record;
  v_id uuid;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para atribuir colaboradores a reservas';
  end if;

  select * into v_booking
  from public.bookings
  where id = p_booking_id;

  if not found then
    raise exception 'Reserva no encontrada';
  end if;

  select * into v_collaborator
  from public.commercial_collaborators
  where id = p_collaborator_id;

  if not found then
    raise exception 'Colaborador comercial no encontrado';
  end if;

  if v_collaborator.status <> 'active'::public.commercial_collaborator_status then
    raise exception 'El colaborador comercial no está activo';
  end if;

  select * into v_terms
  from public.get_active_collaborator_terms_v1(
    p_collaborator_id,
    coalesce(v_booking.created_at::date, current_date)
  )
  limit 1;

  insert into public.booking_commercial_attributions (
    booking_id,
    collaborator_id,
    collaborator_code_snapshot,
    collaborator_name_snapshot,
    terms_id,
    commission_type_snapshot,
    fixed_amount_cents_snapshot,
    percentage_basis_points_snapshot,
    currency_snapshot,
    referral_note,
    created_by,
    updated_by
  )
  values (
    p_booking_id,
    p_collaborator_id,
    v_collaborator.code,
    v_collaborator.name,
    v_terms.terms_id,
    coalesce(v_terms.commission_type, 'none'::public.commercial_commission_type),
    v_terms.fixed_amount_cents,
    v_terms.percentage_basis_points,
    coalesce(v_terms.currency, 'EUR'),
    nullif(trim(coalesce(p_referral_note, '')), ''),
    auth.uid(),
    auth.uid()
  )
  on conflict (booking_id)
  do update set
    collaborator_id = excluded.collaborator_id,
    collaborator_code_snapshot = excluded.collaborator_code_snapshot,
    collaborator_name_snapshot = excluded.collaborator_name_snapshot,
    terms_id = excluded.terms_id,
    commission_type_snapshot = excluded.commission_type_snapshot,
    fixed_amount_cents_snapshot = excluded.fixed_amount_cents_snapshot,
    percentage_basis_points_snapshot = excluded.percentage_basis_points_snapshot,
    currency_snapshot = excluded.currency_snapshot,
    referral_note = excluded.referral_note,
    attributed_at = now(),
    updated_by = auth.uid()
  returning id into v_id;

  return v_id;
end;
$$;

-- =========================================================
-- 8. RPC: QUITAR ATRIBUCIÓN
-- =========================================================

create or replace function public.remove_booking_collaborator_v1(
  p_booking_id uuid
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
    raise exception 'No autorizado para modificar la atribución comercial';
  end if;

  select id into v_id
  from public.booking_commercial_attributions
  where booking_id = p_booking_id;

  if v_id is null then
    raise exception 'La Reserva no tiene colaborador comercial atribuido';
  end if;

  delete from public.booking_commercial_attributions
  where id = v_id;

  return v_id;
end;
$$;

-- =========================================================
-- 9. VISTA RESERVA + COLABORADOR
-- =========================================================

create or replace view public.booking_commercial_attribution_v1
with (security_invoker = true)
as
select
  b.id as booking_id,
  b.booking_reference,
  b.departure_id,
  b.channel_id,
  sc.code as channel_code,
  sc.name as channel_name,
  sc.channel_type,
  a.collaborator_id,
  a.collaborator_code_snapshot as collaborator_code,
  a.collaborator_name_snapshot as collaborator_name,
  c.kind as collaborator_kind,
  c.status as collaborator_status,
  a.commission_type_snapshot,
  a.fixed_amount_cents_snapshot,
  a.percentage_basis_points_snapshot,
  a.currency_snapshot,
  a.referral_note,
  a.attributed_at
from public.bookings b
left join public.sales_channels sc
  on sc.id = b.channel_id
left join public.booking_commercial_attributions a
  on a.booking_id = b.id
left join public.commercial_collaborators c
  on c.id = a.collaborator_id;

grant select on public.booking_commercial_attribution_v1
to authenticated;

-- =========================================================
-- 10. VISTA DE PRODUCCIÓN POR COLABORADOR
-- =========================================================

create or replace view public.commercial_collaborator_production_v1
with (security_invoker = true)
as
select
  c.id as collaborator_id,
  c.code,
  c.name,
  c.kind,
  c.status,
  count(a.booking_id) filter (
    where b.status = 'confirmed'::public.booking_status
  )::integer as confirmed_bookings,
  coalesce(sum(
    case
      when b.status = 'confirmed'::public.booking_status
      then (
        select coalesce(sum(bp.quantity), 0)
        from public.booking_participants bp
        where bp.booking_id = b.id
      )
      else 0
    end
  ), 0)::integer as booked_participants,
  coalesce(sum(
    case
      when b.status = 'confirmed'::public.booking_status
      then b.contracted_total_cents
      else 0
    end
  ), 0)::bigint as contracted_amount_cents,
  min(b.created_at) filter (
    where b.status = 'confirmed'::public.booking_status
  ) as first_confirmed_booking_at,
  max(b.created_at) filter (
    where b.status = 'confirmed'::public.booking_status
  ) as last_confirmed_booking_at
from public.commercial_collaborators c
left join public.booking_commercial_attributions a
  on a.collaborator_id = c.id
left join public.bookings b
  on b.id = a.booking_id
group by c.id, c.code, c.name, c.kind, c.status;

grant select on public.commercial_collaborator_production_v1
to authenticated;

-- =========================================================
-- 11. AUDITORÍA
-- =========================================================

drop trigger if exists trg_audit_commercial_collaborators
  on public.commercial_collaborators;
create trigger trg_audit_commercial_collaborators
after insert or update or delete on public.commercial_collaborators
for each row execute function public.write_audit_log();

drop trigger if exists trg_audit_commercial_collaborator_terms
  on public.commercial_collaborator_terms;
create trigger trg_audit_commercial_collaborator_terms
after insert or update or delete on public.commercial_collaborator_terms
for each row execute function public.write_audit_log();

drop trigger if exists trg_audit_booking_commercial_attributions
  on public.booking_commercial_attributions;
create trigger trg_audit_booking_commercial_attributions
after insert or update or delete on public.booking_commercial_attributions
for each row execute function public.write_audit_log();

-- =========================================================
-- 12. RLS
-- =========================================================

alter table public.commercial_collaborators enable row level security;
alter table public.commercial_collaborator_terms enable row level security;
alter table public.booking_commercial_attributions enable row level security;

drop policy if exists commercial_collaborators_staff_read
  on public.commercial_collaborators;
create policy commercial_collaborators_staff_read
on public.commercial_collaborators
for select
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager','guide','viewer']::public.app_role[]
  )
);

drop policy if exists commercial_collaborator_terms_management_read
  on public.commercial_collaborator_terms;
create policy commercial_collaborator_terms_management_read
on public.commercial_collaborator_terms
for select
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  )
);

drop policy if exists booking_commercial_attributions_staff_read
  on public.booking_commercial_attributions;
create policy booking_commercial_attributions_staff_read
on public.booking_commercial_attributions
for select
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager','guide','viewer']::public.app_role[]
  )
);

-- =========================================================
-- 13. PERMISOS RPC
-- =========================================================

revoke all on function public.create_commercial_collaborator_v1(
  text, text, public.commercial_collaborator_kind,
  text, text, text, text, text, text, text
) from public, anon;

grant execute on function public.create_commercial_collaborator_v1(
  text, text, public.commercial_collaborator_kind,
  text, text, text, text, text, text, text
) to authenticated;

revoke all on function public.assign_booking_collaborator_v1(uuid, uuid, text)
from public, anon;
grant execute on function public.assign_booking_collaborator_v1(uuid, uuid, text)
to authenticated;

revoke all on function public.remove_booking_collaborator_v1(uuid)
from public, anon;
grant execute on function public.remove_booking_collaborator_v1(uuid)
to authenticated;

comment on view public.booking_commercial_attribution_v1 is
  'Reserva enriquecida con canal y colaborador comercial, manteniendo ambas dimensiones separadas.';

comment on view public.commercial_collaborator_production_v1 is
  'Producción histórica por colaborador comercial. Solo lectura; no calcula ni liquida comisiones.';

commit;
