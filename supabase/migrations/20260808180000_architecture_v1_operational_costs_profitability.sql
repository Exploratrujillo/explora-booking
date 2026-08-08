-- Explora Booking
-- Arquitectura funcional v1
-- MigraciÃ³n I: Costes y rentabilidad operativa
-- Fecha: 2026-08-08
--
-- OBJETIVO
-- -------
-- Crear una capa econÃ³mica OPERATIVA capaz de calcular el coste real
-- y el margen de una salida, sin convertir Explora Booking en un sistema
-- de contabilidad general.
--
-- PRINCIPIOS
-- ----------
-- - Los ingresos vienen de reservas/pagos ya existentes.
-- - Los costes operativos se imputan a salidas concretas.
-- - Los consumos de inventario pueden convertirse en coste de salida.
-- - El coste de una guÃ­a externa o recurso puede imputarse a la salida.
-- - COLABORADORES COMERCIALES (hoteles, apartamentos...) siguen siendo
--   un dominio distinto; sus liquidaciones se tratarÃ¡n despuÃ©s.
-- - No se modelan nÃ³minas, impuestos, amortizaciones ni contabilidad completa.
-- - Los informes futuros leerÃ¡n esta capa sin modificar los hechos.

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
    where t.typname = 'operational_cost_type'
      and n.nspname = 'public'
  ) then
    create type public.operational_cost_type as enum (
      'guide',
      'inventory',
      'transport',
      'ticket',
      'service',
      'marketing',
      'other'
    );
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'operational_cost_source'
      and n.nspname = 'public'
  ) then
    create type public.operational_cost_source as enum (
      'manual',
      'inventory_movement',
      'resource_assignment',
      'other'
    );
  end if;
end
$$;


-- =========================================================
-- 2. COSTES IMPUTABLES A SALIDA
-- =========================================================

create table if not exists public.departure_operational_costs (
  id uuid primary key default gen_random_uuid(),

  departure_id uuid not null
    references public.departures(id) on delete cascade,

  cost_type public.operational_cost_type not null,
  source public.operational_cost_source not null default 'manual',

  label text not null,
  amount_cents integer not null,
  currency char(3) not null default 'EUR',

  -- VÃ­nculos opcionales a hechos de origen.
  inventory_movement_id bigint
    references public.inventory_movements(id) on delete set null,

  resource_id uuid
    references public.resources(id) on delete set null,

  notes text,

  occurred_at timestamptz not null default now(),

  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint departure_operational_costs_label_not_blank
    check (length(trim(label)) > 0),

  constraint departure_operational_costs_amount_non_negative
    check (amount_cents >= 0),

  constraint departure_operational_costs_currency_format
    check (currency ~ '^[A-Z]{3}$')
);

create index if not exists idx_departure_operational_costs_departure
  on public.departure_operational_costs(departure_id, occurred_at);

create index if not exists idx_departure_operational_costs_type
  on public.departure_operational_costs(cost_type, departure_id);

create unique index if not exists uq_departure_operational_cost_inventory_movement
  on public.departure_operational_costs(inventory_movement_id)
  where inventory_movement_id is not null;

drop trigger if exists trg_departure_operational_costs_set_updated_at
  on public.departure_operational_costs;

create trigger trg_departure_operational_costs_set_updated_at
before update on public.departure_operational_costs
for each row execute function public.set_updated_at();

comment on table public.departure_operational_costs is
  'Costes operativos imputados a una salida concreta. No es contabilidad general.';


-- =========================================================
-- 3. FUNCIÃ“N: COSTE DESDE CONSUMO DE INVENTARIO
-- =========================================================
--
-- Convierte un movimiento departure_consumption en coste de salida.
-- Usa el unit_cost_cents fotografiado en el movimiento.
-- Si el coste ya existe para ese movimiento, no duplica.

