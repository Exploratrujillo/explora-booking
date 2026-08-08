-- Explora Booking
-- Arquitectura funcional v1
-- Migración J: Lista de espera y promociones
-- Fecha: 2026-08-08
--
-- OBJETIVO
-- -------
-- Completar dos dominios que ya estaban previstos en la configuración:
--   1) Lista de espera real por salida.
--   2) Promociones / códigos promocionales con aplicación fotografiada a la reserva.
--
-- PRINCIPIOS
-- ----------
-- - waitlist_enabled ya existe en experiences/departures: aquí se crea el motor real.
-- - promotions_enabled ya existe en experiences: aquí se crea el motor real.
-- - Una entrada en lista de espera NO es una reserva.
-- - La conversión a reserva queda trazada mediante converted_booking_id.
-- - Una promoción NO es un canal, colaborador, forma de pago ni tarifa.
-- - La reserva conserva contracted_total_cents como importe final congelado.
-- - La promoción aplicada queda fotografiada para que cambios posteriores no alteren el histórico.
-- - Arquitectura v1 admite una promoción principal por reserva.
-- - Esta migración no crea automatismos de email/SMS; solo deja el estado operativo preparado.

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
    where t.typname = 'waitlist_entry_status'
      and n.nspname = 'public'
  ) then
    create type public.waitlist_entry_status as enum (
      'waiting',
      'offered',
      'converted',
      'cancelled',
      'expired'
    );
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'promotion_status'
      and n.nspname = 'public'
  ) then
    create type public.promotion_status as enum (
      'draft',
      'active',
      'inactive',
      'archived'
    );
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'promotion_discount_type'
      and n.nspname = 'public'
  ) then
    create type public.promotion_discount_type as enum (
      'fixed_amount',
      'percentage'
    );
  end if;
end
$$;


-- =========================================================
-- 2. LISTA DE ESPERA
-- =========================================================

create table if not exists public.waitlist_entries (
  id uuid primary key default gen_random_uuid(),

  departure_id uuid not null
    references public.departures(id) on delete cascade,

  experience_id uuid not null
    references public.experiences(id) on delete restrict,

  status public.waitlist_entry_status not null default 'waiting',

  contact_name text not null,
  contact_email text,
  contact_phone text,
  contact_province text,

  requested_capacity integer not null,
  requested_adults integer not null default 0,

  customer_notes text,
  internal_notes text,

  joined_at timestamptz not null default now(),

  offered_at timestamptz,
  offer_expires_at timestamptz,

  converted_booking_id uuid
    references public.bookings(id) on delete set null,

  converted_at timestamptz,
  cancelled_at timestamptz,
  expired_at timestamptz,

  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint waitlist_entries_contact_name_not_blank
    check (length(trim(contact_name)) > 0),

  constraint waitlist_entries_requested_capacity_valid
    check (requested_capacity > 0),

  constraint waitlist_entries_requested_adults_valid
    check (
      requested_adults >= 0
      and requested_adults <= requested_capacity
    ),

  constraint waitlist_entries_offer_dates_valid
    check (
      offer_expires_at is null
      or offered_at is null
      or offer_expires_at > offered_at
    ),

  constraint waitlist_entries_status_coherent
    check (
      (
        status = 'waiting'::public.waitlist_entry_status
        and converted_booking_id is null
        and converted_at is null
        and cancelled_at is null
        and expired_at is null
      )
      or
      (
        status = 'offered'::public.waitlist_entry_status
        and offered_at is not null
        and converted_booking_id is null
        and converted_at is null
        and cancelled_at is null
        and expired_at is null
      )
      or
      (
        status = 'converted'::public.waitlist_entry_status
        and converted_booking_id is not null
        and converted_at is not null
        and cancelled_at is null
        and expired_at is null
      )
      or
      (
        status = 'cancelled'::public.waitlist_entry_status
        and cancelled_at is not null
        and converted_booking_id is null
      )
      or
      (
        status = 'expired'::public.waitlist_entry_status
        and expired_at is not null
        and converted_booking_id is null
      )
    )
);

create index if not exists idx_waitlist_entries_departure_status_joined
  on public.waitlist_entries(departure_id, status, joined_at);

create index if not exists idx_waitlist_entries_contact_phone
  on public.waitlist_entries(contact_phone);

create unique index if not exists uq_waitlist_entries_converted_booking
  on public.waitlist_entries(converted_booking_id)
  where converted_booking_id is not null;

