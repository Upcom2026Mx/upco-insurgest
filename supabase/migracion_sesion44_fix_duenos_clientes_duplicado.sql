-- Upco InsurGest — Sesion 44: corrige duplicados de duenos_clientes cuando una misma cuenta
-- tiene fila en agentes Y en promotorias a la vez
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- Bug real encontrado probando la Sesion 43: /app, /promotor y /maestra comparten sesion (mismo
-- dominio) — visitar un portal estando logueado en otro ya crea una fila ahi tambien (documentado
-- desde la Sesion 10). Hoy existen 3 cuentas reales así: agente-prueba-a, agente-prueba-b y el
-- correo del fundador. La vista duenos_clientes (UNION ALL de agentes+promotorias) generaba DOS
-- filas con el mismo id para esas cuentas, y cualquier JOIN/EXISTS contra duenos_clientes por id
-- las contaba dos veces — en revisar_vencimientos() eso significa correos de aviso DUPLICADOS.
--
-- Arreglo: todo join/exists contra duenos_clientes ahora también compara la columna `tipo`,
-- calculada a partir de si la fila de clientes tiene agente_id o promotoria_id — así solo hace
-- match con la fila correcta de la vista, nunca con las dos.

create or replace function public.portal_cliente(p_token uuid, p_nip text default null, p_dispositivo text default null) returns json
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
      'alias_retiro', case when a.tipo = 'agente' and a.tarjeta_activa then a.alias_publico else null end
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
  join duenos_clientes a on a.id = coalesce(c2.agente_id, c2.promotoria_id)
    and a.tipo = case when c2.agente_id is not null then 'agente' else 'promotoria' end
  where c2.id = c.id;

  return resultado;
end;
$$;

create or replace function public.notificar_nueva_solicitud() returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text;
  v_dueno_correo text;
  v_dueno_nombre text;
  v_de text;
  v_detalle text;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'resend_api_key';
  if v_key is null then return new; end if;

  select d.correo, coalesce(d.nombre, d.nombre_negocio) into v_dueno_correo, v_dueno_nombre
  from duenos_clientes d
  where d.id = coalesce(new.agente_id, new.promotoria_id)
    and d.tipo = case when new.agente_id is not null then 'agente' else 'promotoria' end;

  if v_dueno_correo is null then return new; end if;

  if new.cliente_id is not null then
    select nombre into v_de from clientes where id = new.cliente_id;
  else
    v_de := new.prospecto_nombre || ' (prospecto de tu tarjeta)';
  end if;

  v_detalle := case when new.tipo = 'endoso' then coalesce(new.tipo_cambio,'Cambio a su póliza')
                     else coalesce(new.ramo_interes,'Cotización') end;

  perform net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization','Bearer '||v_key,'Content-Type','application/json'),
    body := jsonb_build_object(
      'from','Upco InsurGest <notificaciones@upco.app>',
      'to', jsonb_build_array(v_dueno_correo),
      'subject', case when new.cliente_id is null then 'Nuevo prospecto desde tu tarjeta'
                      when new.tipo = 'endoso' then 'Nueva solicitud de endoso'
                      else 'Nueva solicitud de cotización' end,
      'html', format('<p>Hola %s,</p><p><strong>%s</strong> te mandó una solicitud: <strong>%s</strong>.</p><p>%s</p><p>%s</p><p>Entra a tu panel de InsurGest para verla completa.</p>',
        coalesce(v_dueno_nombre,'agente'), v_de, v_detalle, coalesce(new.descripcion,''),
        case when new.cliente_id is null then
          coalesce('Contacto: '||coalesce(new.prospecto_correo,'')||' '||coalesce(new.prospecto_telefono,''),'')
        else '' end)
    )
  );
  return new;
end;
$$;

