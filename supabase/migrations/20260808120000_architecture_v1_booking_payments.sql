-- Explora Booking
-- Arquitectura funcional v1
-- Migración C: Pagos y estado económico de la Reserva
-- Fecha: 2026-08-08
--
-- OBJETIVO
-- -------
-- Crear la capa económica de la Reserva separando claramente:
--
--   1) lo contratado por el cliente        -> bookings.contracted_total_cents
--   2) los movimientos de pago/devolución  -> booking_payment_movements
--   3) el estado económico calculado        -> booking_payment_summary_v1
--
-- PRINCIPIOS
-- ----------
-- - El estado de pago del CLIENTE es independiente de la liquidación con una OTA.
-- - Una Reserva pagada a Civitatis puede figurar como PAGADA para el guía
--   aunque Explora todavía no haya recibido la liquidación de Civitatis.
-- - Los cobros pueden registrarse desde Oficina o Modo Guía.
-- - Se admiten pagos parciales, devoluciones y ajustes justificados.
-- - Nunca se borra un cobro para "corregirlo": se registra un movimiento compensatorio.
-- - No-Show y asistencia NO forman parte de esta migración.
-- - Liquidaciones OTA NO forman parte de esta migración.
--
-- La liquidación OTA se construirá después como una capa de Oficina distinta.

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
    where t.typname = 'payment_movement_type'
      and n.nspname = 'public'
  ) then
    create type public.payment_movement_type as enum (
      'payment',
      'refund',
      'adjustment_credit',
      'adjustment_debit'
    );
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'payment_method'
      and n.nspname = 'public'
  ) then
    create type public.payment_method as enum (
      'cash',
      'card_pos',
      'payment_link',
      'paypal',
      'bizum',
      'bank_transfer',
      'ota',
      'other'
    );
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'payment_funds_destination'
      and n.nspname = 'public'
  ) then
    create type public.payment_funds_destination as enum (
      'explora',
      'third_party'
    );
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'payment_entry_context'
      and n.nspname = 'public'
  ) then
    create type public.payment_entry_context as enum (
      'office',
      'guide',
      'system',
      'import'
    );
  end if;
end
$$;


-- =========================================================
-- 2. MOVIMIENTOS ECONÓMICOS DE LA RESERVA
-- =========================================================
--
-- amount_cents SIEMPRE es positivo.
-- El signo económico lo determina movement_type:
--
-- payment / adjustment_credit  -> suman al saldo pagado por el cliente
-- refund / adjustment_debit    -> restan
--
-- funds_destination:
--   explora      -> el dinero entra/sale directamente de Explora
--   third_party  -> el cliente ha pagado/devolución gestionada por OTA
--
-- Esta distinción permite:
--   cliente = PAGADO
--   liquidación OTA = todavía PENDIENTE
--
-- sin mezclar ambas realidades.

create table if not exists public.booking_payment_movements (
  id uuid primary key default gen_random_uuid(),

  booking_id uuid not null
    references public.bookings(id) on delete restrict,

  movement_type public.payment_movement_type not null,
  payment_method public.payment_method not null,

  amount_cents integer not null,
  currency char(3) not null default 'EUR',

  funds_destination public.payment_funds_destination
    not null default 'explora',

  entry_context public.payment_entry_context
    not null default 'office',

  -- Referencias externas: SumUp, PayPal, OTA, transferencia, TPV, etc.
  external_reference text,

  -- Motivo/explicación. Es especialmente importante en ajustes.
  reason text,
  internal_notes text,

  occurred_at timestamptz not null default now(),

  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),

  constraint booking_payment_movements_amount_positive
    check (amount_cents > 0),

  constraint booking_payment_movements_currency_format
    check (currency ~ '^[A-Z]{3}$'),

  constraint booking_payment_movements_adjustment_reason_required
    check (
      movement_type not in (
        'adjustment_credit'::public.payment_movement_type,
        'adjustment_debit'::public.payment_movement_type
      )
      or length(trim(coalesce(reason, ''))) >= 3
    )
);

create index if not exists idx_booking_payment_movements_booking
  on public.booking_payment_movements(booking_id, occurred_at, created_at);

create index if not exists idx_booking_payment_movements_method
  on public.booking_payment_movements(payment_method, occurred_at);