drop trigger if exists trg_waitlist_entries_set_updated_at
  on public.waitlist_entries;

create trigger trg_waitlist_entries_set_updated_at
before update on public.waitlist_entries
for each row execute function public.set_updated_at();

comment on table public.waitlist_entries is
  'Solicitudes reales en lista de espera. Una entrada no consume capacidad y no es una Reserva hasta su conversión.';


-- =========================================================
-- 3. VALIDACIÓN DE SALIDA EN LISTA DE ESPERA
-- =========================================================

create or replace function public.validate_waitlist_entry_departure_v1()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_departure public.departures%rowtype;
begin
  select *
  into v_departure
  from public.departures
  where id = new.departure_id;

  if not found then
    raise exception 'Salida no encontrada';
  end if;

  if v_departure.experience_id <> new.experience_id then
    raise exception 'La experiencia no coincide con la salida';
  end if;

  if not v_departure.waitlist_enabled then
    raise exception 'La lista de espera no está habilitada para esta salida';
  end if;

  if v_departure.cancelled_at is not null then
    raise exception 'No se puede usar lista de espera en una salida cancelada';
  end if;

  if v_departure.finalized_at is not null then
    raise exception 'No se puede usar lista de espera en una salida finalizada';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_waitlist_entries_validate_departure
  on public.waitlist_entries;

create trigger trg_waitlist_entries_validate_departure
before insert or update of departure_id, experience_id
on public.waitlist_entries
for each row execute function public.validate_waitlist_entry_departure_v1();


-- =========================================================
-- 4. RPC: AÑADIR A LISTA DE ESPERA
-- =========================================================

