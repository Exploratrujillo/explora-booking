-- Explora Booking
-- Arquitectura funcional v1
-- Migración E: Tareas, eventos de dominio y situaciones operativas
-- Fecha: 2026-08-08
--
-- OBJETIVO
-- -------
-- Añadir la capa que transforma hechos ya registrados en elementos
-- accionables para Inicio / Oficina, sin duplicar la auditoría técnica.
--
-- MODELO
-- ------
-- 1) audit_log:
--    historial técnico ya existente. Se conserva sin cambios.
--
-- 2) domain_events:
--    hechos de negocio relevantes e inmutables.
--
-- 3) operational_tasks:
--    acciones persistentes que requieren resolución humana.
--
-- 4) operational_situations_v1:
--    situaciones calculadas a partir del estado actual.
--    NO se almacenan y desaparecen cuando deja de existir su causa.
--
-- PRINCIPIOS
-- ----------
-- - Una situación calculada no se "marca como hecha".
-- - Una tarea sí tiene ciclo de vida.
-- - Resolver una tarea no modifica por sí solo la Reserva, Pago, Salida, etc.
-- - Los informes futuros leerán estos datos, pero no los modificarán.
-- - No se crean notificaciones push/email/WhatsApp automáticas aquí.
-- - No se duplica audit_log.

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
    where t.typname = 'domain_event_type'
      and n.nspname = 'public'
  ) then
    create type public.domain_event_type as enum (
      'booking_created',
      'booking_updated',
      'booking_cancelled',
      'payment_recorded',
      'refund_recorded',
      'attendance_recorded',
      'communication_recorded',
      'communication_acknowledged',
      'departure_changed',
      'departure_cancelled',
      'departure_finalized',
      'task_created',
      'task_resolved',
      'other'
    );
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'operational_task_status'
      and n.nspname = 'public'
  ) then
    create type public.operational_task_status as enum (
      'open',
      'in_progress',
      'resolved',
      'dismissed'
    );
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'operational_priority'
      and n.nspname = 'public'
  ) then
    create type public.operational_priority as enum (
      'low',
      'normal',
      'high',
      'urgent'
    );
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'operational_entity_type'
      and n.nspname = 'public'
  ) then
    create type public.operational_entity_type as enum (
      'booking',
      'departure',
      'communication',
      'payment',
      'resource',
      'other'
    );
  end if;
end
$$;


-- =========================================================
-- 2. EVENTOS DE DOMINIO
-- =========================================================
--
-- Registro funcional de hechos relevantes.
-- No sustituye audit_log: audit_log responde "qué cambió técnicamente";
-- domain_events responde "qué ocurrió en el negocio".

create table if not exists public.domain_events (
  id bigint generated always as identity primary key,

  event_type public.domain_event_type not null,
  entity_type public.operational_entity_type not null,
  entity_id text not null,

  booking_id uuid references public.bookings(id) on delete set null,
  departure_id uuid references public.departures(id) on delete set null,

  occurred_at timestamptz not null default now(),

  title text not null,
  payload jsonb not null default '{}'::jsonb,

  source_context text,
  created_by uuid references public.profiles(id) on delete set null,

  constraint domain_events_entity_id_not_blank
    check (length(trim(entity_id)) > 0),

  constraint domain_events_title_not_blank
    check (length(trim(title)) > 0),

  constraint domain_events_payload_object
    check (jsonb_typeof(payload) = 'object')
);

create index if not exists idx_domain_events_occurred_at
  on public.domain_events(occurred_at desc);

create index if not exists idx_domain_events_entity
  on public.domain_events(entity_type, entity_id, occurred_at desc);

create index if not exists idx_domain_events_booking
  on public.domain_events(booking_id, occurred_at desc);

create index if not exists idx_domain_events_departure
  on public.domain_events(departure_id, occurred_at desc);

comment on table public.domain_events is
  'Eventos funcionales de negocio. Complementan, pero no sustituyen, el historial técnico audit_log.';


