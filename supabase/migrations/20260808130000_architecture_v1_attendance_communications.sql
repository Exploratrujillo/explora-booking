-- Explora Booking
-- Arquitectura funcional v1
-- Migración D: Asistencia y comunicaciones operativas
-- Fecha: 2026-08-08
--
-- OBJETIVO
-- -------
-- Construir la capa del día de la visita sin mezclarla con pagos:
--
--   1) Asistencia de una Reserva a una salida.
--   2) No-Show como hecho operativo, NO como estado económico.
--   3) Registro de comunicaciones con el cliente.
--   4) Confirmación/OK del cliente cuando una comunicación requiere respuesta.
--
-- PRINCIPIOS
-- ----------
-- - Una Reserva puede estar pendiente, presente, parcialmente presente o no-show.
-- - El estado de asistencia es independiente del estado de pago.
-- - No-Show no modifica ni borra pagos.
-- - Las consecuencias económicas se calcularán después cruzando asistencia + pagos.
-- - Las comunicaciones quedan ligadas a la Reserva y, cuando procede, a la salida.
-- - WhatsApp enviado y OK recibido son hechos distintos.
-- - Un cambio de hora/cancelación puede requerir confirmación del cliente.
-- - Oficina y Modo Guía pueden registrar hechos operativos.
-- - No se implementa envío automático de WhatsApp/email en esta migración:
--   aquí se registra y estructura la operativa para que la interfaz pueda usarla.

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
    where t.typname = 'booking_attendance_status'
      and n.nspname = 'public'
  ) then
    create type public.booking_attendance_status as enum (
      'pending',
      'present',
      'partial',
      'no_show'
    );
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'communication_channel'
      and n.nspname = 'public'
  ) then
    create type public.communication_channel as enum (
      'whatsapp',
      'phone',
      'sms',
      'email',
      'in_person',
      'other'
    );
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'communication_direction'
      and n.nspname = 'public'
  ) then
    create type public.communication_direction as enum (
      'outbound',
      'inbound'
    );
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'communication_purpose'
      and n.nspname = 'public'
  ) then
    create type public.communication_purpose as enum (
      'general',
      'booking_confirmation',
      'meeting_point',
      'time_change',
      'departure_cancellation',
      'payment',
      'late_arrival',
      'other'
    );
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'communication_status'
      and n.nspname = 'public'
  ) then
    create type public.communication_status as enum (
      'pending',
      'sent',
      'delivered',
      'acknowledged',
      'failed'
    );
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'operational_entry_context'
      and n.nspname = 'public'
  ) then
    create type public.operational_entry_context as enum (
      'office',
      'guide',
      'system',
      'import'
    );
  end if;
end
$$;


-- =========================================================
-- 2. ASISTENCIA POR RESERVA
-- =========================================================
--
-- Una fila por Reserva.
-- La salida se fotografía desde bookings.departure_id para facilitar
-- consultas de Modo Guía y preservar el contexto operativo.
--
-- expected_participants / attended_participants son opcionales:
-- permiten reflejar asistencia parcial sin obligarnos todavía a
-- gestionar check-in persona por persona.

create table if not exists public.booking_attendance (
  id uuid primary key default gen_random_uuid(),

  booking_id uuid not null
    references public.bookings(id) on delete restrict,

  departure_id uuid not null
    references public.departures(id) on delete restrict,

  status public.booking_attendance_status
    not null default 'pending',

  expected_participants integer,
  attended_participants integer,

  checked_in_at timestamptz,
  marked_no_show_at timestamptz,

  entry_context public.operational_entry_context
    not null default 'office',

  notes text,

  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint booking_attendance_booking_unique
    unique (booking_id),

  constraint booking_attendance_expected_valid
    check (
      expected_participants is null
      or expected_participants >= 0
    ),

  constraint booking_attendance_attended_valid
    check (
      attended_participants is null
      or attended_participants >= 0
    ),

  constraint booking_attendance_counts_consistent
    check (
      expected_participants is null
      or attended_participants is null
      or attended_participants <= expected_participants
    ),

  constraint booking_attendance_present_consistent
    check (
      status <> 'present'::public.booking_attendance_status
      or expected_participants is null
      or attended_participants is null
      or attended_participants = expected_participants
    ),

  constraint booking_attendance_no_show_consistent
    check (
      status <> 'no_show'::public.booking_attendance_status
      or attended_participants is null
      or attended_participants = 0
    )
);