create or replace function public.add_waitlist_entry_v1(
  p_departure_id uuid,
  p_contact_name text,
  p_requested_capacity integer,
  p_requested_adults integer default 0,
  p_contact_email text default null,
  p_contact_phone text default null,
  p_contact_province text default null,
  p_customer_notes text default null,
  p_internal_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_departure public.departures%rowtype;
  v_id uuid;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para gestionar la lista de espera';
  end if;

  select *
  into v_departure
  from public.departures
  where id = p_departure_id;

  if not found then
    raise exception 'Salida no encontrada';
  end if;

  if not v_departure.waitlist_enabled then
    raise exception 'La lista de espera no está habilitada para esta salida';
  end if;

  if v_departure.cancelled_at is not null
     or v_departure.finalized_at is not null
  then
    raise exception 'La salida no admite nuevas entradas en lista de espera';
  end if;

  if p_contact_name is null or length(trim(p_contact_name)) = 0 then
    raise exception 'El nombre de contacto es obligatorio';
  end if;

  if p_requested_capacity is null or p_requested_capacity <= 0 then
    raise exception 'El número de plazas solicitadas debe ser positivo';
  end if;

  if p_requested_adults is null
     or p_requested_adults < 0
     or p_requested_adults > p_requested_capacity
  then
    raise exception 'El número de adultos solicitado no es válido';
  end if;

  if nullif(trim(coalesce(p_contact_email, '')), '') is null
     and nullif(trim(coalesce(p_contact_phone, '')), '') is null
  then
    raise exception 'La lista de espera requiere email o teléfono de contacto';
  end if;

  insert into public.waitlist_entries (
    departure_id,
    experience_id,
    status,
    contact_name,
    contact_email,
    contact_phone,
    contact_province,
    requested_capacity,
    requested_adults,
    customer_notes,
    internal_notes,
    created_by,
    updated_by
  )
  values (
    p_departure_id,
    v_departure.experience_id,
    'waiting'::public.waitlist_entry_status,
    trim(p_contact_name),
    nullif(trim(coalesce(p_contact_email, '')), ''),
    nullif(trim(coalesce(p_contact_phone, '')), ''),
    nullif(trim(coalesce(p_contact_province, '')), ''),
    p_requested_capacity,
    p_requested_adults,
    nullif(trim(coalesce(p_customer_notes, '')), ''),
    nullif(trim(coalesce(p_internal_notes, '')), ''),
    auth.uid(),
    auth.uid()
  )
  returning id into v_id;

  return v_id;
end;
$$;


-- =========================================================
-- 5. RPC: OFRECER PLAZAS
-- =========================================================

create or replace function public.offer_waitlist_entry_v1(
  p_waitlist_entry_id uuid,
  p_offer_expires_at timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_entry public.waitlist_entries%rowtype;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para gestionar la lista de espera';
  end if;

  select *
  into v_entry
  from public.waitlist_entries
  where id = p_waitlist_entry_id
  for update;

  if not found then
    raise exception 'Entrada de lista de espera no encontrada';
  end if;

  if v_entry.status <> 'waiting'::public.waitlist_entry_status then
    raise exception 'Solo se pueden ofrecer plazas a una entrada en espera';
  end if;

  if p_offer_expires_at is not null
     and p_offer_expires_at <= now()
  then
    raise exception 'La caducidad de la oferta debe estar en el futuro';
  end if;

  update public.waitlist_entries
  set
    status = 'offered'::public.waitlist_entry_status,
    offered_at = now(),
    offer_expires_at = p_offer_expires_at,
    updated_by = auth.uid()
  where id = p_waitlist_entry_id;

  return p_waitlist_entry_id;
end;
$$;


-- =========================================================
-- 6. RPC: CONVERTIR EN RESERVA
-- =========================================================
--
-- La Reserva debe existir previamente.
-- Esta función NO crea la Reserva porque su composición de precios,
-- participantes y canal pertenece al motor de Reservas.
-- Aquí solo se valida y registra la conversión.

create or replace function public.convert_waitlist_entry_v1(
  p_waitlist_entry_id uuid,
  p_booking_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_entry public.waitlist_entries%rowtype;
  v_booking public.bookings%rowtype;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para convertir lista de espera';
  end if;

  select *
  into v_entry
  from public.waitlist_entries
  where id = p_waitlist_entry_id
  for update;

  if not found then
    raise exception 'Entrada de lista de espera no encontrada';
  end if;

  if v_entry.status not in (
    'waiting'::public.waitlist_entry_status,
    'offered'::public.waitlist_entry_status
  ) then
    raise exception 'La entrada no está disponible para conversión';
  end if;

  select *
  into v_booking
  from public.bookings
  where id = p_booking_id;

  if not found then
    raise exception 'Reserva no encontrada';
  end if;

  if v_booking.status <> 'confirmed'::public.booking_status then
    raise exception 'La Reserva debe estar confirmada';
  end if;

  if v_booking.departure_id <> v_entry.departure_id then
    raise exception 'La Reserva pertenece a otra salida';
  end if;

  if v_booking.experience_id <> v_entry.experience_id then
    raise exception 'La Reserva pertenece a otra experiencia';
  end if;

  update public.waitlist_entries
  set
    status = 'converted'::public.waitlist_entry_status,
    converted_booking_id = p_booking_id,
    converted_at = now(),
    updated_by = auth.uid()
  where id = p_waitlist_entry_id;

  return p_waitlist_entry_id;
end;
$$;


-- =========================================================
-- 7. RPC: CANCELAR / EXPIRAR ENTRADA
-- =========================================================

create or replace function public.close_waitlist_entry_v1(
  p_waitlist_entry_id uuid,
  p_status public.waitlist_entry_status,
  p_internal_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_entry public.waitlist_entries%rowtype;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para gestionar la lista de espera';
  end if;

  if p_status not in (
    'cancelled'::public.waitlist_entry_status,
    'expired'::public.waitlist_entry_status
  ) then
    raise exception 'Estado de cierre no permitido';
  end if;

  select *
  into v_entry
  from public.waitlist_entries
  where id = p_waitlist_entry_id
  for update;

  if not found then
    raise exception 'Entrada de lista de espera no encontrada';
  end if;

  if v_entry.status = 'converted'::public.waitlist_entry_status then
    raise exception 'Una entrada convertida no puede cancelarse ni expirar';
  end if;

  update public.waitlist_entries
  set
    status = p_status,
    cancelled_at = case
      when p_status = 'cancelled'::public.waitlist_entry_status then now()
      else null
    end,
    expired_at = case
      when p_status = 'expired'::public.waitlist_entry_status then now()
      else null
    end,
    internal_notes = coalesce(
      nullif(trim(coalesce(p_internal_notes, '')), ''),
      internal_notes
    ),
    updated_by = auth.uid()
  where id = p_waitlist_entry_id;

  return p_waitlist_entry_id;
end;
$$;


-- =========================================================
-- 8. VISTA: COLA OPERATIVA
-- =========================================================

create or replace view public.waitlist_queue_v1
with (security_invoker = true)
as
select
  w.id as waitlist_entry_id,
  w.departure_id,
  w.experience_id,
  d.starts_at,

  w.status,
  w.contact_name,
  w.contact_email,
  w.contact_phone,

  w.requested_capacity,
  w.requested_adults,

  w.joined_at,
  w.offered_at,
  w.offer_expires_at,

  row_number() over (
    partition by w.departure_id
    order by
      case
        when w.status = 'offered'::public.waitlist_entry_status then 0
        else 1
      end,
      w.joined_at,
      w.id
  )::integer as queue_position,

  d.capacity,
  d.reserved_capacity,
  d.blocked_seats,
  d.nominal_available_capacity

from public.waitlist_entries w
join public.departure_operational_v1 d
  on d.id = w.departure_id
where w.status in (
  'waiting'::public.waitlist_entry_status,
  'offered'::public.waitlist_entry_status
);

grant select on public.waitlist_queue_v1
to authenticated;


-- =========================================================
-- 9. VISTA: RESUMEN DE LISTA DE ESPERA POR SALIDA
-- =========================================================

create or replace view public.departure_waitlist_summary_v1
with (security_invoker = true)
as
select
  d.id as departure_id,

  count(w.id) filter (
    where w.status = 'waiting'::public.waitlist_entry_status
  )::integer as waiting_entries,

  coalesce(sum(w.requested_capacity) filter (
    where w.status = 'waiting'::public.waitlist_entry_status
  ), 0)::integer as waiting_requested_capacity,

  count(w.id) filter (
    where w.status = 'offered'::public.waitlist_entry_status
  )::integer as offered_entries,

  coalesce(sum(w.requested_capacity) filter (
    where w.status = 'offered'::public.waitlist_entry_status
  ), 0)::integer as offered_requested_capacity

from public.departures d
left join public.waitlist_entries w
  on w.departure_id = d.id
group by d.id;

grant select on public.departure_waitlist_summary_v1
to authenticated;


-- =========================================================
-- 10. PROMOCIONES
-- =========================================================

create table if not exists public.promotions (
  id uuid primary key default gen_random_uuid(),

  code text not null,
  name text not null,
  description text,

  status public.promotion_status not null default 'draft',

  discount_type public.promotion_discount_type not null,

  fixed_amount_cents integer,
  percentage_basis_points integer,

  currency char(3) not null default 'EUR',

  valid_from timestamptz,
  valid_until timestamptz,

  minimum_booking_amount_cents integer not null default 0,
  maximum_discount_cents integer,

  max_total_uses integer,
  current_use_count integer not null default 0,

  internal_notes text,

  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint promotions_code_not_blank
    check (length(trim(code)) > 0),

  constraint promotions_name_not_blank
    check (length(trim(name)) > 0),

  constraint promotions_currency_format
    check (currency ~ '^[A-Z]{3}$'),

  constraint promotions_fixed_valid
    check (fixed_amount_cents is null or fixed_amount_cents >= 0),

  constraint promotions_percentage_valid
    check (
      percentage_basis_points is null
      or (
        percentage_basis_points >= 0
        and percentage_basis_points <= 10000
      )
    ),

  constraint promotions_discount_value_consistent
    check (
      (
        discount_type = 'fixed_amount'::public.promotion_discount_type
        and fixed_amount_cents is not null
        and percentage_basis_points is null
      )
      or
      (
        discount_type = 'percentage'::public.promotion_discount_type
        and percentage_basis_points is not null
        and fixed_amount_cents is null
      )
    ),

  constraint promotions_dates_valid
    check (
      valid_from is null
      or valid_until is null
      or valid_from < valid_until
    ),

  constraint promotions_minimum_amount_valid
    check (minimum_booking_amount_cents >= 0),

  constraint promotions_maximum_discount_valid
    check (
      maximum_discount_cents is null
      or maximum_discount_cents >= 0
    ),

  constraint promotions_max_total_uses_valid
    check (
      max_total_uses is null
      or max_total_uses > 0
    ),

  constraint promotions_current_use_count_valid
    check (current_use_count >= 0)
);

create unique index if not exists uq_promotions_code_ci
  on public.promotions(lower(code));

create index if not exists idx_promotions_status_dates
  on public.promotions(status, valid_from, valid_until);

drop trigger if exists trg_promotions_set_updated_at
  on public.promotions;

create trigger trg_promotions_set_updated_at
before update on public.promotions
for each row execute function public.set_updated_at();


-- =========================================================
-- 11. PROMOCIONES POR EXPERIENCIA
-- =========================================================
--
-- Si una promoción no tiene filas aquí, puede aplicarse a cualquier
-- experiencia que tenga promotions_enabled=true.
-- Si tiene filas, solo es válida para esas experiencias.

create table if not exists public.promotion_experiences (
  promotion_id uuid not null
    references public.promotions(id) on delete cascade,

  experience_id uuid not null
    references public.experiences(id) on delete cascade,

  created_at timestamptz not null default now(),

  primary key (promotion_id, experience_id)
);

create index if not exists idx_promotion_experiences_experience
  on public.promotion_experiences(experience_id, promotion_id);


-- =========================================================
-- 12. PROMOCIÓN FOTOGRAFIADA EN RESERVA
-- =========================================================

create table if not exists public.booking_promotions (
  id uuid primary key default gen_random_uuid(),

  booking_id uuid not null
    references public.bookings(id) on delete cascade,

  promotion_id uuid
    references public.promotions(id) on delete set null,

  promotion_code_snapshot text not null,
  promotion_name_snapshot text not null,

  discount_type_snapshot public.promotion_discount_type not null,

  fixed_amount_cents_snapshot integer,
  percentage_basis_points_snapshot integer,

  currency_snapshot char(3) not null default 'EUR',

  pre_discount_total_cents integer not null,
  discount_amount_cents integer not null,
  final_total_cents_snapshot integer not null,

  applied_at timestamptz not null default now(),

  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),

  constraint booking_promotions_booking_unique
    unique (booking_id),

  constraint booking_promotions_code_not_blank
    check (length(trim(promotion_code_snapshot)) > 0),

  constraint booking_promotions_name_not_blank
    check (length(trim(promotion_name_snapshot)) > 0),

  constraint booking_promotions_currency_format
    check (currency_snapshot ~ '^[A-Z]{3}$'),

  constraint booking_promotions_amounts_valid
    check (
      pre_discount_total_cents >= 0
      and discount_amount_cents >= 0
      and final_total_cents_snapshot >= 0
      and discount_amount_cents <= pre_discount_total_cents
      and final_total_cents_snapshot =
        pre_discount_total_cents - discount_amount_cents
    )
);

create index if not exists idx_booking_promotions_promotion
  on public.booking_promotions(promotion_id, applied_at);


-- =========================================================
-- 13. FUNCIÓN: CALCULAR PROMOCIÓN
-- =========================================================

create or replace function public.calculate_promotion_discount_v1(
  p_code text,
  p_experience_id uuid,
  p_pre_discount_total_cents integer,
  p_reference_at timestamptz default now()
)
returns table (
  promotion_id uuid,
  promotion_code text,
  promotion_name text,
  discount_type public.promotion_discount_type,
  fixed_amount_cents integer,
  percentage_basis_points integer,
  currency char(3),
  discount_amount_cents integer,
  final_total_cents integer
)
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_promotion public.promotions%rowtype;
  v_experience public.experiences%rowtype;
  v_discount integer;
begin
  if p_code is null or length(trim(p_code)) = 0 then
    raise exception 'El código promocional es obligatorio';
  end if;

  if p_pre_discount_total_cents is null
     or p_pre_discount_total_cents < 0
  then
    raise exception 'El importe previo al descuento no es válido';
  end if;

  select *
  into v_experience
  from public.experiences
  where id = p_experience_id;

  if not found then
    raise exception 'Experiencia no encontrada';
  end if;

  if not v_experience.promotions_enabled then
    raise exception 'Las promociones no están habilitadas para esta experiencia';
  end if;

  select *
  into v_promotion
  from public.promotions
  where lower(code) = lower(trim(p_code))
    and status = 'active'::public.promotion_status;

  if not found then
    raise exception 'Código promocional no válido';
  end if;

  if v_promotion.valid_from is not null
     and p_reference_at < v_promotion.valid_from
  then
    raise exception 'La promoción todavía no está vigente';
  end if;

  if v_promotion.valid_until is not null
     and p_reference_at > v_promotion.valid_until
  then
    raise exception 'La promoción ha caducado';
  end if;

  if p_pre_discount_total_cents < v_promotion.minimum_booking_amount_cents then
    raise exception 'La Reserva no alcanza el importe mínimo de la promoción';
  end if;

  if v_promotion.max_total_uses is not null
     and v_promotion.current_use_count >= v_promotion.max_total_uses
  then
    raise exception 'La promoción ha alcanzado su límite de usos';
  end if;

  if exists (
    select 1
    from public.promotion_experiences pe
    where pe.promotion_id = v_promotion.id
  )
  and not exists (
    select 1
    from public.promotion_experiences pe
    where pe.promotion_id = v_promotion.id
      and pe.experience_id = p_experience_id
  )
  then
    raise exception 'La promoción no es válida para esta experiencia';
  end if;

  if v_promotion.discount_type = 'fixed_amount'::public.promotion_discount_type then
    v_discount := least(
      v_promotion.fixed_amount_cents,
      p_pre_discount_total_cents
    );
  else
    v_discount := floor(
      p_pre_discount_total_cents::numeric
      * v_promotion.percentage_basis_points::numeric
      / 10000.0
    )::integer;
  end if;

  if v_promotion.maximum_discount_cents is not null then
    v_discount := least(v_discount, v_promotion.maximum_discount_cents);
  end if;

  return query
  select
    v_promotion.id,
    v_promotion.code,
    v_promotion.name,
    v_promotion.discount_type,
    v_promotion.fixed_amount_cents,
    v_promotion.percentage_basis_points,
    v_promotion.currency,
    v_discount,
    greatest(p_pre_discount_total_cents - v_discount, 0);
end;
$$;


-- =========================================================
-- 14. RPC: APLICAR PROMOCIÓN A RESERVA
-- =========================================================
--
-- Solo puede aplicarse si la Reserva no tiene movimientos de pago.
-- La función actualiza contracted_total_cents y guarda el snapshot.
-- Arquitectura v1 admite una promoción por Reserva.

create or replace function public.apply_booking_promotion_v1(
  p_booking_id uuid,
  p_code text,
  p_pre_discount_total_cents integer
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings%rowtype;
  v_calc record;
  v_id uuid;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para aplicar promociones';
  end if;

  select *
  into v_booking
  from public.bookings
  where id = p_booking_id
  for update;

  if not found then
    raise exception 'Reserva no encontrada';
  end if;

  if v_booking.status <> 'confirmed'::public.booking_status then
    raise exception 'Solo se pueden promocionar reservas confirmadas';
  end if;

  if exists (
    select 1
    from public.booking_payment_movements pm
    where pm.booking_id = p_booking_id
  ) then
    raise exception 'No se puede aplicar una promoción después de registrar pagos';
  end if;

  if exists (
    select 1
    from public.booking_promotions bp
    where bp.booking_id = p_booking_id
  ) then
    raise exception 'La Reserva ya tiene una promoción aplicada';
  end if;

  select *
  into v_calc
  from public.calculate_promotion_discount_v1(
    p_code,
    v_booking.experience_id,
    p_pre_discount_total_cents,
    now()
  );

  update public.bookings
  set
    contracted_total_cents = v_calc.final_total_cents,
    updated_by = auth.uid()
  where id = p_booking_id;

  insert into public.booking_promotions (
    booking_id,
    promotion_id,
    promotion_code_snapshot,
    promotion_name_snapshot,
    discount_type_snapshot,
    fixed_amount_cents_snapshot,
    percentage_basis_points_snapshot,
    currency_snapshot,
    pre_discount_total_cents,
    discount_amount_cents,
    final_total_cents_snapshot,
    created_by
  )
  values (
    p_booking_id,
    v_calc.promotion_id,
    v_calc.promotion_code,
    v_calc.promotion_name,
    v_calc.discount_type,
    v_calc.fixed_amount_cents,
    v_calc.percentage_basis_points,
    v_calc.currency,
    p_pre_discount_total_cents,
    v_calc.discount_amount_cents,
    v_calc.final_total_cents,
    auth.uid()
  )
  returning id into v_id;

  update public.promotions
  set
    current_use_count = current_use_count + 1,
    updated_by = auth.uid()
  where id = v_calc.promotion_id;

  return v_id;
end;
$$;


-- =========================================================
-- 15. RPC: RETIRAR PROMOCIÓN ANTES DE COBRO
-- =========================================================
--
-- Restaura el total previo fotografiado y decrementa el contador.
-- No se permite después de registrar pagos.

create or replace function public.remove_booking_promotion_v1(
  p_booking_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_snapshot public.booking_promotions%rowtype;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para retirar promociones';
  end if;

  if exists (
    select 1
    from public.booking_payment_movements pm
    where pm.booking_id = p_booking_id
  ) then
    raise exception 'No se puede retirar la promoción después de registrar pagos';
  end if;

  select *
  into v_snapshot
  from public.booking_promotions
  where booking_id = p_booking_id
  for update;

  if not found then
    raise exception 'La Reserva no tiene promoción aplicada';
  end if;

  update public.bookings
  set
    contracted_total_cents = v_snapshot.pre_discount_total_cents,
    updated_by = auth.uid()
  where id = p_booking_id;

  delete from public.booking_promotions
  where id = v_snapshot.id;

  if v_snapshot.promotion_id is not null then
    update public.promotions
    set
      current_use_count = greatest(current_use_count - 1, 0),
      updated_by = auth.uid()
    where id = v_snapshot.promotion_id;
  end if;

  return v_snapshot.id;
end;
$$;


-- =========================================================
-- 16. VISTA: PROMOCIONES ACTIVAS
-- =========================================================

create or replace view public.active_promotions_v1
with (security_invoker = true)
as
select
  p.id as promotion_id,
  p.code,
  p.name,
  p.description,
  p.discount_type,
  p.fixed_amount_cents,
  p.percentage_basis_points,
  p.currency,
  p.valid_from,
  p.valid_until,
  p.minimum_booking_amount_cents,
  p.maximum_discount_cents,
  p.max_total_uses,
  p.current_use_count,
  case
    when p.max_total_uses is null then null
    else greatest(p.max_total_uses - p.current_use_count, 0)
  end as remaining_uses
from public.promotions p
where p.status = 'active'::public.promotion_status
  and (p.valid_from is null or p.valid_from <= now())
  and (p.valid_until is null or p.valid_until >= now())
  and (
    p.max_total_uses is null
    or p.current_use_count < p.max_total_uses
  );

grant select on public.active_promotions_v1
to authenticated;


-- =========================================================
-- 17. VISTA: PROMOCIÓN APLICADA A RESERVA
-- =========================================================

create or replace view public.booking_promotion_v1
with (security_invoker = true)
as
select
  b.id as booking_id,
  b.booking_reference,
  b.experience_id,

  bp.promotion_id,
  bp.promotion_code_snapshot as promotion_code,
  bp.promotion_name_snapshot as promotion_name,
  bp.discount_type_snapshot,
  bp.fixed_amount_cents_snapshot,
  bp.percentage_basis_points_snapshot,
  bp.currency_snapshot,

  bp.pre_discount_total_cents,
  bp.discount_amount_cents,
  bp.final_total_cents_snapshot,

  b.contracted_total_cents as booking_contracted_total_cents,
  bp.applied_at

from public.bookings b
left join public.booking_promotions bp
  on bp.booking_id = b.id;

grant select on public.booking_promotion_v1
to authenticated;


-- =========================================================
-- 18. SITUACIONES OPERATIVAS DE LISTA DE ESPERA
-- =========================================================
--
-- A) Hay plazas disponibles y personas esperando.
-- B) Una oferta de plazas ha caducado y aún figura como offered.

create or replace view public.waitlist_operational_situations_v1
with (security_invoker = true)
as

select
  ('waitlist_capacity_available:' || d.id::text)::text as situation_key,
  'waitlist_capacity_available'::text as situation_type,
  d.id as departure_id,
  null::uuid as waitlist_entry_id,
  'high'::public.operational_priority as priority,
  'Hay plazas para la lista de espera'::text as title,
  (
    'Plazas disponibles: '
    || coalesce(d.nominal_available_capacity, 0)::text
    || '; solicitudes en espera: '
    || coalesce(ws.waiting_requested_capacity, 0)::text
  )::text as detail,
  d.starts_at as relevant_at

from public.departure_operational_v1 d
join public.departure_waitlist_summary_v1 ws
  on ws.departure_id = d.id
where d.operational_state = 'open'
  and coalesce(d.nominal_available_capacity, 0) > 0
  and ws.waiting_entries > 0

union all

select
  ('waitlist_offer_expired:' || w.id::text)::text,
  'waitlist_offer_expired'::text,
  w.departure_id,
  w.id,
  'high'::public.operational_priority,
  'Oferta de lista de espera caducada'::text,
  (
    'La oferta enviada a '
    || w.contact_name
    || ' ha superado su fecha límite'
  )::text,
  w.offer_expires_at

from public.waitlist_entries w
where w.status = 'offered'::public.waitlist_entry_status
  and w.offer_expires_at is not null
  and w.offer_expires_at < now();

grant select on public.waitlist_operational_situations_v1
to authenticated;


-- =========================================================
-- 19. AUDITORÍA
-- =========================================================

drop trigger if exists trg_audit_waitlist_entries
  on public.waitlist_entries;

create trigger trg_audit_waitlist_entries
after insert or update or delete on public.waitlist_entries
for each row execute function public.write_audit_log();

drop trigger if exists trg_audit_promotions
  on public.promotions;

create trigger trg_audit_promotions
after insert or update or delete on public.promotions
for each row execute function public.write_audit_log();

drop trigger if exists trg_audit_promotion_experiences
  on public.promotion_experiences;

create trigger trg_audit_promotion_experiences
after insert or update or delete on public.promotion_experiences
for each row execute function public.write_audit_log();

drop trigger if exists trg_audit_booking_promotions
  on public.booking_promotions;

create trigger trg_audit_booking_promotions
after insert or update or delete on public.booking_promotions
for each row execute function public.write_audit_log();


-- =========================================================
-- 20. RLS
-- =========================================================

alter table public.waitlist_entries enable row level security;
alter table public.promotions enable row level security;
alter table public.promotion_experiences enable row level security;
alter table public.booking_promotions enable row level security;

drop policy if exists waitlist_entries_management_read
  on public.waitlist_entries;

create policy waitlist_entries_management_read
on public.waitlist_entries
for select
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager','guide']::public.app_role[]
  )
);

drop policy if exists promotions_staff_read
  on public.promotions;

create policy promotions_staff_read
on public.promotions
for select
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager','viewer']::public.app_role[]
  )
);

