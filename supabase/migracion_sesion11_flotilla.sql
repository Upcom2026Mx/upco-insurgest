-- Upco InsurGest — Flotilla del cliente (autogestionada) + catálogo de verificación vehicular por estado
-- Pegar completo en Supabase > SQL Editor > New query > Run

-- ============ CATÁLOGO DE VERIFICACIÓN VEHICULAR POR ESTADO ============
-- Editable a mano — estos programas cambian por estado y por año, no confiar en que quede fijo para siempre.
create table estados_verificacion (
  estado text primary key,
  requiere_verificacion boolean not null default false,
  notas text
);

insert into estados_verificacion (estado, requiere_verificacion, notas) values
('Aguascalientes', true, null),
('Baja California', false, null),
('Baja California Sur', false, null),
('Campeche', false, null),
('Chiapas', false, null),
('Chihuahua', false, null),
('Ciudad de México', true, 'Programa obligatorio (CAMe)'),
('Coahuila', false, null),
('Colima', false, null),
('Durango', false, null),
('Estado de México', true, 'Programa obligatorio, PVVO (CAMe)'),
('Guanajuato', true, null),
('Guerrero', false, null),
('Hidalgo', true, 'CAMe'),
('Jalisco', true, null),
('Michoacán', true, 'CAMe'),
('Morelos', true, 'CAMe'),
('Nayarit', false, null),
('Nuevo León', false, 'Sin programa obligatorio confirmado — verificar vigencia local'),
('Oaxaca', true, 'CAMe'),
('Puebla', true, 'CAMe'),
('Querétaro', true, null),
('Quintana Roo', false, null),
('San Luis Potosí', false, null),
('Sinaloa', false, null),
('Sonora', false, null),
('Tabasco', false, null),
('Tamaulipas', false, null),
('Tlaxcala', true, 'CAMe'),
('Veracruz', false, null),
('Yucatán', false, null),
('Zacatecas', false, null);

-- Catálogo público de solo lectura (sin datos sensibles) — lo puede leer cualquiera, incluido el portal sin sesión
alter table estados_verificacion enable row level security;
create policy "cualquiera puede leer el catálogo" on estados_verificacion
  for select using (true);

-- ============ FLOTILLA DEL CLIENTE ============
create table flotilla_vehiculos (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid not null references clientes(id) on delete cascade,
  poliza_id uuid references polizas(id) on delete set null,
  placas text,
  estado text,
  marca text,
  modelo text,
  anio int,
  kilometraje_actual int,
  fecha_registro_km date,
  intervalo_mantenimiento_km int not null default 10000 check (intervalo_mantenimiento_km in (10000,15000)),
  fecha_ultimo_servicio date,
  km_ultimo_servicio int,
  fecha_verificacion date,
  notificaciones_activas boolean not null default false,
  created_at timestamptz not null default now()
);

-- Sin RLS abierta: el portal no tiene sesión, todo el acceso pasa por las funciones portal_flotilla_* de abajo
alter table flotilla_vehiculos enable row level security;

-- Máximo 5 vehículos por cliente en su flotilla (mismo límite que ya existe en vehiculos del agente)
create or replace function public.limite_flotilla_por_cliente() returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (select count(*) from flotilla_vehiculos where cliente_id = new.cliente_id) >= 5 then
    raise exception 'Ya tienes el máximo de 5 vehículos en tu flotilla';
  end if;
  return new;
end;
$$;

create trigger limite_flotilla before insert on flotilla_vehiculos
  for each row execute function public.limite_flotilla_por_cliente();

-- ============ LISTAR FLOTILLA + PÓLIZAS DE AUTO DISPONIBLES PARA VINCULAR ============
create or replace function public.portal_flotilla_listar(p_token uuid) returns json
language plpgsql
security definer
set search_path = public
as $$
declare v_cliente_id uuid;
begin
  select id into v_cliente_id from clientes where token_publico = p_token;
  if v_cliente_id is null then return null; end if;

  return json_build_object(
    'flotilla', coalesce((
      select json_agg(t order by t.created_at) from (
        select
          f.id, f.placas, f.estado, f.marca, f.modelo, f.anio,
          f.kilometraje_actual, f.fecha_registro_km, f.intervalo_mantenimiento_km,
          f.fecha_ultimo_servicio, f.km_ultimo_servicio, f.fecha_verificacion, f.notificaciones_activas,
          f.poliza_id, f.created_at,
          coalesce(ev.requiere_verificacion, false) as requiere_verificacion
        from flotilla_vehiculos f
        left join estados_verificacion ev on ev.estado = f.estado
        where f.cliente_id = v_cliente_id
      ) t
    ), '[]'::json),
    'polizas_auto', coalesce((
      select json_agg(json_build_object('id', p.id, 'numero_poliza', p.numero_poliza, 'aseguradora', p.aseguradora))
      from polizas p where p.cliente_id = v_cliente_id and p.ramo = 'Auto'
    ), '[]'::json)
  );
