-- Upco InsurGest — Afiliación de agentes existentes a una promotoría + arreglo del candado de acceso
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- Cierra el bug encontrado: la página de precios promete "5 agentes incluidos" en el plan de
-- promotoría, pero (a) un agente ya registrado no tenía dónde meter el código de una promotoría,
-- y (b) accesoVigente() nunca revisaba promotoria_id, así que un agente de red se topaba con el
-- muro de $299 a los 30 días exactamente igual que uno independiente.
--
-- Modelo confirmado: los primeros 5 agentes aprobados de una promotoría (por orden de aprobación)
-- entran GRATIS mientras la promotoría tenga su propia suscripción vigente. El agente 6+ paga
-- $249/mes por su cuenta — eso se sigue facturando manual, como ya se decidió.

-- ============ VISTA: posición de cada agente dentro de su red ============
-- Un solo lugar que calcula "quién es de los primeros 5", para no repetir esta lógica en 3 partes
-- y que se desincronicen entre sí.
create or replace view public.vista_posicion_red as
select
  a.id,
  a.promotoria_id,
  row_number() over (partition by a.promotoria_id order by a.aprobado_en nulls last, a.id) as posicion
from agentes a
where a.promotoria_id is not null and a.estatus_aprobacion = 'aprobado';

-- No se expone directo por la API — solo la usan las funciones de abajo, que ya corren con
-- privilegios elevados. Sin esto, PostgREST la publicaría como endpoint público de lectura.
revoke all on public.vista_posicion_red from public, anon, authenticated;

-- ============ AFILIACIÓN: agente ya existente mete el código de su promotoría ============
create or replace function public.agente_afiliar_promotoria(p_codigo text) returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ya uuid;
  v_promotoria_id uuid;
begin
  if auth.uid() is null then
    raise exception 'No autorizado';
  end if;

  select promotoria_id into v_ya from agentes where id = auth.uid();
  if v_ya is not null then
    raise exception 'Ya perteneces a una red. Si necesitas cambiarla, escríbenos.';
  end if;

  v_promotoria_id := resolver_codigo_promotoria(p_codigo);
  if v_promotoria_id is null then
    raise exception 'Ese código no es válido';
  end if;

  update agentes set promotoria_id = v_promotoria_id where id = auth.uid();
  return json_build_object('ok', true);
end;
$$;
grant execute on function public.agente_afiliar_promotoria(text) to authenticated;

-- ============ CANDADO: ¿este agente entra gratis por su red? ============
create or replace function public.agente_estado_red() returns json
language sql
stable
security definer
set search_path = public
as $$
  select json_build_object(
    'en_red', a.promotoria_id is not null,
    'posicion', v.posicion,
    'acceso_gratis', coalesce(
      v.posicion <= 5
      and exists (
        select 1 from promotorias p
        where p.id = a.promotoria_id
          and (
            p.estatus_suscripcion in ('active','trialing')
            or (p.acceso_extendido_hasta is not null and p.acceso_extendido_hasta >= now())
            or (p.aprobado_en is not null and now() <= p.aprobado_en + interval '30 days')
          )
      ), false
    ),
    'promotoria_nombre', pr.nombre_negocio
  )
  from agentes a
  left join public.vista_posicion_red v on v.id = a.id
  left join promotorias pr on pr.id = a.promotoria_id
  where a.id = auth.uid();
$$;
grant execute on function public.agente_estado_red() to authenticated;

-- ============ /promotor: mostrar la posición de cada agente en la lista ============
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
        a.created_at as creado,
        v.posicion,
        (select count(*) from clientes c where c.agente_id = a.id) as clientes,
        (select count(*) from polizas p join clientes c on c.id = p.cliente_id where c.agente_id = a.id) as polizas
      from agentes a
      left join public.vista_posicion_red v on v.id = a.id
      where a.promotoria_id = auth.uid()
    ) t
  ), '[]'::json);
end;
$$;

-- ============ /admin: ver también en qué red está cada agente ============
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
        pr.nombre_negocio as promotoria_nombre, v.posicion as posicion_red,
        a.created_at as creado,
        (select count(*) from clientes c where c.agente_id = a.id) as clientes,
        (select count(*) from polizas p join clientes c on c.id = p.cliente_id where c.agente_id = a.id) as polizas
      from agentes a
      left join promotorias pr on pr.id = a.promotoria_id
      left join public.vista_posicion_red v on v.id = a.id
    ) t
  ), '[]'::json);
end;
$$;