create index if not exists idx_booking_payment_movements_destination
  on public.booking_payment_movements(funds_destination, occurred_at);

comment on table public.booking_payment_movements is
  'Movimientos de pago, devolución y ajuste ligados a una Reserva. Nunca se corrige el histórico borrando un cobro.';

comment on column public.booking_payment_movements.funds_destination is
  'explora = fondos cobrados/devueltos directamente por Explora; third_party = cliente pagado a través de OTA u otro tercero.';


-- =========================================================
-- 3. VISTA: ESTADO ECONÓMICO DEL CLIENTE
-- =========================================================
--
-- Esta vista responde a lo que necesita Oficina/Modo Guía:
--   - cuánto debía pagar;
--   - cuánto tiene pagado;
--   - cuánto queda por cobrar;
--   - si está sin pagar / parcial / pagado / sobrepagado.
--
-- La liquidación real con OTA NO se calcula aquí.

create or replace view public.booking_payment_summary_v1
with (security_invoker = true)
as
select
  b.id as booking_id,
  b.departure_id,
  b.experience_id,
  b.channel_id,
  b.status as booking_status,

  b.currency as booking_currency,
  b.contracted_total_cents,

  coalesce(
    sum(
      case
        when pm.movement_type in (
          'payment'::public.payment_movement_type,
          'adjustment_credit'::public.payment_movement_type
        )
        then pm.amount_cents
        else 0
      end
    ),
    0
  )::integer as total_credited_cents,

  coalesce(
    sum(
      case
        when pm.movement_type in (
          'refund'::public.payment_movement_type,
          'adjustment_debit'::public.payment_movement_type
        )
        then pm.amount_cents
        else 0
      end
    ),
    0
  )::integer as total_debited_cents,

  coalesce(
    sum(
      case
        when pm.movement_type in (
          'payment'::public.payment_movement_type,
          'adjustment_credit'::public.payment_movement_type
        )
        then pm.amount_cents
        when pm.movement_type in (
          'refund'::public.payment_movement_type,
          'adjustment_debit'::public.payment_movement_type
        )
        then -pm.amount_cents
        else 0
      end
    ),
    0
  )::integer as customer_paid_net_cents,

  greatest(
    b.contracted_total_cents
    -
    coalesce(
      sum(
        case
          when pm.movement_type in (
            'payment'::public.payment_movement_type,
            'adjustment_credit'::public.payment_movement_type
          )
          then pm.amount_cents
          when pm.movement_type in (
            'refund'::public.payment_movement_type,
            'adjustment_debit'::public.payment_movement_type
          )
          then -pm.amount_cents
          else 0
        end
      ),
      0
    ),
    0
  )::integer as outstanding_cents,

  greatest(
    coalesce(
      sum(
        case
          when pm.movement_type in (
            'payment'::public.payment_movement_type,
            'adjustment_credit'::public.payment_movement_type
          )
          then pm.amount_cents
          when pm.movement_type in (
            'refund'::public.payment_movement_type,
            'adjustment_debit'::public.payment_movement_type
          )
          then -pm.amount_cents
          else 0
        end
      ),
      0
    )
    - b.contracted_total_cents,
    0
  )::integer as overpaid_cents,

  coalesce(
    sum(
      case
        when pm.funds_destination = 'explora'::public.payment_funds_destination
         and pm.movement_type in (
           'payment'::public.payment_movement_type,
           'adjustment_credit'::public.payment_movement_type
         )
        then pm.amount_cents
        when pm.funds_destination = 'explora'::public.payment_funds_destination
         and pm.movement_type in (
           'refund'::public.payment_movement_type,
           'adjustment_debit'::public.payment_movement_type
         )
        then -pm.amount_cents
        else 0
      end
    ),
    0
  )::integer as direct_explora_net_cents,

  coalesce(
    sum(
      case
        when pm.funds_destination = 'third_party'::public.payment_funds_destination
         and pm.movement_type in (
           'payment'::public.payment_movement_type,
           'adjustment_credit'::public.payment_movement_type
         )
        then pm.amount_cents
        when pm.funds_destination = 'third_party'::public.payment_funds_destination
         and pm.movement_type in (
           'refund'::public.payment_movement_type,
           'adjustment_debit'::public.payment_movement_type
         )
        then -pm.amount_cents
        else 0
      end
    ),
    0
  )::integer as third_party_customer_net_cents,

  case
    when b.contracted_total_cents = 0 then 'paid'
    when coalesce(
      sum(
        case
          when pm.movement_type in (
            'payment'::public.payment_movement_type,
            'adjustment_credit'::public.payment_movement_type
          )
          then pm.amount_cents
          when pm.movement_type in (
            'refund'::public.payment_movement_type,
            'adjustment_debit'::public.payment_movement_type
          )
          then -pm.amount_cents
          else 0
        end
      ),
      0
    ) <= 0
    then 'unpaid'

    when coalesce(
      sum(
        case
          when pm.movement_type in (
            'payment'::public.payment_movement_type,
            'adjustment_credit'::public.payment_movement_type
          )
          then pm.amount_cents
          when pm.movement_type in (
            'refund'::public.payment_movement_type,
            'adjustment_debit'::public.payment_movement_type
          )
          then -pm.amount_cents
          else 0
        end
      ),
      0
    ) < b.contracted_total_cents
    then 'partial'

    when coalesce(
      sum(
        case
          when pm.movement_type in (
            'payment'::public.payment_movement_type,
            'adjustment_credit'::public.payment_movement_type
          )
          then pm.amount_cents
          when pm.movement_type in (
            'refund'::public.payment_movement_type,
            'adjustment_debit'::public.payment_movement_type
          )
          then -pm.amount_cents
          else 0
        end
      ),
      0
    ) = b.contracted_total_cents
    then 'paid'

    else 'overpaid'
  end as customer_payment_state,

  count(pm.id)::integer as movement_count,
  max(pm.occurred_at) as last_payment_movement_at

