-- Upco InsurGest — NIP de 6 dígitos para el portal del cliente (validado en el SERVIDOR)
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- POR QUÉ ASÍ Y NO COMO HOMEY:
-- En Homey el NIP vive en localStorage y va ENCIMA de una sesión real de Supabase Auth: es una
-- cortina de privacidad sobre una puerta que ya tiene llave. Aquí no hay puerta debajo — la liga
-- ES la credencial —, así que un NIP local no serviría de nada: cualquiera con la liga entraría
-- desde otro dispositivo. Por eso el NIP se valida contra el servidor, con hash bcrypt, y la liga
-- deja de ser suficiente por sí sola.
--
-- Compatibilidad: portal_cliente cambia de firma, así que hay que DROP antes de recrear (si no,
-- quedan dos sobrecargas y PostgREST responde PGRST203 por ambigüedad). Los parámetros nuevos
-- llevan default null, así que el front viejo sigue funcionando hasta que se publique el nuevo —
-- y hoy ningún cliente tiene NIP, así que nadie se queda fuera en el intervalo.

create extension if not exists pgcrypto with schema extensions;

-- ============ COLUMNAS DEL NIP ============
alter table clientes add column nip_hash text;
alter table clientes add column nip_definido_en timestamptz;
alter table clientes add column nip_intentos int not null default 0;
alter table clientes add column nip_bloqueado_hasta timestamptz;

-- ============ DISPOSITIVOS RECORDADOS ============
-- Para no teclear el NIP en cada visita. El navegador guarda un token largo y aleatorio; aquí
-- solo vive su hash, igual que una contraseña. La huella/rostro del teléfono protege ese token
-- localmente — eso sí es exactamente el modelo de Homey, pero ahora sobre una credencial real.
create table portal_dispositivos (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid not null references clientes(id) on delete cascade,
  token_hash text not null unique,
  creado timestamptz not null default now(),
  ultimo_uso timestamptz,
  expira timestamptz not null
);
create index idx_portal_dispositivos_cliente on portal_dispositivos(cliente_id);
alter table portal_dispositivos enable row level security;
-- Sin políticas: solo las funciones SECURITY DEFINER de abajo la tocan.

-- ============ ESTADO DE LA LIGA (sin datos) ============
-- Lo único que se puede saber sin NIP: si la liga existe y si ya tiene NIP puesto. Nada más.
create or replace function public.portal_estado(p_token uuid) returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select id, nombre, nip_hash, nip_bloqueado_hasta into c
  from clientes where token_publico = p_token;

  if c.id is null then
    return json_build_object('existe', false);
  end if;

  return json_build_object(
    'existe', true,
    'nombre', split_part(c.nombre,' ',1),
    'tiene_nip', c.nip_hash is not null,
    'bloqueado_hasta', c.nip_bloqueado_hasta
  );
end;
$$;
revoke all on function public.portal_estado(uuid) from public;
grant execute on function public.portal_estado(uuid) to anon, authenticated;

-- ============ DEFINIR EL NIP (solo si todavía no tiene) ============
create or replace function public.portal_definir_nip(p_token uuid, p_nip text) returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id uuid;
  v_hash text;
begin
  select id, nip_hash into v_id, v_hash from clientes where token_publico = p_token;
  if v_id is null then
    raise exception 'Liga inválida';
  end if;
  -- Que no se pueda pisar el NIP de alguien con solo tener la liga: para cambiarlo hay que
  -- pedirle a su agente que lo restablezca.
  if v_hash is not null then
    raise exception 'Esta liga ya tiene un NIP. Si lo olvidaste, pídele a tu agente que lo restablezca.';
  end if;
  if p_nip !~ '^[0-9]{6}$' then
    raise exception 'El NIP debe ser de 6 dígitos';
  end if;

  update clientes set
    nip_hash = crypt(p_nip, gen_salt('bf', 8)),
    nip_definido_en = now(),
    nip_intentos = 0,
    nip_bloqueado_hasta = null
  where id = v_id;
end;
$$;
revoke all on function public.portal_definir_nip(uuid,text) from public;
grant execute on function public.portal_definir_nip(uuid,text) to anon, authenticated;

-- ============ RECORDAR ESTE DISPOSITIVO ============
create or replace function public.portal_recordar_dispositivo(p_token uuid, p_nip text) returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id uuid;
  v_hash text;
  v_token text;
