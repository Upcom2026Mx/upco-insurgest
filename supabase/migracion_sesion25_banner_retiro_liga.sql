-- Upco InsurGest — portal_cliente ahora incluye el alias del agente (solo si su tarjeta está
-- activa), para poder enlazar al cotizador de retiro público (/r/{alias}) desde la liga mágica
-- del cliente. Mismo patrón que el resto: null si no aplica, el front decide si muestra el banner.
-- Pegar completo en Supabase > SQL Editor > New query > Run

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
    v_ok := true;
  else
    if c.nip_bloqueado_hasta is not null and now() < c.nip_bloqueado_hasta then
      raise exception 'Demasiados intentos. Espera unos minutos e inténtalo de nuevo.';
    end if;

    if p_dispositivo is not null then
      update portal_dispositivos set ultimo_uso = now()
      where cliente_id = c.id
        and token_hash = encode(digest(p_dispositivo,'sha256'),'hex')
        and expira > now();
      if found then v_ok := true; end if;
    end if;

    if not v_ok and p_nip is not null and c.nip_hash = crypt(p_nip, c.nip_hash) then
      v_ok := true;
    end if;

    if v_ok then
      update clientes set nip_intentos = 0, nip_bloqueado_hasta = null where id = c.id;
    else
      if p_nip is not null or p_dispositivo is not null then
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
      'telefono', a.telefono,
      'alias_retiro', case when a.tarjeta_activa then a.alias_publico else null end
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
