-- Explora Booking
-- Arquitectura funcional v1
-- Migración G: Inventario, compras y reposición
-- Fecha: 2026-08-08
--
-- OBJETIVO
-- -------
-- Crear un dominio independiente para controlar materiales consumibles:
-- cuadernillos, pegatinas, merchandising, material de visita, etc.
--
-- PRINCIPIOS
-- ----------
-- - NO reutiliza public.resources: resources son guías/vehículos/equipos/espacios asignables.
-- - NO mezcla proveedores de compra con COLABORADORES comerciales.
-- - El stock físico se calcula desde movimientos; no se guarda como cifra editable aislada.
-- - Los pedidos y sus recepciones quedan registrados.
-- - El sistema puede conocer:
--      * cuánto hay;
--      * cuánto está pedido;
--      * cuánto falta por recibir;
--      * qué stock mínimo queremos mantener;
--      * plazo habitual de reposición;
--      * coste unitario registrado.
-- - Las necesidades de próximas salidas se modelan mediante reglas por experiencia
--   y reservas actuales, pero no consumen stock hasta registrar el consumo real.
-- - Próxima salida podrá leer esta capa para mostrar checklist/preparación.
-- - Los costes imputables se construirán después sobre consumos reales y compras.

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
    where t.typname = 'inventory_item_status'
      and n.nspname = 'public'
  ) then
    create type public.inventory_item_status as enum (
      'active',
      'inactive',
      'archived'
    );
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'inventory_item_kind'
      and n.nspname = 'public'
  ) then
    create type public.inventory_item_kind as enum (
      'booklet',
      'sticker',
      'merchandise',
      'consumable',
      'other'
    );
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'inventory_movement_type'
      and n.nspname = 'public'
  ) then
    create type public.inventory_movement_type as enum (
      'initial',
      'purchase_receipt',
      'departure_consumption',
      'manual_consumption',
      'adjustment_in',
      'adjustment_out',
      'return_to_stock',
      'supplier_return'
    );
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'purchase_order_status'
      and n.nspname = 'public'
  ) then
    create type public.purchase_order_status as enum (
      'draft',
      'ordered',
      'partially_received',
      'received',
      'cancelled'
    );
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'inventory_requirement_basis'
      and n.nspname = 'public'
  ) then
    create type public.inventory_requirement_basis as enum (
      'per_departure',
      'per_participant',
      'per_adult',
      'per_child'
    );
  end if;
end
$$;


-- =========================================================
-- 2. PROVEEDORES DE COMPRA
-- =========================================================
--
-- Proveedores de materiales/mercancía.
-- NO son colaboradores comerciales que derivan clientes.

create table if not exists public.inventory_suppliers (
  id uuid primary key default gen_random_uuid(),

  name text not null,
  contact_name text,
  email text,
  phone text,
  website text,

  notes text,

  is_active boolean not null default true,

  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint inventory_suppliers_name_not_blank
    check (length(trim(name)) > 0)
);

create unique index if not exists uq_inventory_suppliers_name
  on public.inventory_suppliers(lower(name));

drop trigger if exists trg_inventory_suppliers_set_updated_at
  on public.inventory_suppliers;

create trigger trg_inventory_suppliers_set_updated_at
before update on public.inventory_suppliers
for each row execute function public.set_updated_at();


-- =========================================================
-- 3. ARTÍCULOS DE INVENTARIO
-- =========================================================

create table if not exists public.inventory_items (
  id uuid primary key default gen_random_uuid(),

  code text not null,
  name text not null,
  kind public.inventory_item_kind not null default 'consumable',
  status public.inventory_item_status not null default 'active',

  unit_label text not null default 'ud',

  preferred_supplier_id uuid
    references public.inventory_suppliers(id) on delete set null,

  -- Umbral de reposición.
  reorder_point integer not null default 0,

  -- Cantidad objetivo cuando se repone.
  target_stock integer,

  -- Plazo habitual del proveedor.
  lead_time_days integer not null default 0,

  -- Último coste unitario conocido, en céntimos.
  last_unit_cost_cents integer,
  currency char(3) not null default 'EUR',

  notes text,

  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint inventory_items_code_not_blank
    check (length(trim(code)) > 0),

  constraint inventory_items_name_not_blank
    check (length(trim(name)) > 0),

  constraint inventory_items_unit_label_not_blank
    check (length(trim(unit_label)) > 0),

  constraint inventory_items_reorder_point_valid
    check (reorder_point >= 0),

  constraint inventory_items_target_stock_valid
    check (target_stock is null or target_stock >= 0),

  constraint inventory_items_lead_time_valid
    check (lead_time_days >= 0),

  constraint inventory_items_cost_valid
    check (last_unit_cost_cents is null or last_unit_cost_cents >= 0),

  constraint inventory_items_currency_format
    check (currency ~ '^[A-Z]{3}$')
);

