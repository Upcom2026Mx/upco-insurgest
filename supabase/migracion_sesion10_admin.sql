-- Upco InsurGest — Panel de administración del fundador + registro de agentes con aprobación
-- Pegar completo en Supabase > SQL Editor > New query > Run

-- ============ ESTATUS DE APROBACIÓN ============
alter table agentes add column estatus_aprobacion text not null default 'pendiente'
  check (estatus_aprobacion in ('pendiente','aprobado','rechazado'));

-- las cuentas que ya existen (las de prueba y cualquier otra ya creada a mano) quedan aprobadas
-- de una vez, para no bloquearlas retroactivamente
update agentes set estatus_aprobacion = 'aprobado';

-- ============ CANDADO DE ADMINISTRADOR ============
-- único correo autorizado para usar el panel de administración (mismo patrón que Homey)
create or replace function public.es_admin() returns boolean
language sql stable
security definer
set search_path = public
as $$
  select coalesce((auth.jwt()->>'email') = 'springradio190@gmail.com', false);
$$;

-- ============ RESUMEN GLOBAL DE LA PLATAFORMA ============
create or replace function public.admin_resumen() returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then
    raise exception 'No autorizado';
  end if;
  return json_build_object(
    'agentes_totales', (select count(*) from agentes),
    'agentes_pendientes', (select count(*) from agentes where estatus_aprobacion = 'pendiente'),
    'agentes_aprobados', (select count(*) from agentes where estatus_aprobacion = 'aprobado'),
    'clientes_totales', (select count(*) from clientes),
    'polizas_totales', (select count(*) from polizas),
    'prima_total_vigente', (
      select coalesce(sum(prima),0) from polizas
      where estatus not in ('renovada','cancelada')
        and (fecha_fin is null or fecha_fin >= current_date)
    )
  );
end;
$$;

-- ============ LISTA DE AGENTES CON SUS MÉTRICAS ============
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
        a.created_at as creado,
        (select count(*) from clientes c where c.agente_id = a.id) as clientes,
        (select count(*) from polizas p join clientes c on c.id = p.cliente_id where c.agente_id = a.id) as polizas
      from agentes a
    ) t
  ), '[]'::json);
end;
$$;

-- ============ APROBAR / RECHAZAR AGENTE ============
create or replace function public.admin_aprobar_agente(p_agente_id uuid) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then
    raise exception 'No autorizado';
  end if;
  update agentes set estatus_aprobacion = 'aprobado' where id = p_agente_id;
end;
$$;

create or replace function public.admin_rechazar_agente(p_agente_id uuid) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then
    raise exception 'No autorizado';
  end if;
  update agentes set estatus_aprobacion = 'rechazado' where id = p_agente_id;
end;
$$;

grant execute on function public.es_admin() to authenticated;
grant execute on function public.admin_resumen() to authenticated;
grant execute on function public.admin_agentes() to authenticated;
grant execute on function public.admin_aprobar_agente(uuid) to authenticated;
grant execute on function public.admin_rechazar_agente(uuid) to authenticated;
