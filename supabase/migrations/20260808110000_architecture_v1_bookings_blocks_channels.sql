-- Explora Booking
-- Arquitectura funcional v1
-- Migración B: núcleo de Reservas, Canales y Bloqueos comerciales
-- Fecha: 2026-08-08
--
-- OBJETIVO
-- -------
-- Crear el núcleo comercial definitivo sin romper Sprint 1.3:
--   - canales de venta;
--   - exposición de plazas por canal y salida;
--   - reservas confirmadas/canceladas;
--   - desglose de participantes/precio congelado;
--   - bloqueos comerciales de tiempo o plazas;
--   - sincronización temporal con occupied_capacity y adult_minimum_count
--     para mantener compatibilidad con el backoffice existente.
--
-- NO incluye todavía:
--   - pagos/devoluciones;
--   - liquidaciones OTA;
--   - asistencia/No-Show;
--   - comunicaciones;
--   - colaboradores comerciales;
--   - inventario físico.
--
-- Esas piezas se incorporarán en migraciones posteriores.

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
    where t.typname = 'sales_channel_type'
      and n.nspname = 'public'
  ) then
    create type public.sales_channel_type as enum (
      'direct',
      'ota',
      'partner',
      'internal',
      'other'
    );
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'booking_status'
      and n.nspname = 'public'
  ) then
    create type public.booking_status as enum (
      'confirmed',
      'cancelled'
    );
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'booking_origin'
      and n.nspname = 'public'
  ) then
    create type public.booking_origin as enum (
      'web',
      'office',
      'guide',
      'ota_manual',
      'walk_in',
      'import',
      'other'
    );
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'commercial_block_type'
      and n.nspname = 'public'
  ) then
    create type public.commercial_block_type as enum (
      'time',
      'seats'
    );
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'commercial_block_status'
      and n.nspname = 'public'
  ) then
    create type public.commercial_block_status as enum (
      'active',
      'released',
      'converted'
    );
  end if;
end
$$;


-- =========================================================
-- 2. CANALES DE VENTA
-- =========================================================

create table if not exists public.sales_channels (
  id uuid primary key default gen_random_uuid(),

  code text not null,
  name text not null,
  channel_type public.sales_channel_type not null,
  is_active boolean not null default true,

  -- Se deja preparado para futuras integraciones/conciliaciones.
  external_platform_code text,
  internal_notes text,

  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint sales_channels_code_not_blank
    check (length(trim(code)) > 0),

  constraint sales_channels_name_not_blank
    check (length(trim(name)) > 0)
);

create unique index if not exists uq_sales_channels_code_ci
  on public.sales_channels(lower(code));

create index if not exists idx_sales_channels_active
  on public.sales_channels(is_active, channel_type, name);

drop trigger if exists trg_sales_channels_set_updated_at
  on public.sales_channels;

create trigger trg_sales_channels_set_updated_at
before update on public.sales_channels
for each row execute function public.set_updated_at();

comment on table public.sales_channels is
  'Canales por los que entra una reserva. Canal y colaborador comercial son dimensiones distintas.';


-- Canales base. Se pueden ampliar/desactivar desde Configuración.
insert into public.sales_channels (
  code,
  name,
  channel_type
)
values
  ('WEB', 'Web directa', 'direct'::public.sales_channel_type),
  ('PHONE', 'Teléfono / oficina', 'direct'::public.sales_channel_type),
  ('WALKIN', 'Walk-in', 'direct'::public.sales_channel_type),
  ('CIVITATIS', 'Civitatis', 'ota'::public.sales_channel_type),
  ('GETYOURGUIDE', 'GetYourGuide', 'ota'::public.sales_channel_type),
  ('VIATOR', 'Viator', 'ota'::public.sales_channel_type)
on conflict (lower(code)) do nothing;


-- =========================================================
-- 3. EXPOSICIÓN DE PLAZAS POR CANAL Y SALIDA
-- =========================================================
--
-- exposed_capacity NO es una cuota rígida ni la capacidad real.
-- Una salida de capacidad 25 puede tener 25 plazas expuestas
-- simultáneamente en varios canales.
--
-- El riesgo de sobreexposición se calculará; no se bloquea aquí.

create table if not exists public.departure_channels (
  id uuid primary key default gen_random_uuid(),

  departure_id uuid not null
    references public.departures(id) on delete cascade,

  channel_id uuid not null
    references public.sales_channels(id) on delete restrict,

  exposed_capacity integer not null default 0,
  is_open boolean not null default true,

  internal_notes text,

  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint departure_channels_exposed_capacity_valid
    check (exposed_capacity >= 0),

  constraint departure_channels_unique
    unique (departure_id, channel_id)
);

create index if not exists idx_departure_channels_departure
  on public.departure_channels(departure_id, is_open);

create index if not exists idx_departure_channels_channel
  on public.departure_channels(channel_id, departure_id);

