-- Upco InsurGest — El cliente también se entera de que su póliza vence, y los avisos dejan de repetirse a diario
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- Dos cambios de fondo:
--
-- 1) BUG: no había control de repetición. La condición era "vence en los próximos 15 días" y el
--    cron corre a diario, así que el mismo correo salía 15 días seguidos. Eso entrena a la gente
--    para ignorar los avisos, que es justo lo contrario de lo que queremos. Ahora cada póliza /
--    vehículo se marca cuando se avisa y no se vuelve a avisar hasta 7 días después (o sea, ~2 o 3
--    avisos en toda la ventana: al inicio, a media y cerca del final).
--
-- 2) La póliza por vencer ahora también se le avisa al CLIENTE (correo + push), no solo al agente.
--    En la Sesión 7 se había decidido que solo al agente porque él gestiona la renovación; el dueño
--    corrigió el criterio: al cliente le sirve saberlo y le da motivo para buscar a su agente.

-- ============ MARCAS DE "YA AVISÉ" ============
alter table polizas add column aviso_agente_en timestamptz;
alter table polizas add column aviso_cliente_en timestamptz;
alter table vehiculos add column verificacion_avisada_en timestamptz;

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

  -- ---- 1) pólizas por vencer -> AGENTE (gestiona la renovación) ----
  for r in
    select a.id as agente_id, a.correo as agente_correo, a.nombre as agente_nombre
    from agentes a
    where a.correo is not null
      and exists (
        select 1 from polizas p join clientes c on c.id = p.cliente_id
        where c.agente_id = a.id
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
    where c.agente_id = r.agente_id
      and p.fecha_fin between current_date and current_date + 15
      and p.estatus not in ('renovada','cancelada')
      and (p.aviso_agente_en is null or p.aviso_agente_en < now() - interval '7 days');

    v_html := format(
      '<p>Hola %s,</p><h2>Pólizas por vencer en los próximos 15 días</h2>'
      '<table border="1" cellpadding="6" style="border-collapse:collapse">'
      '<tr><th>Cliente</th><th>Ramo</th><th>Aseguradora</th><th>Número</th><th>Vence</th></tr>%s</table>',
      coalesce(r.agente_nombre,'agente'), v_filas
    );

    perform net.http_post(
      url := 'https://api.resend.com/emails',
      headers := jsonb_build_object('Authorization','Bearer '||v_key,'Content-Type','application/json'),
      body := jsonb_build_object(
        'from','Upco InsurGest <notificaciones@upco.app>',
        'to', jsonb_build_array(r.agente_correo),
        'subject','Tienes pólizas por vencer en los próximos 15 días',
        'html', v_html
      )
    );

    update polizas p set aviso_agente_en = now()
    from clientes c
    where c.id = p.cliente_id
      and c.agente_id = r.agente_id
      and p.fecha_fin between current_date and current_date + 15
      and p.estatus not in ('renovada','cancelada')
      and (p.aviso_agente_en is null or p.aviso_agente_en < now() - interval '7 days');
  end loop;

  -- ---- 2) pólizas por vencer -> CLIENTE (correo + push) ----
  for r in
    select c.id as cliente_id, c.correo as cliente_correo, c.nombre as cliente_nombre,
           c.token_publico as token, a.nombre as agente_nombre, a.telefono as agente_telefono
    from clientes c join agentes a on a.id = c.agente_id
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
      '<p>Tu agente %s ya está enterado y te va a buscar para renovarla. Si quieres adelantarte, '
      'escríbele%s o entra a tu liga para pedirle el cambio.</p>',
      split_part(r.cliente_nombre,' ',1), v_filas,
      coalesce(r.agente_nombre,'de Upco InsurGest'),
      case when r.agente_telefono is not null then ' al '||r.agente_telefono else '' end
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

  -- ---- 3) verificación vehicular por vencer -> CLIENTE (trámite que le toca a él) ----
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

  -- ---- 4) mantenimiento de flotilla próximo -> CLIENTE (correo + push) ----
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
end;
$$;