-- =========================================================
-- 3. TAREAS OPERATIVAS
-- =========================================================
--
-- Las tareas representan trabajo humano pendiente.
-- Pueden nacer manualmente o como consecuencia de un evento.
--
-- deduplication_key permite evitar tareas duplicadas para la misma causa.

create table if not exists public.operational_tasks (
  id uuid primary key default gen_random_uuid(),

  title text not null,
  description text,

  status public.operational_task_status not null default 'open',
  priority public.operational_priority not null default 'normal',

  entity_type public.operational_entity_type,
  entity_id text,

  booking_id uuid references public.bookings(id) on delete set null,
  departure_id uuid references public.departures(id) on delete set null,
  communication_id uuid
    references public.booking_communications(id) on delete set null,

  source_event_id bigint
    references public.domain_events(id) on delete set null,

  deduplication_key text,

  due_at timestamptz,
  assigned_to uuid references public.profiles(id) on delete set null,

  resolved_at timestamptz,
  resolved_by uuid references public.profiles(id) on delete set null,
  resolution_note text,

  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint operational_tasks_title_not_blank
    check (length(trim(title)) > 0),

  constraint operational_tasks_entity_consistent
    check (
      (entity_type is null and entity_id is null)
      or
      (entity_type is not null and entity_id is not null)
    ),

  constraint operational_tasks_resolution_consistent
    check (
      status not in (
        'resolved'::public.operational_task_status,
        'dismissed'::public.operational_task_status
      )
      or resolved_at is not null
    )
);

create unique index if not exists uq_operational_tasks_active_dedup
  on public.operational_tasks(deduplication_key)
  where deduplication_key is not null
    and status in (
      'open'::public.operational_task_status,
      'in_progress'::public.operational_task_status
    );

create index if not exists idx_operational_tasks_active
  on public.operational_tasks(status, priority, due_at);

create index if not exists idx_operational_tasks_booking
  on public.operational_tasks(booking_id, status);

create index if not exists idx_operational_tasks_departure
  on public.operational_tasks(departure_id, status);

create index if not exists idx_operational_tasks_assigned
  on public.operational_tasks(assigned_to, status, due_at);

drop trigger if exists trg_operational_tasks_set_updated_at
  on public.operational_tasks;

create trigger trg_operational_tasks_set_updated_at
before update on public.operational_tasks
for each row execute function public.set_updated_at();

comment on table public.operational_tasks is
  'Acciones persistentes que requieren intervención humana y permanecen hasta su resolución o descarte.';


-- =========================================================
-- 4. RPC INTERNA: REGISTRAR EVENTO
-- =========================================================

create or replace function public.record_domain_event_v1(
  p_event_type public.domain_event_type,
  p_entity_type public.operational_entity_type,
  p_entity_id text,
  p_title text,
  p_booking_id uuid default null,
  p_departure_id uuid default null,
  p_payload jsonb default '{}'::jsonb,
  p_source_context text default null
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
    array['owner','admin','manager','guide']::public.app_role[]
  ) then
    raise exception 'No autorizado para registrar eventos de dominio';
  end if;

  if p_entity_id is null or length(trim(p_entity_id)) = 0 then
    raise exception 'entity_id es obligatorio';
  end if;

  if p_title is null or length(trim(p_title)) = 0 then
    raise exception 'title es obligatorio';
  end if;

  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'payload debe ser un objeto JSON';
  end if;

  insert into public.domain_events (
    event_type,
    entity_type,
    entity_id,
    booking_id,
    departure_id,
    title,
    payload,
    source_context,
    created_by
  )
  values (
    p_event_type,
    p_entity_type,
    trim(p_entity_id),
    p_booking_id,
    p_departure_id,
    trim(p_title),
    p_payload,
    nullif(trim(coalesce(p_source_context, '')), ''),
    auth.uid()
  )
  returning id into v_id;

  return v_id;
end;
$$;


-- =========================================================
-- 5. RPC: CREAR TAREA
-- =========================================================