create unique index if not exists uq_inventory_items_code
  on public.inventory_items(upper(code));

create index if not exists idx_inventory_items_status_kind
  on public.inventory_items(status, kind, name);

drop trigger if exists trg_inventory_items_set_updated_at
  on public.inventory_items;

create trigger trg_inventory_items_set_updated_at
before update on public.inventory_items
for each row execute function public.set_updated_at();


-- =========================================================
-- 4. PEDIDOS DE COMPRA
-- =========================================================

create table if not exists public.purchase_orders (
  id uuid primary key default gen_random_uuid(),

  supplier_id uuid
    references public.inventory_suppliers(id) on delete set null,

  status public.purchase_order_status not null default 'draft',

  ordered_at timestamptz,
  expected_at timestamptz,
  received_at timestamptz,
  cancelled_at timestamptz,

  supplier_reference text,
  notes text,

  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint purchase_orders_dates_consistent
    check (
      expected_at is null
      or ordered_at is null
      or expected_at >= ordered_at
    )
);

create index if not exists idx_purchase_orders_status_expected
  on public.purchase_orders(status, expected_at);

drop trigger if exists trg_purchase_orders_set_updated_at
  on public.purchase_orders;

create trigger trg_purchase_orders_set_updated_at
before update on public.purchase_orders
for each row execute function public.set_updated_at();


create table if not exists public.purchase_order_lines (
  id uuid primary key default gen_random_uuid(),

  purchase_order_id uuid not null
    references public.purchase_orders(id) on delete cascade,

  inventory_item_id uuid not null
    references public.inventory_items(id) on delete restrict,

  ordered_quantity integer not null,
  received_quantity integer not null default 0,

  unit_cost_cents integer,
  currency char(3) not null default 'EUR',

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint purchase_order_lines_ordered_positive
    check (ordered_quantity > 0),

  constraint purchase_order_lines_received_valid
    check (
      received_quantity >= 0
      and received_quantity <= ordered_quantity
    ),

  constraint purchase_order_lines_unit_cost_valid
    check (unit_cost_cents is null or unit_cost_cents >= 0),

  constraint purchase_order_lines_currency_format
    check (currency ~ '^[A-Z]{3}$'),

  constraint purchase_order_lines_unique_item
    unique (purchase_order_id, inventory_item_id)
);

create index if not exists idx_purchase_order_lines_item
  on public.purchase_order_lines(inventory_item_id);

drop trigger if exists trg_purchase_order_lines_set_updated_at
  on public.purchase_order_lines;

create trigger trg_purchase_order_lines_set_updated_at
before update on public.purchase_order_lines
for each row execute function public.set_updated_at();


-- =========================================================
-- 5. MOVIMIENTOS DE STOCK
-- =========================================================
--
-- quantity_delta:
--   positivo = entra stock
--   negativo = sale stock

create table if not exists public.inventory_movements (
  id bigint generated always as identity primary key,

  inventory_item_id uuid not null
    references public.inventory_items(id) on delete restrict,

  movement_type public.inventory_movement_type not null,

  quantity_delta integer not null,

  unit_cost_cents integer,
  currency char(3) not null default 'EUR',

  purchase_order_line_id uuid
    references public.purchase_order_lines(id) on delete set null,

  departure_id uuid
    references public.departures(id) on delete set null,

  note text,

  occurred_at timestamptz not null default now(),
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),

  constraint inventory_movements_non_zero
    check (quantity_delta <> 0),

  constraint inventory_movements_unit_cost_valid
    check (unit_cost_cents is null or unit_cost_cents >= 0),

  constraint inventory_movements_currency_format
    check (currency ~ '^[A-Z]{3}$')
);

