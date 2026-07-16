-- Upco InsurGest — El panel del fundador ahora ve la fecha del próximo cobro de cada cuenta.
-- Pegar completo en Supabase > SQL Editor > New query > Run
-- Único cambio: agregar suscripcion_vigente_hasta a lo que devuelven las dos funciones.

create or replace function public.admin_agentes() returns json
language plpgsql
security definer
set search_path = public
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
set search_path = public
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
        p.created_at as creado,
        (select count(*) from agentes a where a.promotoria_id = p.id) as agentes
      from promotorias p
    ) t
  ), '[]'::json);
end;
$$;