drop trigger if exists trg_departure_channels_set_updated_at
  on public.departure_channels;

create trigger trg_departure_channels_set_updated_at
before update on public.departure_channels
for each row execute function public.set_updated_at();

comment on table public.departure_channels is
  'Exposición comercial de plazas por canal para una salida. No limita la capacidad real ni impide sobreexposición deliberada.';


-- =========================================================
-- 4. RESERVAS
-- =========================================================
--
-- La Reserva es el expediente de la contratación.
-- Conserva una fotografía de los datos de contacto y del importe
-- contratado. No depende de una ficha CRM de cliente.

create table if not exists public.bookings (
  id uuid primary key default gen_random_uuid(),

  departure_id uuid not null
    references public.departures(id) on delete restrict,

  experience_id uuid not null
    references public.experiences(id) on delete restrict,

  channel_id uuid
    references public.sales_channels(id) on delete restrict,

  status public.booking_status not null default 'confirmed',
  origin public.booking_origin not null default 'office',

  -- Localizador propio y referencia externa OTA/agencia.
  -- El localizador definitivo se generará mediante la capa de reserva.
  booking_reference text,
  external_reference text,

  -- Fotografía del contacto en el momento de la contratación.
  contact_name text not null,
  contact_phone text,
  contact_email text,
  contact_province text,

  -- Fotografía económica de lo contratado.
  currency char(3) not null default 'EUR',
  contracted_total_cents integer not null default 0,

  -- Datos operativos.
  internal_notes text,
  customer_notes text,

  confirmed_at timestamptz not null default now(),
  cancelled_at timestamptz,
  cancelled_by uuid references public.profiles(id) on delete set null,
  cancellation_reason text,

  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint bookings_contact_name_not_blank
    check (length(trim(contact_name)) > 0),

  constraint bookings_currency_format
    check (currency ~ '^[A-Z]{3}$'),

  constraint bookings_total_non_negative
    check (contracted_total_cents >= 0),

  constraint bookings_cancelled_fields_coherent
    check (
      (status = 'confirmed'::public.booking_status
        and cancelled_at is null)
      or
      (status = 'cancelled'::public.booking_status
        and cancelled_at is not null)
    )
);

create unique index if not exists uq_bookings_reference_ci
  on public.bookings(lower(booking_reference))
  where booking_reference is not null;

create index if not exists idx_bookings_departure_status
  on public.bookings(departure_id, status);

create index if not exists idx_bookings_experience_created
  on public.bookings(experience_id, created_at desc);

create index if not exists idx_bookings_channel_created
  on public.bookings(channel_id, created_at desc);

create index if not exists idx_bookings_contact_name
  on public.bookings(lower(contact_name));

create index if not exists idx_bookings_contact_phone
  on public.bookings(contact_phone)
  where contact_phone is not null;

create index if not exists idx_bookings_contact_email
  on public.bookings(lower(contact_email))
  where contact_email is not null;

drop trigger if exists trg_bookings_set_updated_at
  on public.bookings;

create trigger trg_bookings_set_updated_at
before update on public.bookings
for each row execute function public.set_updated_at();

comment on table public.bookings is
  'Expediente completo de una contratación. Confirmada o cancelada; no se usa un estado general pendiente.';

comment on column public.bookings.contracted_total_cents is
  'Importe final contratado, congelado en la Reserva. Los cambios posteriores de tarifa no lo reescriben.';


-- =========================================================
-- 5. DESGLOSE DE PARTICIPANTES / PRECIO CONGELADO
-- =========================================================
--
-- Una fila representa una categoría, no necesariamente una persona.
-- Ejemplo: Adulto x 4, Niño x 3.
--
-- price_rule_id conserva la procedencia cuando existe,
-- pero los datos económicos y de cómputo se fotografían para que
-- el histórico no dependa de cambios posteriores de Configuración.

create table if not exists public.booking_participants (
  id uuid primary key default gen_random_uuid(),

  booking_id uuid not null
    references public.bookings(id) on delete cascade,

  price_rule_id uuid
    references public.experience_price_rules(id) on delete set null,

  category public.participant_category not null,
  label text not null,
  quantity integer not null,

  unit_price_cents integer not null default 0,
  currency char(3) not null default 'EUR',

  counts_towards_capacity boolean not null default true,
  counts_as_adult_for_minimum boolean not null default false,

  -- Edad concreta opcional cuando sea útil, sin exigir una fila por persona.
  age_note text,

  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint booking_participants_label_not_blank
    check (length(trim(label)) > 0),

  constraint booking_participants_quantity_positive
    check (quantity > 0),

  constraint booking_participants_unit_price_non_negative
    check (unit_price_cents >= 0),

  constraint booking_participants_currency_format
    check (currency ~ '^[A-Z]{3}$')
);

create index if not exists idx_booking_participants_booking
  on public.booking_participants(booking_id);