create index if not exists idx_inventory_movements_item_date
  on public.inventory_movements(inventory_item_id, occurred_at desc);

create index if not exists idx_inventory_movements_departure
  on public.inventory_movements(departure_id, occurred_at desc);

create index if not exists idx_inventory_movements_purchase_line
  on public.inventory_movements(purchase_order_line_id);


-- =========================================================
-- 6. REGLAS DE NECESIDAD POR EXPERIENCIA
-- =========================================================
--
-- Ejemplos:
--   1 cuadernillo por participante de Pequeños Exploradores.
--   1 pegatina por participante.
--   1 mapa por salida.
--
-- quantity_per_basis permite, por ejemplo:
--   per_participant + 1 => uno por persona
--   per_departure   + 2 => dos por salida

create table if not exists public.experience_inventory_requirements (
  id uuid primary key default gen_random_uuid(),

  experience_id uuid not null
    references public.experiences(id) on delete cascade,

  inventory_item_id uuid not null
    references public.inventory_items(id) on delete restrict,

  basis public.inventory_requirement_basis not null,
  quantity_per_basis integer not null default 1,

  is_active boolean not null default true,

  valid_from date,
  valid_until date,

  notes text,

  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint experience_inventory_requirement_quantity_valid
    check (quantity_per_basis > 0),

  constraint experience_inventory_requirement_dates_valid
    check (
      valid_from is null
      or valid_until is null
      or valid_from <= valid_until
    ),

  constraint experience_inventory_requirement_unique
    unique (experience_id, inventory_item_id, basis)
);

create index if not exists idx_experience_inventory_requirements_experience
  on public.experience_inventory_requirements(experience_id, is_active);

drop trigger if exists trg_experience_inventory_requirements_set_updated_at
  on public.experience_inventory_requirements;

create trigger trg_experience_inventory_requirements_set_updated_at
before update on public.experience_inventory_requirements
for each row execute function public.set_updated_at();


-- =========================================================
-- 7. VISTA: STOCK FÍSICO ACTUAL
-- =========================================================

create or replace view public.inventory_stock_v1
with (security_invoker = true)
as
select
  i.id as inventory_item_id,
  i.code,
  i.name,
  i.kind,
  i.status,
  i.unit_label,

  coalesce(sum(m.quantity_delta), 0)::integer as physical_stock,

  i.reorder_point,
  i.target_stock,
  i.lead_time_days,
  i.last_unit_cost_cents,
  i.currency,

  i.preferred_supplier_id

from public.inventory_items i
left join public.inventory_movements m
  on m.inventory_item_id = i.id
group by
  i.id,
  i.code,
  i.name,
  i.kind,
  i.status,
  i.unit_label,
  i.reorder_point,
  i.target_stock,
  i.lead_time_days,
  i.last_unit_cost_cents,
  i.currency,
  i.preferred_supplier_id;

grant select on public.inventory_stock_v1
to authenticated;


-- =========================================================
-- 8. VISTA: PEDIDOS PENDIENTES
-- =========================================================

create or replace view public.inventory_open_orders_v1
with (security_invoker = true)
as
select
  l.inventory_item_id,

  sum(
    case
      when o.status in (
        'ordered'::public.purchase_order_status,
        'partially_received'::public.purchase_order_status
      )
      then greatest(l.ordered_quantity - l.received_quantity, 0)
      else 0
    end
  )::integer as quantity_on_order,

  min(o.expected_at) filter (
    where o.status in (
      'ordered'::public.purchase_order_status,
      'partially_received'::public.purchase_order_status
    )
      and l.received_quantity < l.ordered_quantity
  ) as next_expected_at

from public.purchase_order_lines l
join public.purchase_orders o
  on o.id = l.purchase_order_id
group by l.inventory_item_id;

grant select on public.inventory_open_orders_v1
to authenticated;


-- =========================================================
-- 9. VISTA: NECESIDAD PREVISTA POR SALIDAS FUTURAS
-- =========================================================
--
-- Usa reservas confirmadas y participantes que consumen capacidad.
-- Para per_adult/per_child se usa booking_participants.category.
--
-- No descuenta stock: solo calcula necesidad prevista.

