-- Upco InsurGest — Unifica "mi flotilla" con los vehículos que ya carga el agente
-- (deshace la tabla separada flotilla_vehiculos de la migración anterior)
-- Pegar completo en Supabase > SQL Editor > New query > Run

-- ============ DESHACER LA TABLA SEPARADA ============
drop function if exists public.portal_flotilla_cotizar(uuid,uuid);
drop function if exists public.portal_flotilla_eliminar(uuid,uuid);
drop function if exists public.portal_flotilla_actualizar(uuid,uuid,int,date,int,date,boolean);
drop function if exists public.portal_flotilla_agregar(uuid,text,text,text,text,int,int,int,uuid);
drop function if exists public.portal_flotilla_listar(uuid);
drop table if exists flotilla_vehiculos;

-- ============ CAMPOS DE MANTENIMIENTO EN LA TABLA vehiculos QUE YA EXISTE ============
alter table vehiculos add column kilometraje_actual int;
alter table vehiculos add column fecha_registro_km date;
alter table vehiculos add column intervalo_mantenimiento_km int not null default 10000 check (intervalo_mantenimiento_km in (10000,15000));
alter table vehiculos add column fecha_ultimo_servicio date;
alter table vehiculos add column km_ultimo_servicio int;
alter table vehiculos add column notificaciones_activas boolean not null default false;

