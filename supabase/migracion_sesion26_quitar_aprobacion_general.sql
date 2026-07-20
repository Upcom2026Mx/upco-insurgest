-- Upco InsurGest — Quita la aprobación manual para agentes independientes; la deja solo para
-- confirmar la afiliación a una red de promotoría.
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- Contexto (decidido con el usuario): estatus_aprobacion nació para evitar que alguien usara el
-- sistema "sin pagar", pero desde la Sesión 14 la prueba de 30 días y el candado de Stripe ya
-- hacen ese trabajo (aprobado_en es lo que arranca el reloj de la prueba). Aprobar cada cuenta a
-- mano quedó redundante para agentes independientes. Donde SÍ sigue haciendo falta es para las
-- promotorías: vista_posicion_red decide quién cuenta entre los primeros 5 "gratis", y eso no se
-- le puede dejar a que cualquiera se autoafilie sin revisión — ahí seguiría el riesgo de que un
-- agente se aproveche del descuento de red.
--
-- Por eso se separan dos cosas que antes vivían en la misma columna:
--   estatus_aprobacion / aprobado_en  -> acceso general al producto. Ahora se aprueba solo,
--                                        de una vez, al registrarse.
--   red_aprobada_en (nueva)           -> confirmación de la afiliación a una promotoría. Sigue
--                                        requiriendo que el fundador o la promotoría la confirmen.

-- ============ ACCESO GENERAL: aprobado de una vez al registrarse ============
alter table agentes alter column estatus_aprobacion set default 'aprobado';
alter table agentes alter column aprobado_en set default now();

-- a quien ya estuviera pendiente (no debería haber agentes reales en ese estado, pero por si acaso)
-- se le aprueba de una vez, igual que se hizo la primera vez que se introdujo este candado
update agentes set estatus_aprobacion = 'aprobado', aprobado_en = coalesce(aprobado_en, now())
where estatus_aprobacion = 'pendiente';

-- ============ RED: nueva columna, separada del acceso general ============
alter table agentes add column red_aprobada_en timestamptz;

-- a los agentes de red que YA estaban aprobados bajo el sistema viejo se les respeta su posición
-- actual — no hay que pedirles que se vuelvan a confirmar solo por este cambio de mecanismo
update agentes set red_aprobada_en = aprobado_en
where promotoria_id is not null and estatus_aprobacion = 'aprobado' and red_aprobada_en is null;

-- ============ vista_posicion_red ahora usa la confirmación de red, no el acceso general ============
create or replace view public.vista_posicion_red as
select
  a.id,
  a.promotoria_id,
  row_number() over (partition by a.promotoria_id order by a.red_aprobada_en nulls last, a.id) as posicion
from agentes a
where a.promotoria_id is not null and a.red_aprobada_en is not null;

revoke all on public.vista_posicion_red from public, anon, authenticated;

-- ============ Confirmar la afiliación a la red — desde /admin ============
create or replace function public.admin_aprobar_red(p_agente_id uuid) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then
    raise exception 'No autorizado';
  end if;
  update agentes set red_aprobada_en = coalesce(red_aprobada_en, now()) where id = p_agente_id;
end;
$$;
grant execute on function public.admin_aprobar_red(uuid) to authenticated;

-- ============ Confirmar la afiliación a la red — desde /promotor (ya no toca estatus_aprobacion,
-- una promotoría no debe poder aprobar/rechazar la cuenta general de nadie, solo su posición en
-- su propia red) ============
create or replace function public.promotoria_aprobar_agente(p_agente_id uuid) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_promotoria() then
    raise exception 'No autorizado';
  end if;
  update agentes set red_aprobada_en = coalesce(red_aprobada_en, now())
  where id = p_agente_id and promotoria_id = auth.uid();
end;
$$;

-- ============ admin_agentes() / promotoria_agentes(): exponer red_aprobada_en ============
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
        (select count(*) from polizas p join clientes c on c.id = p.cliente_id where c.agente_id = a.id) as polizas
      from agentes a
      left join promotorias pr on pr.id = a.promotoria_id
      left join public.vista_posicion_red v on v.id = a.id
    ) t
  ), '[]'::json);
end;
$$;

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
        (select count(*) from polizas p join clientes c on c.id = p.cliente_id where c.agente_id = a.id) as polizas
      from agentes a
      left join public.vista_posicion_red v on v.id = a.id
      where a.promotoria_id = auth.uid()
    ) t
  ), '[]'::json);
end;
$$;

-- ============ promotoria_resumen(): mismo cambio para el dashboard de /promotor ============
create or replace function public.promotoria_resumen() returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_promotoria() then
    raise exception 'No autorizado';
  end if;
  return json_build_object(
    'agentes_totales', (select count(*) from agentes where promotoria_id = auth.uid()),
    'agentes_red_pendiente', (select count(*) from agentes where promotoria_id = auth.uid() and red_aprobada_en is null),
    'agentes_aprobados', (select count(*) from agentes where promotoria_id = auth.uid() and red_aprobada_en is not null),
    'clientes_totales', (select count(*) from clientes c join agentes a on a.id = c.agente_id where a.promotoria_id = auth.uid()),
    'polizas_totales', (select count(*) from polizas p join clientes c on c.id = p.cliente_id join agentes a on a.id = c.agente_id where a.promotoria_id = auth.uid())
  );
end;
$$;

-- ============ admin_resumen(): el conteo útil ahora es "afiliaciones de red sin confirmar",
-- no "cuentas sin aprobar" (que ya no debería acumularse con el nuevo default) ============
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
    'agentes_red_pendiente', (select count(*) from agentes where promotoria_id is not null and red_aprobada_en is null),
    'promotorias_totales', (select count(*) from promotorias),
    'promotorias_pendientes', (select count(*) from promotorias where estatus_aprobacion = 'pendiente'),
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