create or replace view public.departure_inventory_requirements_v1
with (security_invoker = true)
as
select
  d.id as departure_id,
  d.experience_id,
  d.starts_at,

  r.inventory_item_id,
  r.basis,

  (
    case r.basis
      when 'per_departure'::public.inventory_requirement_basis
        then r.quantity_per_basis

      when 'per_participant'::public.inventory_requirement_basis
        then r.quantity_per_basis * coalesce((
          select sum(bp.quantity)::integer
          from public.bookings b
          join public.booking_participants bp
            on bp.booking_id = b.id
          where b.departure_id = d.id
            and b.status = 'confirmed'::public.booking_status
            and bp.counts_towards_capacity = true
        ), 0)

      when 'per_adult'::public.inventory_requirement_basis
        then r.quantity_per_basis * coalesce((
          select sum(bp.quantity)::integer
          from public.bookings b
          join public.booking_participants bp
            on bp.booking_id = b.id
          where b.departure_id = d.id
            and b.status = 'confirmed'::public.booking_status
            and bp.category = 'adult'::public.participant_category
        ), 0)

      when 'per_child'::public.inventory_requirement_basis
        then r.quantity_per_basis * coalesce((
          select sum(bp.quantity)::integer
          from public.bookings b
          join public.booking_participants bp
            on bp.booking_id = b.id
          where b.departure_id = d.id
            and b.status = 'confirmed'::public.booking_status
            and bp.category = 'child'::public.participant_category
        ), 0)
    end
  )::integer as required_quantity

from public.departures d
join public.experience_inventory_requirements r
  on r.experience_id = d.experience_id
 and r.is_active = true
 and (r.valid_from is null or r.valid_from <= d.starts_at::date)
 and (r.valid_until is null or r.valid_until >= d.starts_at::date)

where d.cancelled_at is null
  and d.finalized_at is null;

grant select on public.departure_inventory_requirements_v1
to authenticated;


-- =========================================================
-- 10. VISTA: NECESIDAD FUTURA AGREGADA
-- =========================================================
--
-- Horizonte = lead_time_days del propio artículo.
-- Si lead_time_days = 0, mira hasta hoy.

create or replace view public.inventory_forecast_v1
with (security_invoker = true)
as
select
  s.inventory_item_id,
  s.code,
  s.name,
  s.kind,
  s.unit_label,

  s.physical_stock,

  coalesce(o.quantity_on_order, 0)::integer as quantity_on_order,
  o.next_expected_at,

  coalesce((
    select sum(dir.required_quantity)::integer
    from public.departure_inventory_requirements_v1 dir
    where dir.inventory_item_id = s.inventory_item_id
      and dir.starts_at >= now()
      and dir.starts_at < now() + make_interval(days => s.lead_time_days + 1)
  ), 0)::integer as required_within_lead_time,

  (
    s.physical_stock
    + coalesce(o.quantity_on_order, 0)
    - coalesce((
        select sum(dir.required_quantity)::integer
        from public.departure_inventory_requirements_v1 dir
        where dir.inventory_item_id = s.inventory_item_id
          and dir.starts_at >= now()
          and dir.starts_at < now() + make_interval(days => s.lead_time_days + 1)
      ), 0)
  )::integer as projected_stock_after_near_departures,

  s.reorder_point,
  s.target_stock,
  s.lead_time_days,
  s.last_unit_cost_cents,
  s.currency,

  case
    when (
      s.physical_stock
      + coalesce(o.quantity_on_order, 0)
      - coalesce((
          select sum(dir.required_quantity)::integer
          from public.departure_inventory_requirements_v1 dir
          where dir.inventory_item_id = s.inventory_item_id
            and dir.starts_at >= now()
            and dir.starts_at < now() + make_interval(days => s.lead_time_days + 1)
        ), 0)
    ) <= s.reorder_point
    then true
    else false
  end as reorder_needed

from public.inventory_stock_v1 s
left join public.inventory_open_orders_v1 o
  on o.inventory_item_id = s.inventory_item_id
where s.status = 'active'::public.inventory_item_status;

grant select on public.inventory_forecast_v1
to authenticated;


-- =========================================================
-- 11. SITUACIONES OPERATIVAS DE INVENTARIO
-- =========================================================
--
-- Se integra con la filosofía de Migración E:
-- la situación aparece/desaparece por el estado actual.
-- No crea automáticamente una tarea persistente.