begin
  select id, nip_hash into v_id, v_hash from clientes where token_publico = p_token;
  if v_id is null or v_hash is null or v_hash <> crypt(p_nip, v_hash) then
    raise exception 'NIP incorrecto';
  end if;

  v_token := encode(gen_random_bytes(32), 'hex');
  insert into portal_dispositivos(cliente_id, token_hash, expira)
  values (v_id, encode(digest(v_token,'sha256'),'hex'), now() + interval '30 days');

  return v_token;
end;
$$;
revoke all on function public.portal_recordar_dispositivo(uuid,text) from public;
grant execute on function public.portal_recordar_dispositivo(uuid,text) to anon, authenticated;

-- ============ ABRIR EL PORTAL ============
-- Acepta NIP o un dispositivo recordado. Si el cliente todavía no tiene NIP, deja pasar (para no
-- dejar afuera a quien ya tenía su liga antes de este cambio) — el front le pide crearlo.
drop function if exists public.portal_cliente(uuid);

create or replace function public.portal_cliente(
  p_token uuid,
  p_nip text default null,
  p_dispositivo text default null
) returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_ok boolean := false;
  resultado json;
begin
  select id, nip_hash, nip_intentos, nip_bloqueado_hasta into c
  from clientes where token_publico = p_token;

  if c.id is null then
    return null;
  end if;

  if c.nip_hash is null then
    v_ok := true;  -- todavía no lo configura; el front lo va a mandar a crearlo
  else
    if c.nip_bloqueado_hasta is not null and now() < c.nip_bloqueado_hasta then
      raise exception 'Demasiados intentos. Espera unos minutos e inténtalo de nuevo.';
    end if;

    -- dispositivo recordado
    if p_dispositivo is not null then
      update portal_dispositivos set ultimo_uso = now()
      where cliente_id = c.id
        and token_hash = encode(digest(p_dispositivo,'sha256'),'hex')
        and expira > now();
      if found then v_ok := true; end if;
    end if;

    -- NIP
    if not v_ok and p_nip is not null and c.nip_hash = crypt(p_nip, c.nip_hash) then
      v_ok := true;
    end if;

    if v_ok then
      update clientes set nip_intentos = 0, nip_bloqueado_hasta = null where id = c.id;
    else
      if p_nip is not null or p_dispositivo is not null then
        -- Sin esto, un NIP de 6 dígitos se agota por fuerza bruta en minutos.
        update clientes set
          nip_intentos = nip_intentos + 1,
          nip_bloqueado_hasta = case when nip_intentos + 1 >= 5 then now() + interval '15 minutes' else null end
        where id = c.id;
        raise exception 'NIP incorrecto';
      end if;
      raise exception 'Necesitas tu NIP';
    end if;
  end if;

  select json_build_object(
    'cliente', json_build_object(
      'nombre', c2.nombre,
      'tipo_persona', c2.tipo_persona,
      'tiene_nip', c2.nip_hash is not null
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
      from polizas p where p.cliente_id = c2.id
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
      where v.cliente_id = c2.id
    ), '[]'::json)
  ) into resultado
  from clientes c2
  join agentes a on a.id = c2.agente_id
  where c2.id = c.id;

  return resultado;
end;
$$;
revoke all on function public.portal_cliente(uuid,text,text) from public;
grant execute on function public.portal_cliente(uuid,text,text) to anon, authenticated;

-- ============ EL AGENTE RESTABLECE EL NIP DE SU CLIENTE ============
-- Es el "olvidé mi NIP": el agente lo borra y el cliente crea uno nuevo la próxima vez que entra.
-- Se le caen también los dispositivos recordados, por si el olvido fue porque perdió el teléfono.
create or replace function public.agente_resetear_nip(p_cliente_id uuid) returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not exists (select 1 from clientes where id = p_cliente_id and agente_id = auth.uid()) then
    raise exception 'No autorizado';
  end if;
  delete from portal_dispositivos where cliente_id = p_cliente_id;
  update clientes set nip_hash = null, nip_definido_en = null, nip_intentos = 0, nip_bloqueado_hasta = null
  where id = p_cliente_id;
end;
$$;
grant execute on function public.agente_resetear_nip(uuid) to authenticated;

-- Limpieza de dispositivos vencidos, una vez al día.
create or replace function public.limpiar_dispositivos_vencidos() returns void
language sql
security definer
set search_path = public
as $$
  delete from portal_dispositivos where expira < now();
$$;

select cron.schedule('limpiar-dispositivos', '30 3 * * *', $$select public.limpiar_dispositivos_vencidos();$$);
