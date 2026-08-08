-- Explora Booking
-- Arquitectura funcional v1
-- Migración A: normalización de Operativa
-- Fecha: 2026-08-08
--
-- OBJETIVO
-- -------
-- Separar progresivamente conceptos que hasta ahora estaban mezclados
-- en departure_status:
--
--   - ABIERTA / CERRADA A VENTAS     -> sales_open
--   - CANCELADA COMO SERVICIO        -> cancelled_at
--   - FINALIZADA                     -> finalized_at
--
-- Durante esta fase NO se elimina el campo legacy `status`.
-- Las funciones existentes y Sprint 1.3 todavía dependen de él.
--
-- También se flexibilizan las restricciones de capacidad para permitir:
--   - reservas por encima de capacidad;
--   - reducción de capacidad por debajo de ocupación;
--   - capacidad inferior al mínimo configurado, mostrando advertencia
--     en lugar de bloquear la decisión operativa.
--
-- Esta migración es deliberadamente ADITIVA y de transición.

begin;

-- =========================================================
-- 1. NUEVOS CAMPOS DE ESTADO OPERATIVO
-- =========================================================

alter table public.departures
  add column if not exists sales_open boolean
  not null default true;

comment on column public.departures.sales_open is
  'Indica si la Operativa admite nuevas ventas. ABIERTA=true, CERRADA=false. Es independiente de cancelación y finalización.';


alter table public.departures
  add column if not exists sales_state_changed_at timestamptz;

alter table public.departures
  add column if not exists sales_state_changed_by uuid
  references public.profiles(id) on delete set null;

alter table public.departures
  add column if not exists sales_state_reason text;

comment on column public.departures.sales_state_reason is
  'Motivo opcional del último cambio manual de apertura/cierre de ventas.';


alter table public.departures
  add column if not exists cancelled_at timestamptz;

alter table public.departures
  add column if not exists cancelled_by uuid
  references public.profiles(id) on delete set null;

alter table public.departures
  add column if not exists cancellation_reason text;

comment on column public.departures.cancelled_at is
  'Momento en que una salida comprometida fue cancelada como servicio. No equivale a cerrar ventas.';


alter table public.departures
  add column if not exists finalized_at timestamptz;

alter table public.departures
  add column if not exists finalized_by uuid
  references public.profiles(id) on delete set null;

comment on column public.departures.finalized_at is
  'Momento en que la visita fue finalizada operativamente. No se finaliza automáticamente.';


-- =========================================================
-- 2. MIGRAR EL SIGNIFICADO DEL STATUS LEGACY
-- =========================================================
--
-- Conservamos status para compatibilidad.
-- Inicializamos los nuevos campos a partir de la realidad existente.
--
-- No conocemos la fecha histórica exacta de cancelación/finalización
-- de datos antiguos. Usamos updated_at como mejor referencia disponible.

update public.departures
set
  sales_open = case
    when status = 'scheduled'::public.departure_status then true
    else false
  end,
  cancelled_at = case
    when status = 'cancelled'::public.departure_status
      then coalesce(cancelled_at, updated_at, created_at)
    else cancelled_at
  end,
  finalized_at = case
    when status = 'completed'::public.departure_status
      then coalesce(finalized_at, updated_at, created_at)
    else finalized_at
  end
where true;


-- =========================================================
-- 3. FLEXIBILIZAR CAPACIDAD
-- =========================================================
--
-- La capacidad deja de actuar como bloqueo físico de ocupación.
-- Puede existir, por ejemplo:
--
--   reservados 38 / capacidad 36
--
-- El sistema mostrará la anomalía, pero la base no la impedirá.

alter table public.departures
  drop constraint if exists departures_occupied_capacity_valid;

alter table public.departures
  add constraint departures_occupied_capacity_non_negative
  check (occupied_capacity >= 0);


-- El mínimo tampoco debe impedir modificar libremente la capacidad.

alter table public.departures
  drop constraint if exists departures_minimum_adults_valid;

alter table public.departures
  add constraint departures_minimum_adults_non_negative
  check (minimum_adults >= 0);


-- =========================================================
-- 4. ÍNDICES DE APOYO
-- =========================================================

create index if not exists idx_departures_sales_open_starts_at
  on public.departures(sales_open, starts_at);

create index if not exists idx_departures_cancelled_at
  on public.departures(cancelled_at)
  where cancelled_at is not null;

create index if not exists idx_departures_finalized_at
  on public.departures(finalized_at)
  where finalized_at is not null;


-- =========================================================
-- 5. NUEVA API: ABRIR / CERRAR OPERATIVA
-- =========================================================