create or replace view public.inventory_operational_situations_v1
with (security_invoker = true)
as
select
  ('inventory_reorder:' || f.inventory_item_id::text)::text as situation_key,
  'inventory_reorder'::text as situation_type,
  f.inventory_item_id,
  f.code,
  f.name,
  'high'::public.operational_priority as priority,
  'Reponer stock'::text as title,
  (
    'Stock físico: ' || f.physical_stock::text
    || '; pedido: ' || f.quantity_on_order::text
    || '; necesidad próxima: ' || f.required_within_lead_time::text
    || '; proyectado: ' || f.projected_stock_after_near_departures::text
    || '; punto de reposición: ' || f.reorder_point::text
  )::text as detail,
  f.next_expected_at as relevant_at
from public.inventory_forecast_v1 f
where f.reorder_needed = true;

grant select on public.inventory_operational_situations_v1
to authenticated;


-- =========================================================
-- 12. RPC: REGISTRAR MOVIMIENTO MANUAL
-- =========================================================

create or replace function public.register_inventory_movement_v1(
  p_inventory_item_id uuid,
  p_movement_type public.inventory_movement_type,
  p_quantity_delta integer,
  p_unit_cost_cents integer default null,
  p_departure_id uuid default null,
  p_note text default null
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id bigint;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para registrar movimientos de inventario';
  end if;

  if not exists (
    select 1
    from public.inventory_items
    where id = p_inventory_item_id
  ) then
    raise exception 'Artículo de inventario no encontrado';
  end if;

  if p_quantity_delta is null or p_quantity_delta = 0 then
    raise exception 'La cantidad del movimiento no puede ser cero';
  end if;

  if p_movement_type in (
    'departure_consumption'::public.inventory_movement_type,
    'manual_consumption'::public.inventory_movement_type,
    'adjustment_out'::public.inventory_movement_type,
    'supplier_return'::public.inventory_movement_type
  )
  and p_quantity_delta > 0
  then
    raise exception 'Este tipo de movimiento debe tener cantidad negativa';
  end if;

  if p_movement_type in (
    'initial'::public.inventory_movement_type,
    'purchase_receipt'::public.inventory_movement_type,
    'adjustment_in'::public.inventory_movement_type,
    'return_to_stock'::public.inventory_movement_type
  )
  and p_quantity_delta < 0
  then
    raise exception 'Este tipo de movimiento debe tener cantidad positiva';
  end if;

  insert into public.inventory_movements (
    inventory_item_id,
    movement_type,
    quantity_delta,
    unit_cost_cents,
    departure_id,
    note,
    created_by
  )
  values (
    p_inventory_item_id,
    p_movement_type,
    p_quantity_delta,
    p_unit_cost_cents,
    p_departure_id,
    nullif(trim(coalesce(p_note, '')), ''),
    auth.uid()
  )
  returning id into v_id;

  if p_unit_cost_cents is not null
     and p_unit_cost_cents >= 0
  then
    update public.inventory_items
    set
      last_unit_cost_cents = p_unit_cost_cents,
      updated_by = auth.uid()
    where id = p_inventory_item_id;
  end if;

  return v_id;
end;
$$;


-- =========================================================
-- 13. RPC: REGISTRAR RECEPCIÓN DE PEDIDO
-- =========================================================

create or replace function public.receive_purchase_order_line_v1(
  p_purchase_order_line_id uuid,
  p_quantity integer,
  p_received_at timestamptz default now(),
  p_note text default null
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_line public.purchase_order_lines%rowtype;
  v_order public.purchase_orders%rowtype;
  v_movement_id bigint;
  v_new_received integer;
  v_pending_lines integer;
  v_partial_lines integer;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para recibir pedidos';
  end if;

  if p_quantity is null or p_quantity <= 0 then
    raise exception 'La cantidad recibida debe ser positiva';
  end if;

  select *
  into v_line
  from public.purchase_order_lines
  where id = p_purchase_order_line_id
  for update;

  if not found then
    raise exception 'Línea de pedido no encontrada';
  end if;

  select *
  into v_order
  from public.purchase_orders
  where id = v_line.purchase_order_id
  for update;

  if v_order.status = 'cancelled'::public.purchase_order_status then
    raise exception 'No se puede recibir un pedido cancelado';
  end if;

  v_new_received := v_line.received_quantity + p_quantity;

  if v_new_received > v_line.ordered_quantity then
    raise exception
      'La recepción supera la cantidad pedida. Pedido %, recibido hasta ahora %, intento %',
      v_line.ordered_quantity,
      v_line.received_quantity,
      p_quantity;
  end if;

  update public.purchase_order_lines
  set
    received_quantity = v_new_received
  where id = p_purchase_order_line_id;

  insert into public.inventory_movements (
    inventory_item_id,
    movement_type,
    quantity_delta,
    unit_cost_cents,
    currency,
    purchase_order_line_id,
    note,
    occurred_at,
    created_by
  )
  values (
    v_line.inventory_item_id,
    'purchase_receipt'::public.inventory_movement_type,
    p_quantity,
    v_line.unit_cost_cents,
    v_line.currency,
    p_purchase_order_line_id,
    nullif(trim(coalesce(p_note, '')), ''),
    p_received_at,
    auth.uid()
  )
  returning id into v_movement_id;

  if v_line.unit_cost_cents is not null then
    update public.inventory_items
    set
      last_unit_cost_cents = v_line.unit_cost_cents,
      currency = v_line.currency,
      updated_by = auth.uid()
    where id = v_line.inventory_item_id;
  end if;

  select
    count(*) filter (
      where l.received_quantity < l.ordered_quantity
    )::integer,
    count(*) filter (
      where l.received_quantity > 0
        and l.received_quantity < l.ordered_quantity
    )::integer
  into
    v_pending_lines,
    v_partial_lines
  from public.purchase_order_lines l
  where l.purchase_order_id = v_line.purchase_order_id;

  update public.purchase_orders
  set
    status = case
      when v_pending_lines = 0
        then 'received'::public.purchase_order_status
      when v_partial_lines > 0
        or exists (
          select 1
          from public.purchase_order_lines l2
          where l2.purchase_order_id = v_line.purchase_order_id
            and l2.received_quantity > 0
        )
        then 'partially_received'::public.purchase_order_status
      else
        'ordered'::public.purchase_order_status
    end,
    received_at = case
      when v_pending_lines = 0 then p_received_at
      else null
    end,
    updated_by = auth.uid()
  where id = v_line.purchase_order_id;

  return v_movement_id;
end;
$$;


-- =========================================================
-- 14. RPC: REGISTRAR CONSUMO DE UNA SALIDA
-- =========================================================

create or replace function public.register_departure_inventory_consumption_v1(
  p_departure_id uuid,
  p_inventory_item_id uuid,
  p_quantity integer,
  p_note text default null
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_stock integer;
  v_id bigint;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager','guide']::public.app_role[]
  ) then
    raise exception 'No autorizado para registrar consumo de una salida';
  end if;

  if p_quantity is null or p_quantity <= 0 then
    raise exception 'La cantidad consumida debe ser positiva';
  end if;

  if not exists (
    select 1
    from public.departures
    where id = p_departure_id
  ) then
    raise exception 'Salida no encontrada';
  end if;

  select physical_stock
  into v_stock
  from public.inventory_stock_v1
  where inventory_item_id = p_inventory_item_id;

  if v_stock is null then
    raise exception 'Artículo de inventario no encontrado';
  end if;

  if v_stock < p_quantity then
    raise exception
      'Stock insuficiente. Disponible %, consumo solicitado %',
      v_stock,
      p_quantity;
  end if;

  insert into public.inventory_movements (
    inventory_item_id,
    movement_type,
    quantity_delta,
    unit_cost_cents,
    departure_id,
    note,
    created_by
  )
  select
    i.id,
    'departure_consumption'::public.inventory_movement_type,
    -p_quantity,
    i.last_unit_cost_cents,
    p_departure_id,
    nullif(trim(coalesce(p_note, '')), ''),
    auth.uid()
  from public.inventory_items i
  where i.id = p_inventory_item_id
  returning id into v_id;

  return v_id;
end;
$$;


-- =========================================================
-- 15. AUDITORÍA
-- =========================================================

drop trigger if exists trg_audit_inventory_suppliers
  on public.inventory_suppliers;

create trigger trg_audit_inventory_suppliers
after insert or update or delete on public.inventory_suppliers
for each row execute function public.write_audit_log();

drop trigger if exists trg_audit_inventory_items
  on public.inventory_items;

create trigger trg_audit_inventory_items
after insert or update or delete on public.inventory_items
for each row execute function public.write_audit_log();

drop trigger if exists trg_audit_purchase_orders
  on public.purchase_orders;

create trigger trg_audit_purchase_orders
after insert or update or delete on public.purchase_orders
for each row execute function public.write_audit_log();

drop trigger if exists trg_audit_purchase_order_lines
  on public.purchase_order_lines;

create trigger trg_audit_purchase_order_lines
after insert or update or delete on public.purchase_order_lines
for each row execute function public.write_audit_log();

drop trigger if exists trg_audit_inventory_movements
  on public.inventory_movements;

create trigger trg_audit_inventory_movements
after insert or update or delete on public.inventory_movements
for each row execute function public.write_audit_log();

drop trigger if exists trg_audit_experience_inventory_requirements
  on public.experience_inventory_requirements;

create trigger trg_audit_experience_inventory_requirements
after insert or update or delete on public.experience_inventory_requirements
for each row execute function public.write_audit_log();


-- =========================================================
-- 16. RLS
-- =========================================================

alter table public.inventory_suppliers enable row level security;
alter table public.inventory_items enable row level security;
alter table public.purchase_orders enable row level security;
alter table public.purchase_order_lines enable row level security;
alter table public.inventory_movements enable row level security;
alter table public.experience_inventory_requirements enable row level security;

drop policy if exists inventory_suppliers_management_read
  on public.inventory_suppliers;

create policy inventory_suppliers_management_read
on public.inventory_suppliers
for select
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  )
);