from public.bookings b
left join public.booking_payment_movements pm
  on pm.booking_id = b.id
group by
  b.id,
  b.departure_id,
  b.experience_id,
  b.channel_id,
  b.status,
  b.currency,
  b.contracted_total_cents;

grant select on public.booking_payment_summary_v1
to authenticated;


-- =========================================================
-- 4. VISTA: DETALLE OPERATIVO PARA MODO GUÍA / OFICINA
-- =========================================================
--
-- No incluye datos de liquidación OTA ni comisiones.

create or replace view public.booking_operational_payment_v1
with (security_invoker = true)
as
select
  b.id as booking_id,
  b.departure_id,
  b.contact_name,
  b.contact_phone,
  b.booking_reference,
  b.external_reference,

  sc.code as channel_code,
  sc.name as channel_name,

  ps.contracted_total_cents,
  ps.customer_paid_net_cents,
  ps.outstanding_cents,
  ps.overpaid_cents,
  ps.customer_payment_state,
  ps.last_payment_movement_at

from public.bookings b
left join public.sales_channels sc
  on sc.id = b.channel_id
join public.booking_payment_summary_v1 ps
  on ps.booking_id = b.id
where b.status = 'confirmed'::public.booking_status;

grant select on public.booking_operational_payment_v1
to authenticated;


-- =========================================================
-- 5. API SEGURA: REGISTRAR PAGO
-- =========================================================

create or replace function public.register_booking_payment_v1(
  p_booking_id uuid,
  p_amount_cents integer,
  p_payment_method public.payment_method,
  p_funds_destination public.payment_funds_destination default 'explora',
  p_entry_context public.payment_entry_context default 'office',
  p_external_reference text default null,
  p_occurred_at timestamptz default now(),
  p_internal_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings%rowtype;
  v_movement_id uuid;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager','guide']::public.app_role[]
  ) then
    raise exception 'No autorizado para registrar pagos';
  end if;

  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'El importe del pago debe ser mayor que cero';
  end if;

  select *
  into v_booking
  from public.bookings
  where id = p_booking_id;

  if not found then
    raise exception 'Reserva no encontrada';
  end if;

  if v_booking.status = 'cancelled'::public.booking_status then
    raise exception
      'La Reserva está cancelada. Use una operación administrativa específica si necesita registrar un ajuste histórico';
  end if;

  insert into public.booking_payment_movements (
    booking_id,
    movement_type,
    payment_method,
    amount_cents,
    currency,
    funds_destination,
    entry_context,
    external_reference,
    internal_notes,
    occurred_at,
    created_by
  )
  values (
    p_booking_id,
    'payment'::public.payment_movement_type,
    p_payment_method,
    p_amount_cents,
    v_booking.currency,
    p_funds_destination,
    p_entry_context,
    nullif(trim(coalesce(p_external_reference, '')), ''),
    p_internal_notes,
    coalesce(p_occurred_at, now()),
    auth.uid()
  )
  returning id into v_movement_id;

  return v_movement_id;