create or replace function public.sync_inventory_consumption_cost_v1(
  p_inventory_movement_id bigint
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_movement public.inventory_movements%rowtype;
  v_item public.inventory_items%rowtype;
  v_cost_id uuid;
  v_amount integer;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para sincronizar costes de inventario';
  end if;

  select *
  into v_movement
  from public.inventory_movements
  where id = p_inventory_movement_id;

  if not found then
    raise exception 'Movimiento de inventario no encontrado';
  end if;

  if v_movement.movement_type <> 'departure_consumption'::public.inventory_movement_type then
    raise exception 'El movimiento no es un consumo de salida';
  end if;

  if v_movement.departure_id is null then
    raise exception 'El movimiento no estÃ¡ vinculado a una salida';
  end if;

  if v_movement.unit_cost_cents is null then
    raise exception 'El movimiento no tiene coste unitario fotografiado';
  end if;

  select *
  into v_item
  from public.inventory_items
  where id = v_movement.inventory_item_id;

  v_amount := abs(v_movement.quantity_delta) * v_movement.unit_cost_cents;

  insert into public.departure_operational_costs (
    departure_id,
    cost_type,
    source,
    label,
    amount_cents,
    currency,
    inventory_movement_id,
    notes,
    occurred_at,
    created_by,
    updated_by
  )
  values (
    v_movement.departure_id,
    'inventory'::public.operational_cost_type,
    'inventory_movement'::public.operational_cost_source,
    coalesce(v_item.name, 'Consumo de inventario'),
    v_amount,
    v_movement.currency,
    v_movement.id,
    'Generado desde consumo real de inventario',
    v_movement.occurred_at,
    auth.uid(),
    auth.uid()
  )
  on conflict (inventory_movement_id)
  do update set
    amount_cents = excluded.amount_cents,
    currency = excluded.currency,
    label = excluded.label,
    occurred_at = excluded.occurred_at,
    updated_by = auth.uid()
  returning id into v_cost_id;

  return v_cost_id;
end;
$$;


-- =========================================================
-- 4. RPC: REGISTRAR COSTE MANUAL
-- =========================================================

create or replace function public.register_departure_operational_cost_v1(
  p_departure_id uuid,
  p_cost_type public.operational_cost_type,
  p_label text,
  p_amount_cents integer,
  p_currency char(3) default 'EUR',
  p_resource_id uuid default null,
  p_notes text default null,
  p_occurred_at timestamptz default now()
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
    raise exception 'No autorizado para registrar costes operativos';
  end if;

  if not exists (
    select 1 from public.departures where id = p_departure_id
  ) then
    raise exception 'Salida no encontrada';
  end if;

  if p_label is null or length(trim(p_label)) = 0 then
    raise exception 'La descripciÃ³n del coste es obligatoria';
  end if;

  if p_amount_cents is null or p_amount_cents < 0 then
    raise exception 'El importe del coste no puede ser negativo';
  end if;

  if p_resource_id is not null
     and not exists (
       select 1 from public.resources where id = p_resource_id
     )
  then
    raise exception 'Recurso no encontrado';
  end if;

  insert into public.departure_operational_costs (
    departure_id,
    cost_type,
    source,
    label,
    amount_cents,
    currency,
    resource_id,
    notes,
    occurred_at,
    created_by,
    updated_by
  )
  values (
    p_departure_id,
    p_cost_type,
    'manual'::public.operational_cost_source,
    trim(p_label),
    p_amount_cents,
    upper(p_currency),
    p_resource_id,
    nullif(trim(coalesce(p_notes, '')), ''),
    p_occurred_at,
    auth.uid(),
    auth.uid()
  )
  returning id into v_id;

  return v_id;
end;
$$;


-- =========================================================
-- 5. VISTA: INGRESO CONTRATADO POR SALIDA
-- =========================================================

create or replace view public.departure_contracted_revenue_v1
with (security_invoker = true)
as
select
  d.id as departure_id,

  coalesce(sum(
    case
      when b.status = 'confirmed'::public.booking_status
      then b.contracted_total_cents
      else 0
    end
  ), 0)::bigint as contracted_revenue_cents,

  count(b.id) filter (
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
  ), 0)::integer as booked_participants

from public.departures d
left join public.bookings b
  on b.departure_id = d.id
group by d.id;

grant select on public.departure_contracted_revenue_v1
to authenticated;


-- =========================================================
-- 6. VISTA: COBRADO NETO POR SALIDA
-- =========================================================

create or replace view public.departure_collected_revenue_v1
with (security_invoker = true)
as
select
  d.id as departure_id,

  coalesce(sum(
    case
      when b.status = 'confirmed'::public.booking_status
      then ps.customer_paid_net_cents
      else 0
    end
  ), 0)::bigint as customer_collected_net_cents,

  coalesce(sum(
    case
      when b.status = 'confirmed'::public.booking_status
      then ps.direct_explora_net_cents
      else 0
    end
  ), 0)::bigint as explora_collected_net_cents,

  coalesce(sum(
    case
      when b.status = 'confirmed'::public.booking_status
      then ps.third_party_customer_net_cents
      else 0
    end
  ), 0)::bigint as third_party_collected_net_cents

from public.departures d
left join public.bookings b
  on b.departure_id = d.id
left join public.booking_payment_summary_v1 ps
  on ps.booking_id = b.id
group by d.id;

grant select on public.departure_collected_revenue_v1
to authenticated;


-- =========================================================
-- 7. VISTA: COSTES POR SALIDA
-- =========================================================

create or replace view public.departure_operational_cost_summary_v1
with (security_invoker = true)
as
select
  d.id as departure_id,

  coalesce(sum(c.amount_cents), 0)::bigint as total_operational_cost_cents,

  coalesce(sum(c.amount_cents) filter (
    where c.cost_type = 'guide'::public.operational_cost_type
  ), 0)::bigint as guide_cost_cents,

  coalesce(sum(c.amount_cents) filter (
    where c.cost_type = 'inventory'::public.operational_cost_type
  ), 0)::bigint as inventory_cost_cents,

  coalesce(sum(c.amount_cents) filter (
    where c.cost_type = 'transport'::public.operational_cost_type
  ), 0)::bigint as transport_cost_cents,

  coalesce(sum(c.amount_cents) filter (
    where c.cost_type = 'ticket'::public.operational_cost_type
  ), 0)::bigint as ticket_cost_cents,

  coalesce(sum(c.amount_cents) filter (
    where c.cost_type = 'service'::public.operational_cost_type
  ), 0)::bigint as service_cost_cents,

  coalesce(sum(c.amount_cents) filter (
    where c.cost_type = 'marketing'::public.operational_cost_type
  ), 0)::bigint as marketing_cost_cents,

  coalesce(sum(c.amount_cents) filter (
    where c.cost_type = 'other'::public.operational_cost_type
  ), 0)::bigint as other_cost_cents

from public.departures d
left join public.departure_operational_costs c
  on c.departure_id = d.id
group by d.id;

grant select on public.departure_operational_cost_summary_v1
to authenticated;


-- =========================================================
-- 8. VISTA: RENTABILIDAD POR SALIDA
-- =========================================================
--
-- contracted_margin:
--   ingreso contratado - costes operativos
--
-- collected_margin:
--   cobrado neto total cliente - costes operativos
--
-- explora_cash_margin:
--   efectivo neto que ha entrado en Explora - costes operativos
--
-- third_party todavÃ­a no implica liquidaciÃ³n OTA;
-- solo representa dinero cobrado por terceros.

create or replace view public.departure_profitability_v1
with (security_invoker = true)
as
select
  d.id as departure_id,
  d.experience_id,
  d.starts_at,
  d.ends_at,
  d.operational_state,

  cr.confirmed_bookings,
  cr.booked_participants,

  cr.contracted_revenue_cents,
  col.customer_collected_net_cents,
  col.explora_collected_net_cents,
  col.third_party_collected_net_cents,

  cs.total_operational_cost_cents,
  cs.guide_cost_cents,
  cs.inventory_cost_cents,
  cs.transport_cost_cents,
  cs.ticket_cost_cents,
  cs.service_cost_cents,
  cs.marketing_cost_cents,
  cs.other_cost_cents,

  (
    cr.contracted_revenue_cents
    - cs.total_operational_cost_cents
  )::bigint as contracted_margin_cents,

  (
    col.customer_collected_net_cents
    - cs.total_operational_cost_cents
  )::bigint as collected_margin_cents,

  (
    col.explora_collected_net_cents
    - cs.total_operational_cost_cents
  )::bigint as explora_cash_margin_cents,

  case
    when cr.booked_participants > 0
    then round(
      cs.total_operational_cost_cents::numeric
      / cr.booked_participants::numeric,
      2
    )
    else null
  end as operational_cost_per_participant_cents,

  case
    when cr.contracted_revenue_cents > 0
    then round(
      (
        (
          cr.contracted_revenue_cents
          - cs.total_operational_cost_cents
        )::numeric
        / cr.contracted_revenue_cents::numeric
      ) * 100,
      2
    )
    else null
  end as contracted_margin_percentage

from public.departure_operational_v1 d
join public.departure_contracted_revenue_v1 cr
  on cr.departure_id = d.id
join public.departure_collected_revenue_v1 col
  on col.departure_id = d.id
join public.departure_operational_cost_summary_v1 cs
  on cs.departure_id = d.id;

grant select on public.departure_profitability_v1
to authenticated;


-- =========================================================
-- 9. VISTA: RENTABILIDAD POR EXPERIENCIA
-- =========================================================

create or replace view public.experience_profitability_v1
with (security_invoker = true)
as
select
  e.id as experience_id,
  e.code as experience_code,
  e.name as experience_name,

  count(p.departure_id)::integer as departure_count,

  coalesce(sum(p.confirmed_bookings), 0)::integer as confirmed_bookings,
  coalesce(sum(p.booked_participants), 0)::integer as booked_participants,

  coalesce(sum(p.contracted_revenue_cents), 0)::bigint as contracted_revenue_cents,
  coalesce(sum(p.customer_collected_net_cents), 0)::bigint as customer_collected_net_cents,
  coalesce(sum(p.total_operational_cost_cents), 0)::bigint as total_operational_cost_cents,

  coalesce(sum(p.contracted_margin_cents), 0)::bigint as contracted_margin_cents,
  coalesce(sum(p.collected_margin_cents), 0)::bigint as collected_margin_cents,

  case
    when coalesce(sum(p.booked_participants), 0) > 0
    then round(
      coalesce(sum(p.total_operational_cost_cents), 0)::numeric
      / sum(p.booked_participants)::numeric,
      2
    )
    else null
  end as operational_cost_per_participant_cents,

  case
    when coalesce(sum(p.contracted_revenue_cents), 0) > 0
    then round(
      (
        coalesce(sum(p.contracted_margin_cents), 0)::numeric
        / sum(p.contracted_revenue_cents)::numeric
      ) * 100,
      2
    )
    else null
  end as contracted_margin_percentage

from public.experiences e
left join public.departure_profitability_v1 p
  on p.experience_id = e.id
group by
  e.id,
  e.code,
  e.name;

grant select on public.experience_profitability_v1
to authenticated;


-- =========================================================
-- 10. SITUACIÃ“N OPERATIVA: SALIDA CON COSTES > INGRESO
-- =========================================================
--
-- Solo para salidas con ingreso contratado positivo.
-- No crea una tarea automÃ¡ticamente.

create or replace view public.profitability_operational_situations_v1
with (security_invoker = true)
as
select
  ('departure_negative_margin:' || p.departure_id::text)::text as situation_key,
  'departure_negative_margin'::text as situation_type,
  p.departure_id,
  'high'::public.operational_priority as priority,
  'Salida con margen negativo'::text as title,
  (
    'Ingreso contratado: '
    || to_char(p.contracted_revenue_cents / 100.0, 'FM999999990D00')
    || ' EUR; costes: '
    || to_char(p.total_operational_cost_cents / 100.0, 'FM999999990D00')
    || ' EUR; margen: '
    || to_char(p.contracted_margin_cents / 100.0, 'FM999999990D00')
    || ' EUR'
  )::text as detail,
  p.starts_at as relevant_at
from public.departure_profitability_v1 p
where p.contracted_revenue_cents > 0
  and p.contracted_margin_cents < 0;

grant select on public.profitability_operational_situations_v1
to authenticated;


-- =========================================================
-- 11. AUDITORÃA
-- =========================================================

drop trigger if exists trg_audit_departure_operational_costs
  on public.departure_operational_costs;

create trigger trg_audit_departure_operational_costs
after insert or update or delete on public.departure_operational_costs
for each row execute function public.write_audit_log();


-- =========================================================
-- 12. RLS
-- =========================================================

alter table public.departure_operational_costs enable row level security;

drop policy if exists departure_operational_costs_management_read
  on public.departure_operational_costs;

create policy departure_operational_costs_management_read
on public.departure_operational_costs
for select
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  )
);


-- =========================================================
-- 13. PERMISOS RPC
-- =========================================================

revoke all on function public.sync_inventory_consumption_cost_v1(bigint)
from public, anon;

grant execute on function public.sync_inventory_consumption_cost_v1(bigint)
to authenticated;


revoke all on function public.register_departure_operational_cost_v1(
  uuid,
  public.operational_cost_type,
  text,
  integer,
  char,
  uuid,
  text,
  timestamptz
) from public, anon;

grant execute on function public.register_departure_operational_cost_v1(
  uuid,
  public.operational_cost_type,
  text,
  integer,
  char,
  uuid,
  text,
  timestamptz
) to authenticated;


-- =========================================================
-- 14. COMENTARIOS FINALES
-- =========================================================

comment on view public.departure_profitability_v1 is
  'Rentabilidad operativa por salida: ingresos contratados/cobrados, costes y mÃ¡rgenes.';

comment on view public.experience_profitability_v1 is
  'Rentabilidad agregada por experiencia. No es contabilidad general ni fiscal.';

commit;