create or replace function public.create_operational_task_v1(
  p_title text,
  p_description text default null,
  p_priority public.operational_priority default 'normal',
  p_entity_type public.operational_entity_type default null,
  p_entity_id text default null,
  p_booking_id uuid default null,
  p_departure_id uuid default null,
  p_communication_id uuid default null,
  p_source_event_id bigint default null,
  p_deduplication_key text default null,
  p_due_at timestamptz default null,
  p_assigned_to uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_existing uuid;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para crear tareas operativas';
  end if;

  if p_title is null or length(trim(p_title)) = 0 then
    raise exception 'El título de la tarea es obligatorio';
  end if;

  if (p_entity_type is null) <> (p_entity_id is null) then
    raise exception 'entity_type y entity_id deben indicarse juntos';
  end if;

  if p_deduplication_key is not null
     and length(trim(p_deduplication_key)) > 0
  then
    select id
    into v_existing
    from public.operational_tasks
    where deduplication_key = trim(p_deduplication_key)
      and status in (
        'open'::public.operational_task_status,
        'in_progress'::public.operational_task_status
      )
    limit 1;

    if v_existing is not null then
      return v_existing;
    end if;
  end if;

  insert into public.operational_tasks (
    title,
    description,
    priority,
    entity_type,
    entity_id,
    booking_id,
    departure_id,
    communication_id,
    source_event_id,
    deduplication_key,
    due_at,
    assigned_to,
    created_by,
    updated_by
  )
  values (
    trim(p_title),
    nullif(trim(coalesce(p_description, '')), ''),
    p_priority,
    p_entity_type,
    case
      when p_entity_id is null then null
      else trim(p_entity_id)
    end,
    p_booking_id,
    p_departure_id,
    p_communication_id,
    p_source_event_id,
    nullif(trim(coalesce(p_deduplication_key, '')), ''),
    p_due_at,
    p_assigned_to,
    auth.uid(),
    auth.uid()
  )
  returning id into v_id;

  return v_id;
end;
$$;


-- =========================================================
-- 6. RPC: CAMBIAR ESTADO / RESOLVER TAREA
-- =========================================================

create or replace function public.set_operational_task_status_v1(
  p_task_id uuid,
  p_status public.operational_task_status,
  p_resolution_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_task public.operational_tasks%rowtype;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para modificar tareas operativas';
  end if;

  select *
  into v_task
  from public.operational_tasks
  where id = p_task_id;

  if not found then
    raise exception 'Tarea no encontrada';
  end if;

  update public.operational_tasks
  set
    status = p_status,
    resolved_at = case
      when p_status in (
        'resolved'::public.operational_task_status,
        'dismissed'::public.operational_task_status
      )
      then coalesce(resolved_at, now())
      else null
    end,
    resolved_by = case
      when p_status in (
        'resolved'::public.operational_task_status,
        'dismissed'::public.operational_task_status
      )
      then auth.uid()
      else null
    end,
    resolution_note = case
      when p_status in (
        'resolved'::public.operational_task_status,
        'dismissed'::public.operational_task_status
      )
      then nullif(trim(coalesce(p_resolution_note, '')), '')
      else null
    end,
    updated_by = auth.uid()
  where id = p_task_id;

  return p_task_id;
end;
$$;


-- =========================================================
-- 7. VISTA DE TAREAS ACTIVAS
-- =========================================================

create or replace view public.active_operational_tasks_v1
with (security_invoker = true)
as
select
  t.id,
  t.title,
  t.description,
  t.status,
  t.priority,

  t.entity_type,
  t.entity_id,

  t.booking_id,
  b.booking_reference,
  b.contact_name,

  t.departure_id,
  d.starts_at as departure_starts_at,
  d.experience_id,

  t.communication_id,
  t.source_event_id,

  t.deduplication_key,
  t.due_at,
  t.assigned_to,

  case
    when t.due_at is not null
      and t.due_at < now()
    then true
    else false
  end as overdue,

  t.created_at,
  t.updated_at

from public.operational_tasks t
left join public.bookings b
  on b.id = t.booking_id
left join public.departures d
  on d.id = t.departure_id
where t.status in (
  'open'::public.operational_task_status,
  'in_progress'::public.operational_task_status
);

grant select on public.active_operational_tasks_v1
to authenticated;


-- =========================================================
-- 8. SITUACIONES CALCULADAS
-- =========================================================
--
-- Esta vista NO guarda estados.
-- Cada fila existe únicamente mientras exista la causa.
--
-- Primera versión:
--   - salida con mínimo aún no alcanzado;
--   - comunicación que requiere OK;
--   - Reserva con importe pendiente;
--   - salida pasada que todavía no ha sido finalizada.
--
-- Inventario/stock añadirá después sus propias situaciones sin
-- convertirlas en tareas persistentes automáticamente.

create or replace view public.operational_situations_v1
with (security_invoker = true)
as

-- A. Salida pendiente de alcanzar mínimo
select
  'departure_minimum_not_reached'::text as situation_type,
  'departure'::public.operational_entity_type as entity_type,
  d.id::text as entity_id,
  null::uuid as booking_id,
  d.id as departure_id,
  null::uuid as communication_id,
  'normal'::public.operational_priority as priority,
  'Mínimo de adultos pendiente'::text as title,
  (
    'La salida tiene '
    || coalesce(d.adult_minimum_count, 0)::text
    || ' de '
    || d.minimum_adults::text
    || ' adultos mínimos'
  )::text as detail,
  d.starts_at as relevant_at

from public.departure_operational_v1 d
where d.operational_state = 'open'
  and d.minimum_reached = false
  and d.minimum_adults > 0
  and d.starts_at >= now()

union all

-- B. Comunicación pendiente de OK
select
  'communication_pending_ack'::text,
  'communication'::public.operational_entity_type,
  p.communication_id::text,
  p.booking_id,
  p.departure_id,
  p.communication_id,
  case
    when d.starts_at is not null
      and d.starts_at <= now() + interval '24 hours'
    then 'high'::public.operational_priority
    else 'normal'::public.operational_priority
  end,
  'Cliente pendiente de confirmar comunicación'::text,
  coalesce(
    p.message_summary,
    'Comunicación enviada pendiente de OK'
  )::text,
  coalesce(p.sent_at, p.created_at)

from public.pending_booking_acknowledgements_v1 p
left join public.departures d
  on d.id = p.departure_id

union all

-- C. Reserva con importe pendiente
select
  'booking_payment_pending'::text,
  'booking'::public.operational_entity_type,
  s.booking_id::text,
  s.booking_id,
  b.departure_id,
  null::uuid,
  case
    when d.starts_at is not null
      and d.starts_at <= now() + interval '24 hours'
    then 'high'::public.operational_priority
    else 'normal'::public.operational_priority
  end,
  'Cobro pendiente'::text,
  (
    'Pendiente: '
    || to_char(s.outstanding_cents / 100.0, 'FM999999990D00')
    || ' '
    || s.booking_currency
  )::text,
  coalesce(d.starts_at, b.created_at)

from public.booking_payment_summary_v1 s
join public.bookings b
  on b.id = s.booking_id
left join public.departures d
  on d.id = b.departure_id
where b.status = 'confirmed'::public.booking_status
  and s.outstanding_cents > 0

union all

-- D. Salida pasada pendiente de finalizar
select
  'departure_pending_finalization'::text,
  'departure'::public.operational_entity_type,
  d.id::text,
  null::uuid,
  d.id,
  null::uuid,
  'high'::public.operational_priority,
  'Visita pendiente de finalizar'::text,
  'La hora de la salida ya ha pasado y todavía no consta como finalizada'::text,
  d.starts_at

from public.departure_operational_v1 d
where d.operational_state not in ('finalized', 'cancelled')
  and d.starts_at < now();

grant select on public.operational_situations_v1
to authenticated;

comment on view public.operational_situations_v1 is
  'Situaciones calculadas a partir del estado actual. No son tareas y desaparecen cuando desaparece su causa.';


-- =========================================================
-- 9. BANDEJA UNIFICADA PARA INICIO
-- =========================================================
--
-- Permite que Inicio consuma Situaciones + Tareas activas en una
-- sola consulta, manteniendo claro cuál es cuál.

create or replace view public.operational_inbox_v1
with (security_invoker = true)
as

select
  ('situation:' || s.situation_type || ':' || s.entity_id)::text as item_key,
  'situation'::text as item_kind,
  s.situation_type as item_type,
  s.entity_type,
  s.entity_id,
  s.booking_id,
  s.departure_id,
  s.communication_id,
  s.priority,
  s.title,
  s.detail,
  s.relevant_at,
  null::uuid as task_id,
  false as manually_resolvable

from public.operational_situations_v1 s

union all

select
  ('task:' || t.id::text)::text,
  'task'::text,
  'operational_task'::text,
  coalesce(t.entity_type, 'other'::public.operational_entity_type),
  coalesce(t.entity_id, t.id::text),
  t.booking_id,
  t.departure_id,
  t.communication_id,
  t.priority,
  t.title,
  t.description,
  coalesce(t.due_at, t.created_at),
  t.id,
  true

from public.active_operational_tasks_v1 t;

grant select on public.operational_inbox_v1
to authenticated;

comment on view public.operational_inbox_v1 is
  'Bandeja unificada para Inicio: situaciones calculadas y tareas persistentes, diferenciadas explícitamente.';


-- =========================================================
-- 10. AUDITORÍA
-- =========================================================
--
-- domain_events es ya un registro histórico funcional e inmutable,
-- por lo que no se audita a sí mismo.
-- operational_tasks sí se audita mediante el sistema técnico existente.

drop trigger if exists trg_audit_operational_tasks
  on public.operational_tasks;

create trigger trg_audit_operational_tasks
after insert or update or delete on public.operational_tasks
for each row execute function public.write_audit_log();


-- =========================================================
-- 11. RLS
-- =========================================================

alter table public.domain_events enable row level security;
alter table public.operational_tasks enable row level security;

drop policy if exists domain_events_operational_read
  on public.domain_events;

create policy domain_events_operational_read
on public.domain_events
for select
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager','guide']::public.app_role[]
  )
);

