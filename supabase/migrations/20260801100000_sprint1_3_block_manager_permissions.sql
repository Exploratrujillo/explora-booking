-- Explora Booking
-- Sprint 1.3 - Parte 1B
-- Corrección segura de permisos del Gestor de Bloques
-- Archivo: 20260801100000_sprint1_3_block_manager_permissions.sql

begin;

-- La primera versión de get_schedule_blocks se ejecutaba como SECURITY INVOKER.
-- La vista schedule_block_manager usa security_invoker=true, por lo que Supabase
-- exigía al usuario autenticado permisos directos sobre schedules y tablas relacionadas.
--
-- El backoffice no debe acceder directamente a esas tablas. La lectura se realiza
-- mediante esta RPC SECURITY DEFINER, limitada a usuarios internos autorizados.

create or replace function public.get_schedule_blocks(
  p_status public.schedule_status default null,
  p_experience_id uuid default null,
  p_include_archived boolean default false
)
returns setof public.schedule_block_manager
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.current_user_has_role(
    array['owner','admin','manager']::public.app_role[]
  ) then
    raise exception 'No autorizado para consultar bloques de planificación';
  end if;

  return query
  select b.*
  from public.schedule_block_manager b
  where (p_status is null or b.status = p_status)
    and (p_experience_id is null or b.experience_id = p_experience_id)
    and (
      p_include_archived
      or b.status <> 'archived'::public.schedule_status
    )
  order by
    case b.status
      when 'active'::public.schedule_status then 1
      when 'draft'::public.schedule_status then 2
      when 'paused'::public.schedule_status then 3
      else 4
    end,
    b.valid_from desc,
    b.block_name;
end;
$$;

revoke all on function public.get_schedule_blocks(
  public.schedule_status,
  uuid,
  boolean
) from public, anon;

grant execute on function public.get_schedule_blocks(
  public.schedule_status,
  uuid,
  boolean
) to authenticated;

-- El acceso normal del backoffice debe hacerse mediante la RPC anterior.
-- Eliminamos el acceso directo concedido anteriormente a la vista.
revoke select on public.schedule_block_manager from authenticated;

comment on function public.get_schedule_blocks(
  public.schedule_status,
  uuid,
  boolean
) is
  'Lista los bloques de planificación para usuarios internos autorizados sin conceder acceso directo a las tablas operativas.';

commit;