end;
$$;

revoke all on function public.register_booking_payment_v1(
  uuid,
  integer,
  public.payment_method,
  public.payment_funds_destination,
  public.payment_entry_context,
  text,
  timestamptz,
  text
) from public, anon;

grant execute on function public.register_booking_payment_v1(
  uuid,
  integer,
  public.payment_method,
  public.payment_funds_destination,
  public.payment_entry_context,
  text,
  timestamptz,
  text
) to authenticated;


-- =========================================================
-- 6. API SEGURA: REGISTRAR DEVOLUCIÓN
-- =========================================================
--
-- La devolución se registra como movimiento.
-- No se elimina el cobro original.

create or replace function public.register_booking_refund_v1(
  p_booking_id uuid,
  p_amount_cents integer,
  p_payment_method public.payment_method,
  p_funds_destination public.payment_funds_destination default 'explora',
  p_entry_context public.payment_entry_context default 'office',
  p_reason text default null,
  p_external_reference text default null,
  p_occurred_at timestamptz default now(),
  p_internal_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings%rowtype;
  v_summary public.booking_payment_summary_v1%rowtype;
  v_movement_id uuid;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para registrar devoluciones';
  end if;

  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'El importe de devolución debe ser mayor que cero';
  end if;

  select *
  into v_booking
  from public.bookings
  where id = p_booking_id;

  if not found then
    raise exception 'Reserva no encontrada';
  end if;

  select *
  into v_summary
  from public.booking_payment_summary_v1
  where booking_id = p_booking_id;

  if p_amount_cents > coalesce(v_summary.customer_paid_net_cents, 0) then
    raise exception
      'La devolución (%) supera el saldo neto pagado por el cliente (%)',
      p_amount_cents,
      coalesce(v_summary.customer_paid_net_cents, 0);
  end if;

  insert into public.booking_payment_movements (
    booking_id,
    movement_type,
    payment_method,
    amount_cents,
    currency,
    funds_destination,
    entry_context,
    external_reference,
    reason,
    internal_notes,
    occurred_at,
    created_by
  )
  values (
    p_booking_id,
    'refund'::public.payment_movement_type,
    p_payment_method,
    p_amount_cents,
    v_booking.currency,
    p_funds_destination,
    p_entry_context,
    nullif(trim(coalesce(p_external_reference, '')), ''),
    nullif(trim(coalesce(p_reason, '')), ''),
    p_internal_notes,
    coalesce(p_occurred_at, now()),
    auth.uid()
  )
  returning id into v_movement_id;

  return v_movement_id;
end;
$$;

revoke all on function public.register_booking_refund_v1(
  uuid,
  integer,
  public.payment_method,
  public.payment_funds_destination,
  public.payment_entry_context,
  text,
  text,
  timestamptz,
  text
) from public, anon;

grant execute on function public.register_booking_refund_v1(
  uuid,
  integer,
  public.payment_method,
  public.payment_funds_destination,
  public.payment_entry_context,
  text,
  text,
  timestamptz,
  text
) to authenticated;


-- =========================================================
-- 7. API SEGURA: AJUSTE ECONÓMICO JUSTIFICADO
-- =========================================================
--
-- adjustment_credit:
--   aumenta el saldo reconocido como pagado.
--
-- adjustment_debit:
--   reduce el saldo reconocido como pagado.
--
-- Útil para corregir diferencias sin borrar movimientos.
-- Requiere motivo.

create or replace function public.register_booking_payment_adjustment_v1(
  p_booking_id uuid,
  p_amount_cents integer,
  p_adjustment_type public.payment_movement_type,
  p_reason text,
  p_payment_method public.payment_method default 'other',
  p_funds_destination public.payment_funds_destination default 'explora',
  p_entry_context public.payment_entry_context default 'office',
  p_external_reference text default null,
  p_occurred_at timestamptz default now(),
  p_internal_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings%rowtype;
  v_movement_id uuid;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para registrar ajustes económicos';
  end if;

  if p_adjustment_type not in (
    'adjustment_credit'::public.payment_movement_type,
    'adjustment_debit'::public.payment_movement_type
  ) then
    raise exception
      'El tipo debe ser adjustment_credit o adjustment_debit';
  end if;

  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'El importe del ajuste debe ser mayor que cero';
  end if;

  if length(trim(coalesce(p_reason, ''))) < 3 then
    raise exception 'Debe indicar un motivo para el ajuste';
  end if;

  select *
  into v_booking
  from public.bookings
  where id = p_booking_id;

  if not found then
    raise exception 'Reserva no encontrada';
  end if;

  insert into public.booking_payment_movements (
    booking_id,
    movement_type,
    payment_method,
    amount_cents,
    currency,
    funds_destination,
    entry_context,
    external_reference,
    reason,
    internal_notes,
    occurred_at,
    created_by
  )
  values (
    p_booking_id,
    p_adjustment_type,
    p_payment_method,
    p_amount_cents,
    v_booking.currency,
    p_funds_destination,
    p_entry_context,
    nullif(trim(coalesce(p_external_reference, '')), ''),
    trim(p_reason),
    p_internal_notes,
    coalesce(p_occurred_at, now()),
    auth.uid()
  )
  returning id into v_movement_id;

  return v_movement_id;
end;
$$;

revoke all on function public.register_booking_payment_adjustment_v1(
  uuid,
  integer,
  public.payment_movement_type,
  text,
  public.payment_method,
  public.payment_funds_destination,
  public.payment_entry_context,
  text,
  timestamptz,
  text
) from public, anon;

grant execute on function public.register_booking_payment_adjustment_v1(
  uuid,
  integer,
  public.payment_movement_type,
  text,
  public.payment_method,
  public.payment_funds_destination,
  public.payment_entry_context,
  text,
  timestamptz,
  text
) to authenticated;


-- =========================================================
-- 8. API SEGURA: RESUMEN ECONÓMICO DE UNA RESERVA
-- =========================================================

create or replace function public.get_booking_payment_summary_v1(
  p_booking_id uuid
)
returns public.booking_payment_summary_v1
language sql
stable
security definer
set search_path = public
as $$
  select s.*
  from public.booking_payment_summary_v1 s
  where s.booking_id = p_booking_id
    and public.current_user_has_role(
      array['owner','admin','manager','guide']::public.app_role[]
    );
$$;

revoke all on function public.get_booking_payment_summary_v1(uuid)
from public, anon;

grant execute on function public.get_booking_payment_summary_v1(uuid)
to authenticated;


-- =========================================================
-- 9. AUDITORÍA
-- =========================================================

drop trigger if exists trg_audit_booking_payment_movements
  on public.booking_payment_movements;

create trigger trg_audit_booking_payment_movements
after insert or update or delete on public.booking_payment_movements
for each row execute function public.write_audit_log();


-- =========================================================
-- 10. ROW LEVEL SECURITY
-- =========================================================

alter table public.booking_payment_movements enable row level security;

-- Oficina puede consultar movimientos completos.
drop policy if exists booking_payment_movements_office_read
  on public.booking_payment_movements;

create policy booking_payment_movements_office_read
on public.booking_payment_movements
for select
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  )
);

-- Guías NO reciben por ahora lectura directa de la tabla.
-- Modo Guía consumirá las RPC/vistas operativas específicas,
-- sin exponer información administrativa de liquidaciones.


-- =========================================================
-- 11. COMENTARIOS DE ARQUITECTURA
-- =========================================================

comment on view public.booking_payment_summary_v1 is
  'Estado económico del cliente respecto a su Reserva. No representa la liquidación con una OTA.';

comment on view public.booking_operational_payment_v1 is
  'Resumen operativo de pago para Oficina/Modo Guía: pagado, pendiente e importe a cobrar, sin información de liquidaciones OTA.';


commit;