drop trigger if exists trg_booking_participants_set_updated_at
  on public.booking_participants;

create trigger trg_booking_participants_set_updated_at
before update on public.booking_participants
for each row execute function public.set_updated_at();

comment on table public.booking_participants is
  'Desglose por categoría de una Reserva. Congela precio y reglas de cómputo aplicadas al contratar.';


-- =========================================================
-- 6. BLOQUEOS COMERCIALES
-- =========================================================
--
-- NO confundir con schedule blocks de Sprint 1.3.
--
-- TIME:
--   protege una franja para una privada/grupo todavía no confirmado.
--
-- SEATS:
--   protege un número determinado de plazas dentro de una Operativa.
--
-- Un bloqueo no es una Reserva pendiente.

create table if not exists public.commercial_blocks (
  id uuid primary key default gen_random_uuid(),

  block_type public.commercial_block_type not null,
  status public.commercial_block_status not null default 'active',

  experience_id uuid
    references public.experiences(id) on delete set null,

  departure_id uuid
    references public.departures(id) on delete restrict,

  -- Para bloqueos de tiempo.
  starts_at timestamptz,
  ends_at timestamptz,

  -- Para bloqueos de plazas.
  blocked_seats integer,

  -- Contacto / procedencia de la petición.
  contact_name text,
  contact_phone text,
  contact_email text,
  organization_name text,

  title text,
  internal_notes text,

  -- Hitos comerciales ligeros; no existe entidad Presupuesto.
  quote_sent_at timestamptz,
  quote_accepted_at timestamptz,

  released_at timestamptz,
  released_by uuid references public.profiles(id) on delete set null,
  release_reason text,

  converted_at timestamptz,
  converted_by uuid references public.profiles(id) on delete set null,
  converted_booking_id uuid
    references public.bookings(id) on delete set null,

  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint commercial_blocks_time_range_valid
    check (
      starts_at is null
      or ends_at is null
      or ends_at > starts_at
    ),

  constraint commercial_blocks_seats_positive
    check (
      blocked_seats is null
      or blocked_seats > 0
    ),

  constraint commercial_blocks_type_fields_valid
    check (
      (
        block_type = 'time'::public.commercial_block_type
        and starts_at is not null
        and ends_at is not null
        and blocked_seats is null
      )
      or
      (
        block_type = 'seats'::public.commercial_block_type
        and departure_id is not null
        and blocked_seats is not null
        and starts_at is null
        and ends_at is null
      )
    ),

  constraint commercial_blocks_status_fields_coherent
    check (
      (
        status = 'active'::public.commercial_block_status
        and released_at is null
        and converted_at is null
      )
      or
      (
        status = 'released'::public.commercial_block_status
        and released_at is not null
        and converted_at is null
      )
      or
      (
        status = 'converted'::public.commercial_block_status
        and converted_at is not null
        and converted_booking_id is not null
      )
    )
);

create index if not exists idx_commercial_blocks_status_time
  on public.commercial_blocks(status, starts_at);

create index if not exists idx_commercial_blocks_departure_status
  on public.commercial_blocks(departure_id, status)
  where departure_id is not null;

create index if not exists idx_commercial_blocks_contact_name
  on public.commercial_blocks(lower(contact_name))
  where contact_name is not null;

drop trigger if exists trg_commercial_blocks_set_updated_at
  on public.commercial_blocks;

create trigger trg_commercial_blocks_set_updated_at
before update on public.commercial_blocks
for each row execute function public.set_updated_at();

comment on table public.commercial_blocks is
  'Bloqueos comerciales temporales de tiempo o plazas. No son schedule blocks ni Reservas pendientes.';


-- =========================================================
-- 7. TOTALES DERIVADOS DE RESERVAS
-- =========================================================

create or replace view public.booking_capacity_totals_v1
with (security_invoker = true)
as
select
  b.departure_id,

  coalesce(
    sum(
      case
        when b.status = 'confirmed'::public.booking_status
         and bp.counts_towards_capacity
        then bp.quantity
        else 0
      end
    ),
    0
  )::integer as reserved_capacity,

  coalesce(
    sum(
      case
        when b.status = 'confirmed'::public.booking_status
         and bp.counts_as_adult_for_minimum
        then bp.quantity
        else 0
      end
    ),
    0
  )::integer as adult_minimum_count,

  coalesce(
    sum(
      case
        when b.status = 'confirmed'::public.booking_status
        then bp.quantity
        else 0
      end
    ),
    0
  )::integer as total_participants

from public.bookings b
left join public.booking_participants bp
  on bp.booking_id = b.id
group by b.departure_id;


create or replace view public.active_seat_blocks_v1
with (security_invoker = true)
as
select
  departure_id,
  coalesce(sum(blocked_seats), 0)::integer as blocked_seats
from public.commercial_blocks
where status = 'active'::public.commercial_block_status
  and block_type = 'seats'::public.commercial_block_type