create or replace function public.set_departure_sales_open(
  p_departure_id uuid,
  p_sales_open boolean,
  p_reason text default null
)
returns public.departures
language plpgsql
security definer
set search_path = public
as $$
declare
  v_departure public.departures;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para abrir o cerrar una Operativa';
  end if;

  if p_departure_id is null then
    raise exception 'La salida es obligatoria';
  end if;

  if p_sales_open is null then
    raise exception 'Debe indicarse si la Operativa queda abierta o cerrada';
  end if;

  select *
  into v_departure
  from public.departures
  where id = p_departure_id
  for update;

  if not found then
    raise exception 'Salida no encontrada';
  end if;

  if v_departure.cancelled_at is not null
     and p_sales_open = true
  then
    raise exception
      'La salida está cancelada como servicio. No puede reabrirse a ventas sin resolver antes la cancelación';
  end if;

  if v_departure.finalized_at is not null
     and p_sales_open = true
  then
    raise exception
      'La visita está finalizada y no puede reabrirse a ventas';
  end if;

  update public.departures
  set
    sales_open = p_sales_open,
    sales_state_changed_at = now(),
    sales_state_changed_by = auth.uid(),
    sales_state_reason = nullif(trim(coalesce(p_reason, '')), ''),

    -- Compatibilidad temporal con el status legacy.
    status = case
      when p_sales_open = true
        then 'scheduled'::public.departure_status
      else 'closed'::public.departure_status
    end,

    updated_by = auth.uid()
  where id = p_departure_id
  returning * into v_departure;

  return v_departure;
end;
$$;

revoke all on function public.set_departure_sales_open(
  uuid,
  boolean,
  text
) from public, anon;

grant execute on function public.set_departure_sales_open(
  uuid,
  boolean,
  text
) to authenticated;


-- =========================================================
-- 6. NUEVA API: CANCELAR UNA SALIDA CON CLIENTES
-- =========================================================

create or replace function public.cancel_departure_v1(
  p_departure_id uuid,
  p_reason text
)
returns public.departures
language plpgsql
security definer
set search_path = public
as $$
declare
  v_departure public.departures;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para cancelar una salida';
  end if;

  if p_departure_id is null then
    raise exception 'La salida es obligatoria';
  end if;

  if length(trim(coalesce(p_reason, ''))) < 3 then
    raise exception 'Debe indicarse un motivo de cancelación';
  end if;

  select *
  into v_departure
  from public.departures
  where id = p_departure_id
  for update;

  if not found then
    raise exception 'Salida no encontrada';
  end if;

  if v_departure.finalized_at is not null then
    raise exception 'Una visita ya finalizada no puede cancelarse';
  end if;

  update public.departures
  set
    sales_open = false,
    sales_state_changed_at = now(),
    sales_state_changed_by = auth.uid(),
    sales_state_reason = 'Cierre por cancelación de la salida',

    cancelled_at = coalesce(cancelled_at, now()),
    cancelled_by = auth.uid(),
    cancellation_reason = trim(p_reason),

    -- Compatibilidad temporal.
    status = 'cancelled'::public.departure_status,

    updated_by = auth.uid()
  where id = p_departure_id
  returning * into v_departure;

  return v_departure;
end;
$$;

revoke all on function public.cancel_departure_v1(
  uuid,
  text
) from public, anon;

grant execute on function public.cancel_departure_v1(
  uuid,
  text
) to authenticated;


-- =========================================================
-- 7. NUEVA API: FINALIZAR VISITA
-- =========================================================
--
-- En futuras migraciones, antes de ejecutar esta función,
-- Modo Guía revisará asistencia, pagos y consumos.
--
-- La base permite finalizar aunque después queden TAREAS
-- administrativas pendientes.

create or replace function public.finalize_departure_v1(
  p_departure_id uuid
)
returns public.departures
language plpgsql
security definer
set search_path = public
as $$
declare
  v_departure public.departures;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager','guide']::public.app_role[]
  ) then
    raise exception 'No autorizado para finalizar una visita';
  end if;

  if p_departure_id is null then
    raise exception 'La salida es obligatoria';
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
    raise exception 'Una salida cancelada no puede finalizarse como realizada';
  end if;

  update public.departures
  set
    sales_open = false,
    sales_state_changed_at = now(),
    sales_state_changed_by = auth.uid(),
    sales_state_reason = 'Cierre por finalización de la visita',

    finalized_at = coalesce(finalized_at, now()),
    finalized_by = auth.uid(),

    -- Compatibilidad temporal.
    status = 'completed'::public.departure_status,

    updated_by = auth.uid()
  where id = p_departure_id
  returning * into v_departure;

  return v_departure;
end;
$$;

revoke all on function public.finalize_departure_v1(uuid)
from public, anon;

