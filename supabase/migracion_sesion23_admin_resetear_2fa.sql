-- Upco InsurGest — El fundador restablece el 2FA de un agente con un clic
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- POR QUÉ:
-- Los códigos de respaldo de la Sesión 22 solo sirven si el agente los guardó, y en la vida real
-- casi nadie lo hace. Sin un botón aquí, cada agente que pierda su teléfono se convierte en una
-- visita a la base de datos — o sea, en soporte manual que no escala a 200 agentes.
--
-- El fundador ya puede leer y borrar todo de estas cuentas: esto no le da poder nuevo, solo le
-- evita entrar a mano a la base para hacer lo mismo.

create or replace function public.admin_resetear_2fa(p_user_id uuid) returns void
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if not public.es_admin() then
    raise exception 'No autorizado';
  end if;
  -- Que exista como agente o como promotoría: no queremos un botón que borre el 2FA de
  -- cualquier usuario de auth por su uuid.
  if not exists (select 1 from agentes where id = p_user_id)
     and not exists (select 1 from promotorias where id = p_user_id) then
    raise exception 'Esa cuenta no es un agente ni una promotoría';
  end if;

  delete from auth.mfa_factors where user_id = p_user_id;
  delete from mfa_codigos_respaldo where user_id = p_user_id;
end;
$$;
grant execute on function public.admin_resetear_2fa(uuid) to authenticated;

-- ============ QUE EL PANEL MUESTRE QUIÉN TIENE 2FA ============
create or replace function public.admin_agentes() returns json
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if not public.es_admin() then
    raise exception 'No autorizado';
  end if;
  return coalesce((
    select json_agg(t order by t.creado desc) from (
      select
        a.id, a.nombre, a.correo, a.telefono, a.nombre_negocio, a.estatus_aprobacion,
        a.rfc, a.tiene_cedula, a.tipos_cedula, a.numero_cedula,
        a.acepto_terminos, a.acepto_terminos_version, a.acepto_terminos_fecha,
        a.estatus_suscripcion, a.plan_periodo, a.acceso_extendido_hasta, a.aprobado_en,
        a.suscripcion_vigente_hasta,
        exists (select 1 from auth.mfa_factors f where f.user_id = a.id and f.status = 'verified') as tiene_2fa,
        a.created_at as creado,
        (select count(*) from clientes c where c.agente_id = a.id) as clientes,
        (select count(*) from polizas p join clientes c on c.id = p.cliente_id where c.agente_id = a.id) as polizas
      from agentes a
    ) t
  ), '[]'::json);
end;
$$;

create or replace function public.admin_promotorias() returns json
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if not public.es_admin() then
    raise exception 'No autorizado';
  end if;
  return coalesce((
    select json_agg(t order by t.creado desc) from (
      select
        p.id, p.nombre, p.correo, p.nombre_negocio, p.rfc, p.codigo_invitacion, p.estatus_aprobacion,
        p.estatus_suscripcion, p.plan_periodo, p.acceso_extendido_hasta, p.aprobado_en,
        p.suscripcion_vigente_hasta,
        exists (select 1 from auth.mfa_factors f where f.user_id = p.id and f.status = 'verified') as tiene_2fa,
        p.created_at as creado,
        (select count(*) from agentes a where a.promotoria_id = p.id) as agentes
      from promotorias p
    ) t
  ), '[]'::json);
end;
$$;