group by departure_id;


-- =========================================================
-- 8. SINCRONIZACIÓN LEGACY DE OCUPACIÓN
-- =========================================================
--
-- occupied_capacity y adult_minimum_count siguen existiendo porque
-- Sprint 1.3 los usa. A partir de ahora se sincronizan desde Reservas.
--
-- La fuente definitiva pasa a ser bookings + booking_participants.

create or replace function public.recalculate_departure_booking_totals_v1(
  p_departure_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reserved_capacity integer := 0;
  v_adult_minimum_count integer := 0;
begin
  if p_departure_id is null then
    return;
  end if;

  select
    coalesce(t.reserved_capacity, 0),
    coalesce(t.adult_minimum_count, 0)
  into
    v_reserved_capacity,
    v_adult_minimum_count
  from public.booking_capacity_totals_v1 t
  where t.departure_id = p_departure_id;

  if not found then
    v_reserved_capacity := 0;
    v_adult_minimum_count := 0;
  end if;

  update public.departures
  set
    occupied_capacity = v_reserved_capacity,
    adult_minimum_count = v_adult_minimum_count
  where id = p_departure_id;
end;
$$;


create or replace function public.sync_booking_totals_after_booking_change_v1()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    perform public.recalculate_departure_booking_totals_v1(old.departure_id);
    return old;
  end if;

  perform public.recalculate_departure_booking_totals_v1(new.departure_id);

  if tg_op = 'UPDATE'
     and old.departure_id is distinct from new.departure_id
  then
    perform public.recalculate_departure_booking_totals_v1(old.departure_id);
  end if;

  return new;
end;
$$;

drop trigger if exists trg_bookings_sync_departure_totals_v1
  on public.bookings;

create trigger trg_bookings_sync_departure_totals_v1
after insert or update or delete on public.bookings
for each row execute function public.sync_booking_totals_after_booking_change_v1();


create or replace function public.sync_booking_totals_after_participant_change_v1()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking_id uuid;
  v_old_booking_id uuid;
  v_departure_id uuid;
begin
  if tg_op = 'DELETE' then
    v_booking_id := old.booking_id;
  else
    v_booking_id := new.booking_id;
  end if;

  select departure_id
  into v_departure_id
  from public.bookings
  where id = v_booking_id;

  perform public.recalculate_departure_booking_totals_v1(v_departure_id);

  if tg_op = 'UPDATE'
     and old.booking_id is distinct from new.booking_id
  then
    v_old_booking_id := old.booking_id;

    select departure_id
    into v_departure_id
    from public.bookings
    where id = v_old_booking_id;

    perform public.recalculate_departure_booking_totals_v1(v_departure_id);
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_booking_participants_sync_departure_totals_v1
  on public.booking_participants;

create trigger trg_booking_participants_sync_departure_totals_v1
after insert or update or delete on public.booking_participants
for each row execute function public.sync_booking_totals_after_participant_change_v1();


-- =========================================================
-- 9. VISTA OPERATIVA ENRIQUECIDA
-- =========================================================
--
-- PostgreSQL no permite que CREATE OR REPLACE VIEW renombre/reordene
-- columnas existentes. La vista creada en Migración A era transitoria,
-- por lo que la sustituimos explícitamente dentro de esta transacción.
-- No usamos CASCADE: si apareciera una dependencia inesperada, la
-- migración debe detenerse en lugar de borrar objetos relacionados.

drop view if exists public.departure_operational_v1;

create view public.departure_operational_v1
with (security_invoker = true)
as
select
  d.id,
  d.experience_id,
  d.schedule_id,
  d.starts_at,
  d.ends_at,

  d.capacity,
  d.minimum_adults,

  coalesce(bt.reserved_capacity, 0)::integer as reserved_capacity,
  coalesce(bt.adult_minimum_count, 0)::integer as adult_minimum_count,
  coalesce(bt.total_participants, 0)::integer as total_participants,
  coalesce(sb.blocked_seats, 0)::integer as blocked_seats,

  d.sales_open,
  d.cancelled_at,
  d.cancellation_reason,
  d.finalized_at,

  case
    when d.finalized_at is not null then 'finalized'
    when d.cancelled_at is not null then 'cancelled'
    when d.sales_open then 'open'
    else 'closed'
  end as operational_state,

  case
    when d.capacity is null then false
    when coalesce(bt.reserved_capacity, 0) > d.capacity then true
    else false
  end as over_capacity,

  case
    when coalesce(bt.adult_minimum_count, 0) >= d.minimum_adults
      then true
    else false
  end as minimum_reached,

  case
    when d.capacity is null then null
    else
      d.capacity
      - coalesce(bt.reserved_capacity, 0)
      - coalesce(sb.blocked_seats, 0)
  end::integer as nominal_available_capacity,

  d.status as legacy_status,
  d.occupied_capacity as legacy_occupied_capacity,
  d.adult_minimum_count as legacy_adult_minimum_count,

  d.kind,
  d.source,
  d.publication,
  d.created_at,
  d.updated_at

from public.departures d
left join public.booking_capacity_totals_v1 bt
  on bt.departure_id = d.id
left join public.active_seat_blocks_v1 sb
  on sb.departure_id = d.id;

grant select on public.departure_operational_v1
to authenticated;


-- =========================================================
-- 10. API SEGURA: CREAR RESERVA MANUAL
-- =========================================================
--
-- Recibe el desglose como JSONB:
-- [
--   {
--     "price_rule_id": "...uuid opcional...",
--     "category": "adult",
--     "label": "Adulto",
--     "quantity": 2,
--     "unit_price_cents": 950,
--     "currency": "EUR",
--     "counts_towards_capacity": true,
--     "counts_as_adult_for_minimum": true
--   }
-- ]
--
-- No bloquea una reserva por capacidad. La sobrecapacidad se muestra
-- posteriormente como situación/riesgo.

create or replace function public.create_manual_booking_v1(
  p_departure_id uuid,
  p_channel_id uuid,
  p_contact_name text,
  p_contact_phone text default null,
  p_contact_email text default null,
  p_contact_province text default null,
  p_booking_reference text default null,
  p_external_reference text default null,
  p_origin public.booking_origin default 'office',
  p_contracted_total_cents integer default 0,
  p_currency char(3) default 'EUR',
  p_participants jsonb default '[]'::jsonb,
  p_internal_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_departure public.departures%rowtype;
  v_booking_id uuid;
  v_item jsonb;
  v_category public.participant_category;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para crear Reservas manuales';
  end if;

  if p_departure_id is null then
    raise exception 'La salida es obligatoria';
  end if;

  if length(trim(coalesce(p_contact_name, ''))) = 0 then
    raise exception 'El nombre de contacto es obligatorio';
  end if;

  if p_contracted_total_cents < 0 then
    raise exception 'El importe contratado no puede ser negativo';
  end if;

  select *
  into v_departure
  from public.departures
  where id = p_departure_id
  for update;

  if not found then
    raise exception 'Salida no encontrada';
  end if;

  if v_departure.cancelled_at is not null then
    raise exception 'No se puede crear una Reserva sobre una salida cancelada';
  end if;

  if v_departure.finalized_at is not null then
    raise exception 'No se puede crear una Reserva sobre una visita finalizada';
  end if;

  insert into public.bookings (
    departure_id,
    experience_id,
    channel_id,
    status,
    origin,
    booking_reference,
    external_reference,
    contact_name,
    contact_phone,
    contact_email,
    contact_province,
    currency,
    contracted_total_cents,
    internal_notes,
    created_by,
    updated_by
  )
  values (
    v_departure.id,
    v_departure.experience_id,
    p_channel_id,
    'confirmed'::public.booking_status,
    p_origin,
    nullif(trim(coalesce(p_booking_reference, '')), ''),
    nullif(trim(coalesce(p_external_reference, '')), ''),
    trim(p_contact_name),
    nullif(trim(coalesce(p_contact_phone, '')), ''),
    nullif(trim(coalesce(p_contact_email, '')), ''),
    nullif(trim(coalesce(p_contact_province, '')), ''),
    upper(p_currency),
    p_contracted_total_cents,
    p_internal_notes,
    auth.uid(),
    auth.uid()
  )
  returning id into v_booking_id;

  if jsonb_typeof(p_participants) <> 'array' then
    raise exception 'El desglose de participantes debe ser un array JSON';
  end if;

  for v_item in
    select value from jsonb_array_elements(p_participants)
  loop
    begin
      v_category := (v_item->>'category')::public.participant_category;
    exception
      when invalid_text_representation then
        raise exception 'Categoría de participante no válida: %',
          v_item->>'category';
    end;

    insert into public.booking_participants (
      booking_id,
      price_rule_id,
      category,
      label,
      quantity,
      unit_price_cents,
      currency,
      counts_towards_capacity,
      counts_as_adult_for_minimum,
      age_note,
      created_by,
      updated_by
    )
    values (
      v_booking_id,
      nullif(v_item->>'price_rule_id', '')::uuid,
      v_category,
      coalesce(nullif(trim(v_item->>'label'), ''), v_category::text),
      coalesce((v_item->>'quantity')::integer, 0),
      coalesce((v_item->>'unit_price_cents')::integer, 0),
      upper(coalesce(nullif(v_item->>'currency', ''), p_currency)),
      coalesce((v_item->>'counts_towards_capacity')::boolean, true),
      coalesce((v_item->>'counts_as_adult_for_minimum')::boolean, false),
      nullif(trim(coalesce(v_item->>'age_note', '')), ''),
      auth.uid(),
      auth.uid()
    );
  end loop;

  perform public.recalculate_departure_booking_totals_v1(v_departure.id);

  return v_booking_id;
end;
$$;

revoke all on function public.create_manual_booking_v1(
  uuid, uuid, text, text, text, text, text, text,
  public.booking_origin, integer, char, jsonb, text
) from public, anon;

grant execute on function public.create_manual_booking_v1(
  uuid, uuid, text, text, text, text, text, text,
  public.booking_origin, integer, char, jsonb, text
) to authenticated;


-- =========================================================
-- 11. API SEGURA: CANCELAR RESERVA
-- =========================================================

create or replace function public.cancel_booking_v1(
  p_booking_id uuid,
  p_reason text
)
returns public.bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para cancelar Reservas';
  end if;

  if length(trim(coalesce(p_reason, ''))) < 3 then
    raise exception 'Debe indicarse un motivo de cancelación';
  end if;

  select *
  into v_booking
  from public.bookings
  where id = p_booking_id
  for update;

  if not found then
    raise exception 'Reserva no encontrada';
  end if;

  if v_booking.status = 'cancelled'::public.booking_status then
    return v_booking;
  end if;

  update public.bookings
  set
    status = 'cancelled'::public.booking_status,
    cancelled_at = now(),
    cancelled_by = auth.uid(),
    cancellation_reason = trim(p_reason),
    updated_by = auth.uid()
  where id = p_booking_id
  returning * into v_booking;

  perform public.recalculate_departure_booking_totals_v1(
    v_booking.departure_id
  );

  return v_booking;
end;
$$;

revoke all on function public.cancel_booking_v1(uuid, text)
from public, anon;

grant execute on function public.cancel_booking_v1(uuid, text)
to authenticated;


-- =========================================================
-- 12. API SEGURA: MODIFICAR CONTACTO DE RESERVA
-- =========================================================

create or replace function public.update_booking_contact_v1(
  p_booking_id uuid,
  p_contact_name text,
  p_contact_phone text default null,
  p_contact_email text default null,
  p_contact_province text default null
)
returns public.bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para modificar Reservas';
  end if;

  if length(trim(coalesce(p_contact_name, ''))) = 0 then
    raise exception 'El nombre de contacto es obligatorio';
  end if;

  update public.bookings
  set
    contact_name = trim(p_contact_name),
    contact_phone = nullif(trim(coalesce(p_contact_phone, '')), ''),
    contact_email = nullif(trim(coalesce(p_contact_email, '')), ''),
    contact_province = nullif(trim(coalesce(p_contact_province, '')), ''),
    updated_by = auth.uid()
  where id = p_booking_id
  returning * into v_booking;

  if v_booking.id is null then
    raise exception 'Reserva no encontrada';
  end if;

  return v_booking;
end;
$$;

revoke all on function public.update_booking_contact_v1(
  uuid, text, text, text, text
) from public, anon;

grant execute on function public.update_booking_contact_v1(
  uuid, text, text, text, text
) to authenticated;


-- =========================================================
-- 13. API SEGURA: CREAR BLOQUEO COMERCIAL
-- =========================================================

create or replace function public.create_commercial_block_v1(
  p_block_type public.commercial_block_type,
  p_experience_id uuid default null,
  p_departure_id uuid default null,
  p_starts_at timestamptz default null,
  p_ends_at timestamptz default null,
  p_blocked_seats integer default null,
  p_contact_name text default null,
  p_contact_phone text default null,
  p_contact_email text default null,
  p_organization_name text default null,
  p_title text default null,
  p_internal_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_block_id uuid;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para crear Bloqueos';
  end if;

  insert into public.commercial_blocks (
    block_type,
    status,
    experience_id,
    departure_id,
    starts_at,
    ends_at,
    blocked_seats,
    contact_name,
    contact_phone,
    contact_email,
    organization_name,
    title,
    internal_notes,
    created_by,
    updated_by
  )
  values (
    p_block_type,
    'active'::public.commercial_block_status,
    p_experience_id,
    p_departure_id,
    p_starts_at,
    p_ends_at,
    p_blocked_seats,
    nullif(trim(coalesce(p_contact_name, '')), ''),
    nullif(trim(coalesce(p_contact_phone, '')), ''),
    nullif(trim(coalesce(p_contact_email, '')), ''),
    nullif(trim(coalesce(p_organization_name, '')), ''),
    nullif(trim(coalesce(p_title, '')), ''),
    p_internal_notes,
    auth.uid(),
    auth.uid()
  )
  returning id into v_block_id;

  return v_block_id;
end;
$$;

revoke all on function public.create_commercial_block_v1(
  public.commercial_block_type, uuid, uuid, timestamptz, timestamptz,
  integer, text, text, text, text, text, text
) from public, anon;

grant execute on function public.create_commercial_block_v1(
  public.commercial_block_type, uuid, uuid, timestamptz, timestamptz,
  integer, text, text, text, text, text, text
) to authenticated;


-- =========================================================
-- 14. API SEGURA: LIBERAR BLOQUEO
-- =========================================================

create or replace function public.release_commercial_block_v1(
  p_block_id uuid,
  p_reason text default null
)
returns public.commercial_blocks
language plpgsql
security definer
set search_path = public
as $$
declare
  v_block public.commercial_blocks;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para liberar Bloqueos';
  end if;

  select *
  into v_block
  from public.commercial_blocks
  where id = p_block_id
  for update;

  if not found then
    raise exception 'Bloqueo no encontrado';
  end if;

  if v_block.status <> 'active'::public.commercial_block_status then
    return v_block;
  end if;

  update public.commercial_blocks
  set
    status = 'released'::public.commercial_block_status,
    released_at = now(),
    released_by = auth.uid(),
    release_reason = nullif(trim(coalesce(p_reason, '')), ''),
    updated_by = auth.uid()
  where id = p_block_id
  returning * into v_block;

  return v_block;
end;
$$;

revoke all on function public.release_commercial_block_v1(uuid, text)
from public, anon;

grant execute on function public.release_commercial_block_v1(uuid, text)
to authenticated;


-- =========================================================
-- 15. API SEGURA: CONVERTIR BLOQUEO EN RESERVA
-- =========================================================
--
-- La Reserva debe crearse antes con las condiciones finalmente
-- aceptadas. Esta función enlaza ambos expedientes y cierra el bloqueo.

create or replace function public.convert_commercial_block_v1(
  p_block_id uuid,
  p_booking_id uuid
)
returns public.commercial_blocks
language plpgsql
security definer
set search_path = public
as $$
declare
  v_block public.commercial_blocks;
  v_booking public.bookings;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para convertir Bloqueos';
  end if;

  select *
  into v_block
  from public.commercial_blocks
  where id = p_block_id
  for update;

  if not found then
    raise exception 'Bloqueo no encontrado';
  end if;

  if v_block.status <> 'active'::public.commercial_block_status then
    raise exception 'Solo se puede convertir un Bloqueo activo';
  end if;

  select *
  into v_booking
  from public.bookings
  where id = p_booking_id;

  if not found then
    raise exception 'Reserva no encontrada';
  end if;

  if v_booking.status <> 'confirmed'::public.booking_status then
    raise exception 'La Reserva asociada debe estar confirmada';
  end if;

  if v_block.block_type = 'seats'::public.commercial_block_type
     and v_block.departure_id is distinct from v_booking.departure_id
  then
    raise exception
      'El Bloqueo de plazas y la Reserva deben pertenecer a la misma salida';
  end if;

  update public.commercial_blocks
  set
    status = 'converted'::public.commercial_block_status,
    converted_at = now(),
    converted_by = auth.uid(),
    converted_booking_id = p_booking_id,
    updated_by = auth.uid()
  where id = p_block_id
  returning * into v_block;

  return v_block;
end;
$$;

revoke all on function public.convert_commercial_block_v1(uuid, uuid)
from public, anon;

grant execute on function public.convert_commercial_block_v1(uuid, uuid)
to authenticated;


-- =========================================================
-- 16. API SEGURA: EXPOSICIÓN POR CANAL
-- =========================================================

create or replace function public.set_departure_channel_exposure_v1(
  p_departure_id uuid,
  p_channel_id uuid,
  p_exposed_capacity integer,
  p_is_open boolean default true
)
returns public.departure_channels
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result public.departure_channels;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para modificar exposición por canal';
  end if;

  if p_exposed_capacity is null or p_exposed_capacity < 0 then
    raise exception 'Las plazas expuestas no pueden ser negativas';
  end if;

  if not exists (
    select 1
    from public.departures
    where id = p_departure_id
  ) then
    raise exception 'Salida no encontrada';
  end if;

  if not exists (
    select 1
    from public.sales_channels
    where id = p_channel_id
      and is_active = true
  ) then
    raise exception 'Canal no encontrado o inactivo';
  end if;

  insert into public.departure_channels (
    departure_id,
    channel_id,
    exposed_capacity,
    is_open,
    created_by,
    updated_by
  )
  values (
    p_departure_id,
    p_channel_id,
    p_exposed_capacity,
    p_is_open,
    auth.uid(),
    auth.uid()
  )
  on conflict (departure_id, channel_id)
  do update set
    exposed_capacity = excluded.exposed_capacity,
    is_open = excluded.is_open,
    updated_by = auth.uid()
  returning * into v_result;

  return v_result;
end;
$$;

revoke all on function public.set_departure_channel_exposure_v1(
  uuid, uuid, integer, boolean
) from public, anon;

grant execute on function public.set_departure_channel_exposure_v1(
  uuid, uuid, integer, boolean
) to authenticated;


-- =========================================================
-- 17. VISTA DE RIESGO POR CANALES
-- =========================================================

create or replace view public.departure_channel_risk_v1
with (security_invoker = true)
as
select
  d.id as departure_id,
  d.starts_at,
  d.capacity,

  coalesce(bt.reserved_capacity, 0)::integer as reserved_capacity,
  coalesce(sb.blocked_seats, 0)::integer as blocked_seats,

  coalesce(
    sum(
      case
        when dc.is_open then dc.exposed_capacity
        else 0
      end
    ),
    0
  )::integer as total_exposed_capacity,

  case
    when d.capacity is null then null
    else greatest(
      d.capacity
      - coalesce(bt.reserved_capacity, 0)
      - coalesce(sb.blocked_seats, 0),
      0
    )
  end::integer as nominal_remaining_capacity,

  case
    when d.capacity is null then false
    when coalesce(
      sum(
        case
          when dc.is_open then dc.exposed_capacity
          else 0
        end
      ),
      0
    )
    >
    greatest(
      d.capacity
      - coalesce(bt.reserved_capacity, 0)
      - coalesce(sb.blocked_seats, 0),
      0
    )
    then true
    else false
  end as overexposure_risk

from public.departures d
left join public.booking_capacity_totals_v1 bt
  on bt.departure_id = d.id
left join public.active_seat_blocks_v1 sb
  on sb.departure_id = d.id
left join public.departure_channels dc
  on dc.departure_id = d.id
group by
  d.id,
  d.starts_at,
  d.capacity,
  bt.reserved_capacity,
  sb.blocked_seats;

grant select on public.departure_channel_risk_v1
to authenticated;


-- =========================================================
-- 18. AUDITORÍA
-- =========================================================

drop trigger if exists trg_audit_sales_channels
  on public.sales_channels;

create trigger trg_audit_sales_channels
after insert or update or delete on public.sales_channels
for each row execute function public.write_audit_log();


drop trigger if exists trg_audit_departure_channels
  on public.departure_channels;

create trigger trg_audit_departure_channels
after insert or update or delete on public.departure_channels
for each row execute function public.write_audit_log();


drop trigger if exists trg_audit_bookings
  on public.bookings;

create trigger trg_audit_bookings
after insert or update or delete on public.bookings
for each row execute function public.write_audit_log();


drop trigger if exists trg_audit_booking_participants
  on public.booking_participants;

create trigger trg_audit_booking_participants
after insert or update or delete on public.booking_participants
for each row execute function public.write_audit_log();


drop trigger if exists trg_audit_commercial_blocks
  on public.commercial_blocks;

create trigger trg_audit_commercial_blocks
after insert or update or delete on public.commercial_blocks
for each row execute function public.write_audit_log();


-- =========================================================
-- 19. ROW LEVEL SECURITY
-- =========================================================
--
-- En esta fase el acceso normal es mediante RPCs seguras.
-- No se expone escritura directa al frontend.

alter table public.sales_channels enable row level security;
alter table public.departure_channels enable row level security;
alter table public.bookings enable row level security;
alter table public.booking_participants enable row level security;
alter table public.commercial_blocks enable row level security;


-- Lectura interna de canales.
drop policy if exists sales_channels_staff_read
  on public.sales_channels;

create policy sales_channels_staff_read
on public.sales_channels
for select
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager','guide','viewer']::public.app_role[]
  )
);


-- Reservas: inicialmente Oficina.
-- Modo Guía tendrá su política/RPC específica con permisos individuales
-- en la migración de usuarios/permisos.

drop policy if exists bookings_office_read
  on public.bookings;

create policy bookings_office_read
on public.bookings
for select
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  )
);