-- ============ portal_cliente() AHORA INCLUYE LOS CAMPOS NUEVOS ============
create or replace function public.portal_cliente(p_token uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  resultado json;
begin
  select json_build_object(
    'cliente', json_build_object(
      'nombre', c.nombre,
      'tipo_persona', c.tipo_persona
    ),
    'agente', json_build_object(
      'nombre', a.nombre,
      'nombre_negocio', a.nombre_negocio,
      'correo', a.correo,
      'telefono', a.telefono
    ),
    'polizas', coalesce((
      select json_agg(json_build_object(
        'id', p.id,
        'ramo', p.ramo,
        'aseguradora', p.aseguradora,
        'numero_poliza', p.numero_poliza,
        'fecha_inicio', p.fecha_inicio,
        'fecha_fin', p.fecha_fin,
        'estatus', p.estatus,
        'prima', p.prima,
        'forma_pago', p.forma_pago,
        'pdf_url', p.pdf_url,
        'vehiculo_id', p.vehiculo_id
      ) order by p.fecha_fin desc nulls last)
      from polizas p where p.cliente_id = c.id
    ), '[]'::json),
    'vehiculos', coalesce((
      select json_agg(json_build_object(
        'id', v.id,
        'placas', v.placas,
        'estado', v.estado,
        'marca', v.marca,
        'modelo', v.modelo,
        'anio', v.anio,
        'tipo_vehiculo', v.tipo_vehiculo,
        'fecha_verificacion', v.fecha_verificacion,
        'kilometraje_actual', v.kilometraje_actual,
        'fecha_registro_km', v.fecha_registro_km,
        'intervalo_mantenimiento_km', v.intervalo_mantenimiento_km,
        'fecha_ultimo_servicio', v.fecha_ultimo_servicio,
        'km_ultimo_servicio', v.km_ultimo_servicio,
        'notificaciones_activas', v.notificaciones_activas,
        'requiere_verificacion', coalesce(ev.requiere_verificacion, false),
        'tiene_poliza', exists(select 1 from polizas p2 where p2.vehiculo_id = v.id)
      ))
      from vehiculos v
      left join estados_verificacion ev on ev.estado = v.estado
      where v.cliente_id = c.id
    ), '[]'::json)
  ) into resultado
  from clientes c
  join agentes a on a.id = c.agente_id
  where c.token_publico = p_token;

  return resultado;
end;
$$;

-- ============ AGREGAR VEHÍCULO DESDE EL PORTAL (sin póliza todavía) ============
create or replace function public.portal_vehiculo_agregar(
  p_token uuid, p_placas text, p_estado text, p_marca text, p_modelo text, p_anio int,
  p_kilometraje int, p_intervalo int
) returns json
language plpgsql
security definer
set search_path = public
as $$
declare v_cliente_id uuid; v_nuevo record;
begin
  select id into v_cliente_id from clientes where token_publico = p_token;
  if v_cliente_id is null then raise exception 'Liga inválida'; end if;

  insert into vehiculos (cliente_id, placas, estado, marca, modelo, anio, tipo_vehiculo, kilometraje_actual, fecha_registro_km, intervalo_mantenimiento_km)
  values (v_cliente_id, nullif(trim(p_placas),''), nullif(p_estado,''), nullif(trim(p_marca),''), nullif(trim(p_modelo),''), p_anio, 'familiar',
    p_kilometraje, case when p_kilometraje is not null then current_date end, coalesce(p_intervalo,10000))
  returning * into v_nuevo;

  return row_to_json(v_nuevo);
end;
$$;
grant execute on function public.portal_vehiculo_agregar(uuid,text,text,text,text,int,int,int) to anon;

-- ============ ACTUALIZAR KILOMETRAJE / SERVICIO / VERIFICACIÓN / NOTIFICACIONES ============
create or replace function public.portal_vehiculo_actualizar(
  p_token uuid, p_vehiculo_id uuid, p_kilometraje int, p_fecha_ultimo_servicio date,
  p_km_ultimo_servicio int, p_fecha_verificacion date, p_notificaciones_activas boolean
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_cliente_id uuid;
begin
  select id into v_cliente_id from clientes where token_publico = p_token;
  if v_cliente_id is null then raise exception 'Liga inválida'; end if;

  update vehiculos set
    kilometraje_actual = coalesce(p_kilometraje, kilometraje_actual),
    fecha_registro_km = case when p_kilometraje is not null then current_date else fecha_registro_km end,
    fecha_ultimo_servicio = coalesce(p_fecha_ultimo_servicio, fecha_ultimo_servicio),
    km_ultimo_servicio = coalesce(p_km_ultimo_servicio, km_ultimo_servicio),
    fecha_verificacion = coalesce(p_fecha_verificacion, fecha_verificacion),
    notificaciones_activas = coalesce(p_notificaciones_activas, notificaciones_activas)
  where id = p_vehiculo_id and cliente_id = v_cliente_id;
end;
$$;
grant execute on function public.portal_vehiculo_actualizar(uuid,uuid,int,date,int,date,boolean) to anon;

-- ============ ACTIVAR NOTIFICACIONES PARA TODOS SUS VEHÍCULOS (botón del encabezado) ============
create or replace function public.portal_activar_notificaciones(p_token uuid) returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_cliente_id uuid;
begin
  select id into v_cliente_id from clientes where token_publico = p_token;
  if v_cliente_id is null then raise exception 'Liga inválida'; end if;
  update vehiculos set notificaciones_activas = true where cliente_id = v_cliente_id;
end;
$$;
grant execute on function public.portal_activar_notificaciones(uuid) to anon;

-- ============ ELIMINAR VEHÍCULO (solo si el cliente lo agregó y no tiene póliza) ============
create or replace function public.portal_vehiculo_eliminar(p_token uuid, p_vehiculo_id uuid) returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_cliente_id uuid;
begin
  select id into v_cliente_id from clientes where token_publico = p_token;
  if v_cliente_id is null then raise exception 'Liga inválida'; end if;
  if exists(select 1 from polizas where vehiculo_id = p_vehiculo_id) then
    raise exception 'Este vehículo ya tiene una póliza — pídele a tu agente que lo actualice.';
  end if;
  delete from vehiculos where id = p_vehiculo_id and cliente_id = v_cliente_id;
end;
$$;
grant execute on function public.portal_vehiculo_eliminar(uuid,uuid) to anon;

-- ============ SOLICITAR COTIZACIÓN PARA UN VEHÍCULO SIN PÓLIZA ============
create or replace function public.portal_vehiculo_cotizar(p_token uuid, p_vehiculo_id uuid) returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_cliente_id uuid; v_veh record;
begin
  select id into v_cliente_id from clientes where token_publico = p_token;
  if v_cliente_id is null then raise exception 'Liga inválida'; end if;

  select * into v_veh from vehiculos where id = p_vehiculo_id and cliente_id = v_cliente_id;
  if v_veh is null then raise exception 'Vehículo inválido'; end if;

  insert into solicitudes (cliente_id, tipo, ramo_interes, descripcion)
  values (v_cliente_id, 'cotizacion', 'Auto',
    'Cotización para vehículo: ' || coalesce(v_veh.marca,'') || ' ' || coalesce(v_veh.modelo,'') || ' ' || coalesce(v_veh.anio::text,'') ||
    case when v_veh.placas is not null then ' — placas ' || v_veh.placas else '' end);
end;
$$;
grant execute on function public.portal_vehiculo_cotizar(uuid,uuid) to anon;