drop policy if exists operational_tasks_management_read
  on public.operational_tasks;

create policy operational_tasks_management_read
on public.operational_tasks
for select
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  )
);

-- Escritura directa no concedida.
-- Se realiza mediante RPC para conservar reglas y permisos.


-- =========================================================
-- 12. PERMISOS RPC
-- =========================================================

revoke all on function public.record_domain_event_v1(
  public.domain_event_type,
  public.operational_entity_type,
  text,
  text,
  uuid,
  uuid,
  jsonb,
  text
) from public, anon;

grant execute on function public.record_domain_event_v1(
  public.domain_event_type,
  public.operational_entity_type,
  text,
  text,
  uuid,
  uuid,
  jsonb,
  text
) to authenticated;


revoke all on function public.create_operational_task_v1(
  text,
  text,
  public.operational_priority,
  public.operational_entity_type,
  text,
  uuid,
  uuid,
  uuid,
  bigint,
  text,
  timestamptz,
  uuid
) from public, anon;

grant execute on function public.create_operational_task_v1(
  text,
  text,
  public.operational_priority,
  public.operational_entity_type,
  text,
  uuid,
  uuid,
  uuid,
  bigint,
  text,
  timestamptz,
  uuid
) to authenticated;


revoke all on function public.set_operational_task_status_v1(
  uuid,
  public.operational_task_status,
  text
) from public, anon;

grant execute on function public.set_operational_task_status_v1(
  uuid,
  public.operational_task_status,
  text
) to authenticated;


-- =========================================================
-- 13. COMENTARIOS FINALES
-- =========================================================

comment on view public.active_operational_tasks_v1 is
  'Tareas operativas abiertas o en curso, enriquecidas con Reserva y Salida.';

commit;