end;
$$;
grant execute on function public.portal_flotilla_listar(uuid) to anon;

-- ============ AGREGAR VEHÍCULO A LA FLOTILLA ============
create or replace function public.portal_flotilla_agregar(
  p_token uuid, p_placas text, p_estado text, p_marca text, p_modelo text, p_anio int,
  p_kilometraje int, p_intervalo int, p_poliza_id uuid
) returns json
language plpgsql
security definer
set search_path = public
as $$
declare v_cliente_id uuid; v_nuevo record;
begin
  select id into v_cliente_id from clientes where token_publico = p_token;
  if v_cliente_id is null then raise exception 'Liga inválida'; end if;
  if p_poliza_id is not null and not exists(select 1 from polizas where id = p_poliza_id and cliente_id = v_cliente_id) then
    raise exception 'Póliza inválida';
  end if;

  insert into flotilla_vehiculos (cliente_id, placas, estado, marca, modelo, anio, kilometraje_actual, fecha_registro_km, intervalo_mantenimiento_km, poliza_id)
  values (v_cliente_id, nullif(trim(p_placas),''), nullif(p_estado,''), nullif(trim(p_marca),''), nullif(trim(p_modelo),''), p_anio,
    p_kilometraje, case when p_kilometraje is not null then current_date end, coalesce(p_intervalo,10000), p_poliza_id)
  returning * into v_nuevo;

  return row_to_json(v_nuevo);
end;
$$;
grant execute on function public.portal_flotilla_agregar(uuid,text,text,text,text,int,int,int,uuid) to anon;

-- ============ ACTUALIZAR KILOMETRAJE / SERVICIO / NOTIFICACIONES ============
create or replace function public.portal_flotilla_actualizar(
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

  update flotilla_vehiculos set
    kilometraje_actual = coalesce(p_kilometraje, kilometraje_actual),
    fecha_registro_km = case when p_kilometraje is not null then current_date else fecha_registro_km end,
    fecha_ultimo_servicio = coalesce(p_fecha_ultimo_servicio, fecha_ultimo_servicio),
    km_ultimo_servicio = coalesce(p_km_ultimo_servicio, km_ultimo_servicio),
    fecha_verificacion = coalesce(p_fecha_verificacion, fecha_verificacion),
    notificaciones_activas = coalesce(p_notificaciones_activas, notificaciones_activas)
  where id = p_vehiculo_id and cliente_id = v_cliente_id;
end;
$$;
grant execute on function public.portal_flotilla_actualizar(uuid,uuid,int,date,int,date,boolean) to anon;

-- ============ ELIMINAR VEHÍCULO DE LA FLOTILLA ============
create or replace function public.portal_flotilla_eliminar(p_token uuid, p_vehiculo_id uuid) returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_cliente_id uuid;
begin
  select id into v_cliente_id from clientes where token_publico = p_token;
  if v_cliente_id is null then raise exception 'Liga inválida'; end if;
  delete from flotilla_vehiculos where id = p_vehiculo_id and cliente_id = v_cliente_id;
end;
$$;
grant execute on function public.portal_flotilla_eliminar(uuid,uuid) to anon;

-- ============ SOLICITAR COTIZACIÓN PARA UN VEHÍCULO DE LA FLOTILLA SIN PÓLIZA ============
create or replace function public.portal_flotilla_cotizar(p_token uuid, p_vehiculo_id uuid) returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_cliente_id uuid; v_veh record;
begin
  select id into v_cliente_id from clientes where token_publico = p_token;
  if v_cliente_id is null then raise exception 'Liga inválida'; end if;

  select * into v_veh from flotilla_vehiculos where id = p_vehiculo_id and cliente_id = v_cliente_id;
  if v_veh is null then raise exception 'Vehículo inválido'; end if;

  insert into solicitudes (cliente_id, tipo, ramo_interes, descripcion)
  values (v_cliente_id, 'cotizacion', 'Auto',
    'Cotización para vehículo de su flotilla: ' || coalesce(v_veh.marca,'') || ' ' || coalesce(v_veh.modelo,'') || ' ' || coalesce(v_veh.anio::text,'') ||
    case when v_veh.placas is not null then ' — placas ' || v_veh.placas else '' end);
end;
$$;
grant execute on function public.portal_flotilla_cotizar(uuid,uuid) to anon;