grant execute on function public.finalize_departure_v1(uuid)
to authenticated;


-- =========================================================
-- 8. NUEVA API: MODIFICAR CAPACIDAD SIN BLOQUEOS ARTIFICIALES
-- =========================================================

create or replace function public.set_departure_capacity_v1(
  p_departure_id uuid,
  p_capacity integer
)
returns public.departures
language plpgsql
security definer
set search_path = public
as $$
declare
  v_departure public.departures;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para modificar la capacidad';
  end if;

  if p_departure_id is null then
    raise exception 'La salida es obligatoria';
  end if;

  if p_capacity is null or p_capacity <= 0 then
    raise exception 'La capacidad debe ser mayor que cero';
  end if;

  update public.departures
  set
    capacity = p_capacity,
    updated_by = auth.uid()
  where id = p_departure_id
  returning * into v_departure;

  if v_departure.id is null then
    raise exception 'Salida no encontrada';
  end if;

  return v_departure;
end;
$$;

revoke all on function public.set_departure_capacity_v1(
  uuid,
  integer
) from public, anon;

grant execute on function public.set_departure_capacity_v1(
  uuid,
  integer
) to authenticated;


-- =========================================================
-- 9. COMPATIBILIDAD CON LA API ANTIGUA
-- =========================================================
--
-- Sprint 1.3 todavía llama a set_departure_status().
-- Mientras migramos el frontend, hacemos que esa función mantenga
-- también los nuevos campos sincronizados.

create or replace function public.set_departure_status(
  p_departure_id uuid,
  p_status text
)
returns public.departures
language plpgsql
security definer
set search_path = public
as $$
declare
  v_departure public.departures;
  v_status public.departure_status;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para cambiar el estado';
  end if;

  begin
    v_status := p_status::public.departure_status;
  exception
    when invalid_text_representation then
      raise exception 'Estado de salida no válido: %', p_status;
  end;

  update public.departures
  set
    status = v_status,

    sales_open = case
      when v_status = 'scheduled'::public.departure_status
        then true
      else false
    end,

    sales_state_changed_at = now(),
    sales_state_changed_by = auth.uid(),
    sales_state_reason = 'Cambio realizado mediante API legacy',

    cancelled_at = case
      when v_status = 'cancelled'::public.departure_status
        then coalesce(cancelled_at, now())
      else null
    end,

    cancelled_by = case
      when v_status = 'cancelled'::public.departure_status
        then auth.uid()
      else null
    end,

    cancellation_reason = case
      when v_status = 'cancelled'::public.departure_status
        then coalesce(
          cancellation_reason,
          'Cancelación registrada mediante API legacy'
        )
      else null
    end,

    finalized_at = case
      when v_status = 'completed'::public.departure_status
        then coalesce(finalized_at, now())
      else null
    end,

    finalized_by = case
      when v_status = 'completed'::public.departure_status
        then auth.uid()
      else null
    end,

    updated_by = auth.uid()

  where id = p_departure_id
  returning * into v_departure;

  if v_departure.id is null then
    raise exception 'Salida no encontrada';
  end if;

  return v_departure;
end;
$$;

revoke all on function public.set_departure_status(uuid, text)
from public, anon;

grant execute on function public.set_departure_status(uuid, text)
to authenticated;


-- =========================================================
-- 10. VISTA DE DIAGNÓSTICO DE LA NUEVA OPERATIVA
-- =========================================================
--
-- Esta vista es únicamente una primera lectura del nuevo modelo.
-- Reservados, mínimo real y riesgo por canal se incorporarán cuando
-- exista el nuevo núcleo de Reservas.

create or replace view public.departure_operational_v1
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
  d.occupied_capacity,
  d.adult_minimum_count,

  d.sales_open,
  d.cancelled_at,
  d.cancellation_reason,
  d.finalized_at,

  case
    when d.finalized_at is not null then 'finalized'
    when d.cancelled_at is not null then 'cancelled'
    when d.sales_open = true then 'open'
    else 'closed'
  end as operational_state,

  case
    when d.capacity is null then false
    when d.occupied_capacity > d.capacity then true
    else false
  end as over_capacity,

  case
    when d.adult_minimum_count >= d.minimum_adults then true
    else false
  end as minimum_reached,

  d.status as legacy_status,
  d.kind,
  d.source,
  d.publication,
  d.created_at,
  d.updated_at

from public.departures d;

grant select on public.departure_operational_v1
to authenticated;


-- =========================================================
-- 11. AUDITORÍA
-- =========================================================
--
-- departures ya dispone de trigger de auditoría creado en
-- migraciones anteriores, por lo que los nuevos campos quedan
-- incluidos automáticamente en old_data/new_data.


commit;