drop policy if exists booking_participants_office_read
  on public.booking_participants;

create policy booking_participants_office_read
on public.booking_participants
for select
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  )
);


drop policy if exists departure_channels_office_read
  on public.departure_channels;

create policy departure_channels_office_read
on public.departure_channels
for select
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  )
);


drop policy if exists commercial_blocks_office_read
  on public.commercial_blocks;

create policy commercial_blocks_office_read
on public.commercial_blocks
for select
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  )
);


-- =========================================================
-- 20. PERMISOS DE FUNCIONES AUXILIARES
-- =========================================================

revoke all on function public.recalculate_departure_booking_totals_v1(uuid)
from public, anon;

grant execute on function public.recalculate_departure_booking_totals_v1(uuid)
to authenticated;


-- =========================================================
-- 21. COMENTARIOS DE ARQUITECTURA
-- =========================================================

comment on view public.booking_capacity_totals_v1 is
  'Totales derivados de Reservas confirmadas. bookings + booking_participants son la fuente de verdad.';

comment on view public.active_seat_blocks_v1 is
  'Plazas protegidas temporalmente por Bloqueos comerciales activos.';

comment on view public.departure_channel_risk_v1 is
  'Lectura de exposición comercial por salida. Informa del riesgo; no toma decisiones de cierre de canales.';


commit;