create or replace function public.revisar_vencimientos() returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text;
  v_push_secret text;
  r record;
  v_filas text;
  v_html text;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'resend_api_key';
  if v_key is null then
    raise notice 'Falta configurar el secreto resend_api_key en Vault';
    return;
  end if;
  select decrypted_secret into v_push_secret from vault.decrypted_secrets where name = 'push_internal_secret';

  -- ---- 1) pólizas por vencer -> DUEÑO (agente o promotoría, gestiona la renovación) ----
  for r in
    select d.id as dueno_id, d.correo as dueno_correo, coalesce(d.nombre, d.nombre_negocio) as dueno_nombre, d.tipo as dueno_tipo
    from duenos_clientes d
    where d.correo is not null
      and exists (
        select 1 from polizas p join clientes c on c.id = p.cliente_id
        where coalesce(c.agente_id, c.promotoria_id) = d.id
          and (case when c.agente_id is not null then 'agente' else 'promotoria' end) = d.tipo
          and p.fecha_fin between current_date and current_date + 15
          and p.estatus not in ('renovada','cancelada')
          and (p.aviso_agente_en is null or p.aviso_agente_en < now() - interval '7 days')
      )
  loop
    select coalesce(string_agg(
      format('<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>',
        c.nombre, p.ramo, coalesce(p.aseguradora,'—'), coalesce(p.numero_poliza,'—'), to_char(p.fecha_fin,'DD Mon YYYY')),
      ''), '') into v_filas
    from polizas p join clientes c on c.id = p.cliente_id
    where coalesce(c.agente_id, c.promotoria_id) = r.dueno_id
      and (case when c.agente_id is not null then 'agente' else 'promotoria' end) = r.dueno_tipo
      and p.fecha_fin between current_date and current_date + 15
      and p.estatus not in ('renovada','cancelada')
      and (p.aviso_agente_en is null or p.aviso_agente_en < now() - interval '7 days');

    v_html := format(
      '<p>Hola %s,</p><h2>Pólizas por vencer en los próximos 15 días</h2>'
      '<table border="1" cellpadding="6" style="border-collapse:collapse">'
      '<tr><th>Cliente</th><th>Ramo</th><th>Aseguradora</th><th>Número</th><th>Vence</th></tr>%s</table>',
      coalesce(r.dueno_nombre,'agente'), v_filas
    );

    perform net.http_post(
      url := 'https://api.resend.com/emails',
      headers := jsonb_build_object('Authorization','Bearer '||v_key,'Content-Type','application/json'),
      body := jsonb_build_object(
        'from','Upco InsurGest <notificaciones@upco.app>',
        'to', jsonb_build_array(r.dueno_correo),
        'subject','Tienes pólizas por vencer en los próximos 15 días',
        'html', v_html
      )
    );

    update polizas p set aviso_agente_en = now()
    from clientes c
    where c.id = p.cliente_id
      and coalesce(c.agente_id, c.promotoria_id) = r.dueno_id
      and (case when c.agente_id is not null then 'agente' else 'promotoria' end) = r.dueno_tipo
      and p.fecha_fin between current_date and current_date + 15
      and p.estatus not in ('renovada','cancelada')
      and (p.aviso_agente_en is null or p.aviso_agente_en < now() - interval '7 days');
  end loop;

  -- ---- 2) pólizas por vencer -> CLIENTE (correo + push) ----
  for r in
    select c.id as cliente_id, c.correo as cliente_correo, c.nombre as cliente_nombre,
           c.token_publico as token, d.nombre as dueno_nombre, d.nombre_negocio as dueno_negocio, d.telefono as dueno_telefono
    from clientes c
    join duenos_clientes d on d.id = coalesce(c.agente_id, c.promotoria_id)
      and d.tipo = case when c.agente_id is not null then 'agente' else 'promotoria' end
    where c.correo is not null
      and exists (
        select 1 from polizas p
        where p.cliente_id = c.id
          and p.fecha_fin between current_date and current_date + 15
          and p.estatus not in ('renovada','cancelada')
          and (p.aviso_cliente_en is null or p.aviso_cliente_en < now() - interval '7 days')
      )
  loop
    select coalesce(string_agg(
      format('<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>',
        p.ramo, coalesce(p.aseguradora,'—'), coalesce(p.numero_poliza,'—'), to_char(p.fecha_fin,'DD Mon YYYY')),
      ''), '') into v_filas
    from polizas p
    where p.cliente_id = r.cliente_id
      and p.fecha_fin between current_date and current_date + 15
      and p.estatus not in ('renovada','cancelada')
      and (p.aviso_cliente_en is null or p.aviso_cliente_en < now() - interval '7 days');

    v_html := format(
      '<p>Hola %s,</p><h2>Tu seguro está por vencer</h2>'
      '<table border="1" cellpadding="6" style="border-collapse:collapse">'
      '<tr><th>Ramo</th><th>Aseguradora</th><th>Número</th><th>Vence</th></tr>%s</table>'
      '<p>Tu asesor %s ya está enterado y te va a buscar para renovarla. Si quieres adelantarte, '
      'escríbele%s o entra a tu liga para pedirle el cambio.</p>',
      split_part(r.cliente_nombre,' ',1), v_filas,
      coalesce(r.dueno_nombre, r.dueno_negocio, 'de Upco InsurGest'),
      case when r.dueno_telefono is not null then ' al '||r.dueno_telefono else '' end
    );

    perform net.http_post(
      url := 'https://api.resend.com/emails',
      headers := jsonb_build_object('Authorization','Bearer '||v_key,'Content-Type','application/json'),
      body := jsonb_build_object(
        'from','Upco InsurGest <notificaciones@upco.app>',
        'to', jsonb_build_array(r.cliente_correo),
        'subject','Tu seguro está por vencer',
        'html', v_html
      )
    );

    if v_push_secret is not null then
      perform net.http_post(
        url := 'https://pxcvckqahkjlizgotvqw.supabase.co/functions/v1/send-push',
        headers := jsonb_build_object(
          'Content-Type','application/json',
          'Authorization','Bearer sb_publishable_F2WhknXrY8MLjI5ftd0H6w_-XXjej6I',
          'x-internal-secret', v_push_secret
        ),
        body := jsonb_build_object(
          'cliente_id', r.cliente_id,
          'title','Tu seguro está por vencer',
          'body','Entra para verlo o pídele la renovación a tu agente.',
          'url','https://insurgest.upco.app/p/'||r.token
        )
      );
    end if;

    update polizas set aviso_cliente_en = now()
    where cliente_id = r.cliente_id
      and fecha_fin between current_date and current_date + 15
      and estatus not in ('renovada','cancelada')
      and (aviso_cliente_en is null or aviso_cliente_en < now() - interval '7 days');
  end loop;

  -- ---- 3) verificación vehicular por vencer -> CLIENTE (no cambia: no toca dueños) ----
  for r in
    select c.id as cliente_id, c.correo as cliente_correo, c.nombre as cliente_nombre
    from clientes c
    where c.correo is not null
      and exists (
        select 1 from vehiculos v
        where v.cliente_id = c.id
          and v.fecha_verificacion between current_date and current_date + 15
          and (v.verificacion_avisada_en is null or v.verificacion_avisada_en < now() - interval '7 days')
      )
  loop
    select coalesce(string_agg(
      format('<tr><td>%s</td><td>%s</td><td>%s</td></tr>',
        coalesce(v.placas,'—'), trim(coalesce(v.marca,'')||' '||coalesce(v.modelo,'')), to_char(v.fecha_verificacion,'DD Mon YYYY')),
      ''), '') into v_filas
    from vehiculos v
    where v.cliente_id = r.cliente_id
      and v.fecha_verificacion between current_date and current_date + 15
      and (v.verificacion_avisada_en is null or v.verificacion_avisada_en < now() - interval '7 days');

    v_html := format(
      '<p>Hola %s,</p><h2>Tu verificación vehicular está por vencer</h2>'
      '<table border="1" cellpadding="6" style="border-collapse:collapse">'
      '<tr><th>Placas</th><th>Vehículo</th><th>Vence</th></tr>%s</table>',
      split_part(r.cliente_nombre,' ',1), v_filas
    );

    perform net.http_post(
      url := 'https://api.resend.com/emails',
      headers := jsonb_build_object('Authorization','Bearer '||v_key,'Content-Type','application/json'),
      body := jsonb_build_object(
        'from','Upco InsurGest <notificaciones@upco.app>',
        'to', jsonb_build_array(r.cliente_correo),
        'subject','Tu verificación vehicular está por vencer',
        'html', v_html
      )
    );

    update vehiculos set verificacion_avisada_en = now()
    where cliente_id = r.cliente_id
      and fecha_verificacion between current_date and current_date + 15
      and (verificacion_avisada_en is null or verificacion_avisada_en < now() - interval '7 days');
  end loop;

  -- ---- 4) mantenimiento de flotilla próximo -> CLIENTE (no cambia: no toca dueños) ----
  for r in
    select c.id as cliente_id, c.correo as cliente_correo, c.nombre as cliente_nombre, c.token_publico as token
    from clientes c
    where c.correo is not null
      and exists (
        select 1 from vehiculos v
        where v.cliente_id = c.id
          and v.notificaciones_activas = true
          and v.kilometraje_actual is not null
          and v.km_ultimo_servicio is not null
          and (v.km_ultimo_servicio + v.intervalo_mantenimiento_km - v.kilometraje_actual) <= 500
          and (v.mantenimiento_avisado_en is null or v.mantenimiento_avisado_en < now() - interval '14 days')
      )
  loop
    select coalesce(string_agg(
      format('<tr><td>%s</td><td>%s</td><td>%s km</td></tr>',
        coalesce(v.placas,'—'), trim(coalesce(v.marca,'')||' '||coalesce(v.modelo,'')),
        to_char(v.km_ultimo_servicio + v.intervalo_mantenimiento_km, 'FM999,999,999')),
      ''), '') into v_filas
    from vehiculos v
    where v.cliente_id = r.cliente_id
      and v.notificaciones_activas = true
      and v.kilometraje_actual is not null
      and v.km_ultimo_servicio is not null
      and (v.km_ultimo_servicio + v.intervalo_mantenimiento_km - v.kilometraje_actual) <= 500
      and (v.mantenimiento_avisado_en is null or v.mantenimiento_avisado_en < now() - interval '14 days');

    v_html := format(
      '<p>Hola %s,</p><h2>Se acerca el mantenimiento de tu vehículo</h2>'
      '<p>Según el último kilometraje que registraste, ya casi te toca servicio:</p>'
      '<table border="1" cellpadding="6" style="border-collapse:collapse">'
      '<tr><th>Placas</th><th>Vehículo</th><th>Servicio estimado a los</th></tr>%s</table>'
      '<p>Entra a tu liga con tu agente para actualizar tu kilometraje o marcar el servicio como hecho.</p>',
      split_part(r.cliente_nombre,' ',1), v_filas
    );

    perform net.http_post(
      url := 'https://api.resend.com/emails',
      headers := jsonb_build_object('Authorization','Bearer '||v_key,'Content-Type','application/json'),
      body := jsonb_build_object(
        'from','Upco InsurGest <notificaciones@upco.app>',
        'to', jsonb_build_array(r.cliente_correo),
        'subject','Se acerca el mantenimiento de tu vehículo',
        'html', v_html
      )
    );

    if v_push_secret is not null then
      perform net.http_post(
        url := 'https://pxcvckqahkjlizgotvqw.supabase.co/functions/v1/send-push',
        headers := jsonb_build_object(
          'Content-Type','application/json',
          'Authorization','Bearer sb_publishable_F2WhknXrY8MLjI5ftd0H6w_-XXjej6I',
          'x-internal-secret', v_push_secret
        ),
        body := jsonb_build_object(
          'cliente_id', r.cliente_id,
          'title','Se acerca el mantenimiento de tu vehículo',
          'body','Actualiza tu kilometraje o marca el servicio como hecho.',
          'url','https://insurgest.upco.app/p/'||r.token
        )
      );
    end if;

    update vehiculos set mantenimiento_avisado_en = now()
    where cliente_id = r.cliente_id
      and notificaciones_activas = true
      and kilometraje_actual is not null
      and km_ultimo_servicio is not null
      and (km_ultimo_servicio + intervalo_mantenimiento_km - kilometraje_actual) <= 500
      and (mantenimiento_avisado_en is null or mantenimiento_avisado_en < now() - interval '14 days');
  end loop;

  -- ---- 5) cumpleaños de HOY -> DUEÑO (agente o promotoría) ----
  for r in
    select d.id as dueno_id, d.correo as dueno_correo, coalesce(d.nombre, d.nombre_negocio) as dueno_nombre, d.tipo as dueno_tipo
    from duenos_clientes d
    where d.correo is not null
      and exists (
        select 1 from clientes c
        where coalesce(c.agente_id, c.promotoria_id) = d.id
          and (case when c.agente_id is not null then 'agente' else 'promotoria' end) = d.tipo
          and c.fecha_nacimiento is not null
          and extract(month from c.fecha_nacimiento) = extract(month from current_date)
          and extract(day from c.fecha_nacimiento) = extract(day from current_date)
      )
  loop
    select coalesce(string_agg(format('<li>%s</li>', c.nombre), ''), '') into v_filas
    from clientes c
    where coalesce(c.agente_id, c.promotoria_id) = r.dueno_id
      and (case when c.agente_id is not null then 'agente' else 'promotoria' end) = r.dueno_tipo
      and c.fecha_nacimiento is not null
      and extract(month from c.fecha_nacimiento) = extract(month from current_date)
      and extract(day from c.fecha_nacimiento) = extract(day from current_date);

    v_html := format(
      '<p>Hola %s,</p><h2>🎂 Hoy cumplen años:</h2><ul>%s</ul>'
      '<p>Es un buen momento para escribirles y felicitarlos.</p>',
      coalesce(r.dueno_nombre,'agente'), v_filas
    );

    perform net.http_post(
      url := 'https://api.resend.com/emails',
      headers := jsonb_build_object('Authorization','Bearer '||v_key,'Content-Type','application/json'),
      body := jsonb_build_object(
        'from','Upco InsurGest <notificaciones@upco.app>',
        'to', jsonb_build_array(r.dueno_correo),
        'subject','🎂 Hoy es el cumpleaños de tu cliente',
        'html', v_html
      )
    );
  end loop;
end;
$$;