drop policy if exists promotion_experiences_staff_read
  on public.promotion_experiences;

create policy promotion_experiences_staff_read
on public.promotion_experiences
for select
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager','viewer']::public.app_role[]
  )
);

drop policy if exists booking_promotions_staff_read
  on public.booking_promotions;

create policy booking_promotions_staff_read
on public.booking_promotions
for select
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager','guide','viewer']::public.app_role[]
  )
);


-- =========================================================
-- 21. PERMISOS RPC
-- =========================================================

revoke all on function public.add_waitlist_entry_v1(
  uuid,
  text,
  integer,
  integer,
  text,
  text,
  text,
  text,
  text
) from public, anon;

grant execute on function public.add_waitlist_entry_v1(
  uuid,
  text,
  integer,
  integer,
  text,
  text,
  text,
  text,
  text
) to authenticated;


revoke all on function public.offer_waitlist_entry_v1(
  uuid,
  timestamptz
) from public, anon;

grant execute on function public.offer_waitlist_entry_v1(
  uuid,
  timestamptz
) to authenticated;


revoke all on function public.convert_waitlist_entry_v1(
  uuid,
  uuid
) from public, anon;

grant execute on function public.convert_waitlist_entry_v1(
  uuid,
  uuid
) to authenticated;


revoke all on function public.close_waitlist_entry_v1(
  uuid,
  public.waitlist_entry_status,
  text
) from public, anon;

grant execute on function public.close_waitlist_entry_v1(
  uuid,
  public.waitlist_entry_status,
  text
) to authenticated;


revoke all on function public.apply_booking_promotion_v1(
  uuid,
  text,
  integer
) from public, anon;

grant execute on function public.apply_booking_promotion_v1(
  uuid,
  text,
  integer
) to authenticated;


revoke all on function public.remove_booking_promotion_v1(uuid)
from public, anon;

grant execute on function public.remove_booking_promotion_v1(uuid)
to authenticated;


-- =========================================================
-- 22. COMENTARIOS FINALES
-- =========================================================

comment on view public.waitlist_queue_v1 is
  'Cola operativa de lista de espera por salida. No consume inventario hasta convertirse en Reserva.';

comment on table public.promotions is
  'Códigos promocionales configurables. promotions_enabled de la experiencia actúa como interruptor de disponibilidad.';

comment on table public.booking_promotions is
  'Fotografía de la promoción aplicada a una Reserva y de su importe antes/después del descuento.';

commit;