create index if not exists idx_booking_attendance_departure
  on public.booking_attendance(departure_id, status);

create index if not exists idx_booking_attendance_status
  on public.booking_attendance(status);

drop trigger if exists trg_booking_attendance_set_updated_at
  on public.booking_attendance;

create trigger trg_booking_attendance_set_updated_at
before update on public.booking_attendance
for each row execute function public.set_updated_at();

comment on table public.booking_attendance is
  'Estado operativo de asistencia de una Reserva. No-Show es independiente del estado de pago.';


-- =========================================================
-- 3. COMUNICACIONES OPERATIVAS
-- =========================================================
--
-- message_summary guarda una descripción breve, no pretende sustituir
-- el contenido completo de WhatsApp/email.
--
-- requires_acknowledgement:
--   true cuando necesitamos saber que el cliente ha recibido/aceptado
--   la información (por ejemplo cambio de hora o cancelación).
--
-- acknowledged_at:
--   momento en que recibimos el OK/respuesta del cliente.

create table if not exists public.booking_communications (
  id uuid primary key default gen_random_uuid(),

  booking_id uuid not null
    references public.bookings(id) on delete restrict,

  departure_id uuid
    references public.departures(id) on delete restrict,

  channel public.communication_channel not null,
  direction public.communication_direction not null default 'outbound',
  purpose public.communication_purpose not null default 'general',
  status public.communication_status not null default 'pending',

  message_summary text,

  requires_acknowledgement boolean not null default false,
  sent_at timestamptz,
  delivered_at timestamptz,
  acknowledged_at timestamptz,
  failed_at timestamptz,

  external_reference text,
  entry_context public.operational_entry_context
    not null default 'office',

  notes text,

  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint booking_communications_summary_not_blank
    check (
      message_summary is null
      or length(trim(message_summary)) > 0
    ),

  constraint booking_communications_ack_consistent
    check (
      acknowledged_at is null
      or requires_acknowledgement = true
    )
);

create index if not exists idx_booking_communications_booking
  on public.booking_communications(booking_id, created_at desc);

create index if not exists idx_booking_communications_departure
  on public.booking_communications(departure_id, created_at desc);

create index if not exists idx_booking_communications_pending_ack
  on public.booking_communications(
    departure_id,
    requires_acknowledgement,
    acknowledged_at
  );

drop trigger if exists trg_booking_communications_set_updated_at
  on public.booking_communications;

create trigger trg_booking_communications_set_updated_at
before update on public.booking_communications
for each row execute function public.set_updated_at();

comment on table public.booking_communications is
  'Histórico operativo de comunicaciones con clientes, incluyendo envío y confirmación/OK como hechos separados.';


-- =========================================================
-- 4. VALIDACIÓN: LA ASISTENCIA DEBE PERTENECER A LA SALIDA
-- =========================================================

create or replace function public.validate_booking_attendance_departure_v1()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_booking_departure_id uuid;
begin
  select b.departure_id
  into v_booking_departure_id
  from public.bookings b
  where b.id = new.booking_id;

  if v_booking_departure_id is null then
    raise exception 'La Reserva no tiene una salida asociada';
  end if;

  if new.departure_id <> v_booking_departure_id then
    raise exception
      'La salida de asistencia no coincide con la salida de la Reserva';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_validate_booking_attendance_departure
  on public.booking_attendance;

create trigger trg_validate_booking_attendance_departure
before insert or update of booking_id, departure_id
on public.booking_attendance
for each row execute function public.validate_booking_attendance_departure_v1();


-- =========================================================
-- 5. VISTA: ASISTENCIA OPERATIVA POR SALIDA
-- =========================================================

