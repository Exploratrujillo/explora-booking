-- Explora Booking
-- Corrección Arquitectura v1
-- Migración J.1: auditoría de promotion_experiences
-- Fecha: 2026-08-08
--
-- promotion_experiences usa clave primaria compuesta
-- (promotion_id, experience_id) y no dispone de columna id.
-- write_audit_log() presupone NEW.id / OLD.id, por lo que el trigger
-- genérico creado en 20260808190000 es incompatible con esta tabla.
--
-- La relación sigue representada por las tablas auditadas promotions
-- y booking_promotions. Esta corrección elimina únicamente el trigger
-- incompatible; no modifica datos ni el modelo funcional.

begin;

drop trigger if exists trg_audit_promotion_experiences
  on public.promotion_experiences;

comment on table public.promotion_experiences is
  'Relación entre promociones y experiencias. Usa clave primaria compuesta; no emplea el trigger genérico write_audit_log(), que requiere una columna id.';

commit;