drop policy if exists inventory_items_staff_read
  on public.inventory_items;

create policy inventory_items_staff_read
on public.inventory_items
for select
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager','guide']::public.app_role[]
  )
);

drop policy if exists purchase_orders_management_read
  on public.purchase_orders;

create policy purchase_orders_management_read
on public.purchase_orders
for select
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  )
);

drop policy if exists purchase_order_lines_management_read
  on public.purchase_order_lines;

create policy purchase_order_lines_management_read
on public.purchase_order_lines
for select
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  )
);

drop policy if exists inventory_movements_staff_read
  on public.inventory_movements;

create policy inventory_movements_staff_read
on public.inventory_movements
for select
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager','guide']::public.app_role[]
  )
);

drop policy if exists experience_inventory_requirements_staff_read
  on public.experience_inventory_requirements;

create policy experience_inventory_requirements_staff_read
on public.experience_inventory_requirements
for select
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager','guide']::public.app_role[]
  )
);


-- =========================================================
-- 17. PERMISOS RPC
-- =========================================================

revoke all on function public.register_inventory_movement_v1(
  uuid,
  public.inventory_movement_type,
  integer,
  integer,
  uuid,
  text
) from public, anon;

grant execute on function public.register_inventory_movement_v1(
  uuid,
  public.inventory_movement_type,
  integer,
  integer,
  uuid,
  text
) to authenticated;