create or replace view public.departure_attendance_summary_v1
with (security_invoker = true)
as
select
  d.id as departure_id,

  count(b.id) filter (
    where b.status = 'confirmed'::public.booking_status
  )::integer as confirmed_bookings,

  count(b.id) filter (
    where b.status = 'confirmed'::public.booking_status
      and coalesce(a.status, 'pending'::public.booking_attendance_status)
          = 'pending'::public.booking_attendance_status
  )::integer as pending_bookings,

  count(b.id) filter (
    where b.status = 'confirmed'::public.booking_status
      and a.status = 'present'::public.booking_attendance_status
  )::integer as present_bookings,

  count(b.id) filter (
    where b.status = 'confirmed'::public.booking_status
      and a.status = 'partial'::public.booking_attendance_status
  )::integer as partial_bookings,

  count(b.id) filter (
    where b.status = 'confirmed'::public.booking_status
      and a.status = 'no_show'::public.booking_attendance_status
  )::integer as no_show_bookings,

  coalesce(
    sum(a.attended_participants) filter (
      where b.status = 'confirmed'::public.booking_status
        and a.status in (
          'present'::public.booking_attendance_status,
          'partial'::public.booking_attendance_status
        )
    ),
    0
  )::integer as attended_participants

from public.departures d
left join public.bookings b
  on b.departure_id = d.id
left join public.booking_attendance a
  on a.booking_id = b.id
group by d.id;

grant select on public.departure_attendance_summary_v1
to authenticated;


-- =========================================================
-- 6. VISTA: COMUNICACIONES QUE REQUIEREN ATENCIÓN
-- =========================================================
--
-- Útil para Próxima salida / Modo Guía:
-- "Hay clientes a los que hemos avisado de un cambio pero todavía
-- no han dado OK."

create or replace view public.pending_booking_acknowledgements_v1
with (security_invoker = true)
as
select
  c.id as communication_id,
  c.booking_id,
  c.departure_id,

  b.booking_reference,
  b.contact_name,
  b.contact_phone,

  c.channel,
  c.purpose,
  c.status,
  c.message_summary,
  c.sent_at,
  c.requires_acknowledgement,
  c.acknowledged_at,
  c.created_at

from public.booking_communications c
join public.bookings b
  on b.id = c.booking_id
where b.status = 'confirmed'::public.booking_status
  and c.direction = 'outbound'::public.communication_direction
  and c.requires_acknowledgement = true
  and c.acknowledged_at is null
  and c.status <> 'failed'::public.communication_status;

grant select on public.pending_booking_acknowledgements_v1
to authenticated;


-- =========================================================
-- 7. RPC: MARCAR ASISTENCIA
-- =========================================================

