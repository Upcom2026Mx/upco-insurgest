-- Upco InsurGest — Sesión 30: prima vigente por agente, visible en /promotor y /admin
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- promotoria_agentes() y admin_agentes() ya mostraban "X clientes · Y pólizas" por agente, pero
-- no el dinero (prima) que trae cada uno — que es a lo que de verdad se refiere "producción" en
-- el gremio. Misma regla de "vigente" que ya usa admin_resumen() para prima_total_vigente: no
-- cuenta si el estatus es renovada/cancelada, ni si ya venció.

create or replace function public.promotoria_agentes() returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_promotoria() then
    raise exception 'No autorizado';
  end if;
  return coalesce((
    select json_agg(t order by t.creado desc) from (
      select
        a.id, a.nombre, a.correo, a.telefono, a.nombre_negocio, a.estatus_aprobacion,
        a.red_aprobada_en,
        a.created_at as creado,
        v.posicion,
        (select count(*) from clientes c where c.agente_id = a.id) as clientes,
        (select count(*) from polizas p join clientes c on c.id = p.cliente_id where c.agente_id = a.id) as polizas,
        (select coalesce(sum(p.prima),0) from polizas p join clientes c on c.id = p.cliente_id
         where c.agente_id = a.id
           and p.estatus not in ('renovada','cancelada')
           and (p.fecha_fin is null or p.fecha_fin >= current_date)
        ) as prima_total
      from agentes a
      left join public.vista_posicion_red v on v.id = a.id
      where a.promotoria_id = auth.uid()
    ) t
  ), '[]'::json);
end;
$$;

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
        a.red_aprobada_en,
        a.suscripcion_vigente_hasta,
        exists (select 1 from auth.mfa_factors f where f.user_id = a.id and f.status = 'verified') as tiene_2fa,
        pr.nombre_negocio as promotoria_nombre, v.posicion as posicion_red,
        a.created_at as creado,
        (select count(*) from clientes c where c.agente_id = a.id) as clientes,
        (select count(*) from polizas p join clientes c on c.id = p.cliente_id where c.agente_id = a.id) as polizas,
        (select coalesce(sum(p.prima),0) from polizas p join clientes c on c.id = p.cliente_id
         where c.agente_id = a.id
           and p.estatus not in ('renovada','cancelada')
           and (p.fecha_fin is null or p.fecha_fin >= current_date)
        ) as prima_total
      from agentes a
      left join promotorias pr on pr.id = a.promotoria_id
      left join public.vista_posicion_red v on v.id = a.id
    ) t
  ), '[]'::json);
end;
$$;