revoke all on function public.receive_purchase_order_line_v1(
  uuid,
  integer,
  timestamptz,
  text
) from public, anon;

grant execute on function public.receive_purchase_order_line_v1(
  uuid,
  integer,
  timestamptz,
  text
) to authenticated;


revoke all on function public.register_departure_inventory_consumption_v1(
  uuid,
  uuid,
  integer,
  text
) from public, anon;

grant execute on function public.register_departure_inventory_consumption_v1(
  uuid,
  uuid,
  integer,
  text
) to authenticated;


-- =========================================================
-- 18. COMENTARIOS FINALES
-- =========================================================

comment on table public.inventory_items is
  'Artículos consumibles o de stock físico: cuadernillos, pegatinas, merchandising y otros materiales.';

comment on table public.inventory_movements is
  'Libro de movimientos de existencias. El stock físico se calcula sumando quantity_delta.';

comment on table public.purchase_orders is
  'Pedidos de compra a proveedores de materiales. No confundir con colaboradores comerciales.';

comment on view public.inventory_forecast_v1 is
  'Situación consolidada de stock, pedidos y necesidad prevista dentro del plazo de reposición del artículo.';

comment on view public.inventory_operational_situations_v1 is
  'Situaciones calculadas de inventario que requieren reposición según stock proyectado y punto de pedido.';

commit;