create or replace function public.set_booking_attendance_v1(
  p_booking_id uuid,
  p_status public.booking_attendance_status,
  p_attended_participants integer default null,
  p_entry_context public.operational_entry_context default 'guide',
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings%rowtype;
  v_expected integer;
  v_attended integer;
  v_id uuid;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager','guide']::public.app_role[]
  ) then
    raise exception 'No autorizado para registrar asistencia';
  end if;

  select *
  into v_booking
  from public.bookings
  where id = p_booking_id;

  if not found then
    raise exception 'Reserva no encontrada';
  end if;

  if v_booking.status <> 'confirmed'::public.booking_status then
    raise exception 'Solo puede registrarse asistencia sobre una Reserva confirmada';
  end if;

  select coalesce(sum(bp.quantity), 0)::integer
  into v_expected
  from public.booking_participants bp
  where bp.booking_id = p_booking_id
    and bp.counts_towards_capacity = true;

  if p_status = 'no_show'::public.booking_attendance_status then
    v_attended := 0;

  elsif p_status = 'present'::public.booking_attendance_status then
    v_attended := coalesce(p_attended_participants, v_expected);

    if v_expected > 0 and v_attended <> v_expected then
      raise exception
        'Para asistencia completa deben asistir % participantes',
        v_expected;
    end if;

  elsif p_status = 'partial'::public.booking_attendance_status then
    if p_attended_participants is null then
      raise exception
        'Debe indicar cuántas personas asistieron en una asistencia parcial';
    end if;

    v_attended := p_attended_participants;

    if v_attended <= 0 then
      raise exception
        'Una asistencia parcial debe tener al menos una persona asistente';
    end if;

    if v_expected > 0 and v_attended >= v_expected then
      raise exception
        'Si asisten todos los participantes use el estado present';
    end if;

  else
    v_attended := null;
  end if;

  insert into public.booking_attendance (
    booking_id,
    departure_id,
    status,
    expected_participants,
    attended_participants,
    checked_in_at,
    marked_no_show_at,
    entry_context,
    notes,
    created_by,
    updated_by
  )
  values (
    p_booking_id,
    v_booking.departure_id,
    p_status,
    v_expected,
    v_attended,
    case
      when p_status in (
        'present'::public.booking_attendance_status,
        'partial'::public.booking_attendance_status
      )
      then now()
      else null
    end,
    case
      when p_status = 'no_show'::public.booking_attendance_status
      then now()
      else null
    end,
    p_entry_context,
    p_notes,
    auth.uid(),
    auth.uid()
  )
  on conflict (booking_id)
  do update set
    departure_id = excluded.departure_id,
    status = excluded.status,
    expected_participants = excluded.expected_participants,
    attended_participants = excluded.attended_participants,
    checked_in_at = excluded.checked_in_at,
    marked_no_show_at = excluded.marked_no_show_at,
    entry_context = excluded.entry_context,
    notes = excluded.notes,
    updated_by = auth.uid()
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.set_booking_attendance_v1(
  uuid,
  public.booking_attendance_status,
  integer,
  public.operational_entry_context,
  text
) from public, anon;

grant execute on function public.set_booking_attendance_v1(
  uuid,
  public.booking_attendance_status,
  integer,
  public.operational_entry_context,
  text
) to authenticated;


-- =========================================================
-- 8. RPC: REGISTRAR COMUNICACIÓN
-- =========================================================

create or replace function public.register_booking_communication_v1(
  p_booking_id uuid,
  p_channel public.communication_channel,
  p_direction public.communication_direction default 'outbound',
  p_purpose public.communication_purpose default 'general',
  p_status public.communication_status default 'sent',
  p_message_summary text default null,
  p_requires_acknowledgement boolean default false,
  p_entry_context public.operational_entry_context default 'office',
  p_external_reference text default null,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings%rowtype;
  v_id uuid;
  v_now timestamptz := now();
begin
  if not public.current_user_has_role(
    array['owner','admin','manager','guide']::public.app_role[]
  ) then
    raise exception 'No autorizado para registrar comunicaciones';
  end if;

  select *
  into v_booking
  from public.bookings
  where id = p_booking_id;

  if not found then
    raise exception 'Reserva no encontrada';
  end if;

  insert into public.booking_communications (
    booking_id,
    departure_id,
    channel,
    direction,
    purpose,
    status,
    message_summary,
    requires_acknowledgement,
    sent_at,
    delivered_at,
    acknowledged_at,
    failed_at,
    external_reference,
    entry_context,
    notes,
    created_by,
    updated_by
  )
  values (
    p_booking_id,
    v_booking.departure_id,
    p_channel,
    p_direction,
    p_purpose,
    p_status,
    nullif(trim(coalesce(p_message_summary, '')), ''),
    p_requires_acknowledgement,
    case
      when p_status in (
        'sent'::public.communication_status,
        'delivered'::public.communication_status,
        'acknowledged'::public.communication_status
      )
      then v_now
      else null
    end,
    case
      when p_status in (
        'delivered'::public.communication_status,
        'acknowledged'::public.communication_status
      )
      then v_now
      else null
    end,
    case
      when p_status = 'acknowledged'::public.communication_status
       and p_requires_acknowledgement = true
      then v_now
      else null
    end,
    case
      when p_status = 'failed'::public.communication_status
      then v_now
      else null
    end,
    nullif(trim(coalesce(p_external_reference, '')), ''),
    p_entry_context,
    p_notes,
    auth.uid(),
    auth.uid()
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.register_booking_communication_v1(
  uuid,
  public.communication_channel,
  public.communication_direction,
  public.communication_purpose,
  public.communication_status,
  text,
  boolean,
  public.operational_entry_context,
  text,
  text
) from public, anon;

grant execute on function public.register_booking_communication_v1(
  uuid,
  public.communication_channel,
  public.communication_direction,
  public.communication_purpose,
  public.communication_status,
  text,
  boolean,
  public.operational_entry_context,
  text,
  text
) to authenticated;


-- =========================================================
-- 9. RPC: REGISTRAR EL OK / CONFIRMACIÓN DEL CLIENTE
-- =========================================================

create or replace function public.acknowledge_booking_communication_v1(
  p_communication_id uuid,
  p_entry_context public.operational_entry_context default 'office',
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_comm public.booking_communications%rowtype;
begin
  if not public.current_user_has_role(
    array['owner','admin','manager','guide']::public.app_role[]
  ) then
    raise exception 'No autorizado para confirmar comunicaciones';
  end if;

  select *
  into v_comm
  from public.booking_communications
  where id = p_communication_id;

  if not found then
    raise exception 'Comunicación no encontrada';
  end if;

  if v_comm.requires_acknowledgement = false then
    raise exception 'Esta comunicación no requiere confirmación del cliente';
  end if;

  update public.booking_communications
  set
    status = 'acknowledged'::public.communication_status,
    acknowledged_at = coalesce(acknowledged_at, now()),
    entry_context = p_entry_context,
    notes = case
      when p_notes is null or length(trim(p_notes)) = 0 then notes
      when notes is null or length(trim(notes)) = 0 then trim(p_notes)
      else notes || E'\n' || trim(p_notes)
    end,
    updated_by = auth.uid()
  where id = p_communication_id;

  return p_communication_id;
end;
$$;

revoke all on function public.acknowledge_booking_communication_v1(
  uuid,
  public.operational_entry_context,
  text
) from public, anon;

grant execute on function public.acknowledge_booking_communication_v1(
  uuid,
  public.operational_entry_context,
  text
) to authenticated;


-- =========================================================
-- 10. AUDITORÍA
-- =========================================================

drop trigger if exists trg_audit_booking_attendance
  on public.booking_attendance;

create trigger trg_audit_booking_attendance
after insert or update or delete on public.booking_attendance
for each row execute function public.write_audit_log();

drop trigger if exists trg_audit_booking_communications
  on public.booking_communications;

create trigger trg_audit_booking_communications
after insert or update or delete on public.booking_communications
for each row execute function public.write_audit_log();


-- =========================================================
-- 11. ROW LEVEL SECURITY
-- =========================================================

alter table public.booking_attendance enable row level security;
alter table public.booking_communications enable row level security;

-- Lectura operativa de asistencia.
drop policy if exists booking_attendance_operational_read
  on public.booking_attendance;

create policy booking_attendance_operational_read
on public.booking_attendance
for select
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager','guide']::public.app_role[]
  )
);

-- Lectura operativa de comunicaciones.
drop policy if exists booking_communications_operational_read
  on public.booking_communications;

create policy booking_communications_operational_read
on public.booking_communications
for select
to authenticated
using (
  public.current_user_has_role(
    array['owner','admin','manager','guide']::public.app_role[]
  )
);

-- Escritura directa no se concede mediante políticas.
-- Las modificaciones se realizan por las RPC anteriores para
-- conservar validaciones, permisos y auditoría.


-- =========================================================
-- 12. COMENTARIOS FINALES
-- =========================================================

comment on view public.departure_attendance_summary_v1 is
  'Resumen de asistencia por salida: pendientes, presentes, parciales y No-Show.';

comment on view public.pending_booking_acknowledgements_v1 is
  'Comunicaciones operativas que requieren OK del cliente y todavía no lo han recibido.';

commit;
