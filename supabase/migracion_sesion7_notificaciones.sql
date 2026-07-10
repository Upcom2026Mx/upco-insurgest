-- Upco InsurGest — Sesión 7: notificaciones automáticas por correo
-- Requiere que ya hayas guardado la llave de Resend en Vault:
--   select vault.create_secret('TU_LLAVE', 'resend_api_key');
-- Pegar completo en Supabase > SQL Editor > New query > Run

-- ============ A) REVISIÓN DIARIA DE VENCIMIENTOS ============
-- Pólizas por vencer -> aviso al AGENTE (necesita gestionar la renovación).
-- Verificación vehicular por vencer -> aviso al CLIENTE (trámite que le toca a él).
create or replace function public.revisar_vencimientos() returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text;
  r record;
  v_filas text;
  v_html text;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'resend_api_key';
  if v_key is null then
    raise notice 'Falta configurar el secreto resend_api_key en Vault';
    return;
  end if;

  -- ---- pólizas por vencer -> agente ----
  for r in
    select a.id as agente_id, a.correo as agente_correo, a.nombre as agente_nombre
    from agentes a
    where a.correo is not null
      and exists (
        select 1 from polizas p join clientes c on c.id = p.cliente_id
        where c.agente_id = a.id
          and p.fecha_fin between current_date and current_date + 15
          and p.estatus not in ('renovada','cancelada')
      )
  loop
    select coalesce(string_agg(
      format('<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>',
        c.nombre, p.ramo, coalesce(p.aseguradora,'—'), coalesce(p.numero_poliza,'—'), to_char(p.fecha_fin,'DD Mon YYYY')),
      ''), '') into v_filas
    from polizas p join clientes c on c.id = p.cliente_id
    where c.agente_id = r.agente_id
      and p.fecha_fin between current_date and current_date + 15
      and p.estatus not in ('renovada','cancelada');

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
  end loop;

  -- ---- verificación vehicular por vencer -> cliente ----
  for r in
    select c.id as cliente_id, c.correo as cliente_correo, c.nombre as cliente_nombre
    from clientes c
    where c.correo is not null
      and exists (
        select 1 from vehiculos v
        where v.cliente_id = c.id
          and v.fecha_verificacion between current_date and current_date + 15
      )
  loop
    select coalesce(string_agg(
      format('<tr><td>%s</td><td>%s</td><td>%s</td></tr>',
        coalesce(v.placas,'—'), trim(coalesce(v.marca,'')||' '||coalesce(v.modelo,'')), to_char(v.fecha_verificacion,'DD Mon YYYY')),
      ''), '') into v_filas
    from vehiculos v
    where v.cliente_id = r.cliente_id
      and v.fecha_verificacion between current_date and current_date + 15;

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
  end loop;
end;
$$;

-- corre todos los días a las 08:00 hora de Ciudad de México (14:00 UTC, sin horario de verano)
select cron.schedule('insurgest-revisar-vencimientos','0 14 * * *', $$select public.revisar_vencimientos();$$);

-- ============ B) AVISO INMEDIATO DE SOLICITUD NUEVA ============
-- Cierra el pendiente de la Sesión 6: además de aparecer en la bandeja del agente,
-- ahora también le llega un correo en cuanto el cliente manda un endoso o cotización.
create or replace function public.notificar_nueva_solicitud() returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text;
  v_agente_correo text;
  v_agente_nombre text;
  v_cliente_nombre text;
  v_detalle text;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'resend_api_key';
  if v_key is null then return new; end if;

  select a.correo, a.nombre, c.nombre
    into v_agente_correo, v_agente_nombre, v_cliente_nombre
  from clientes c join agentes a on a.id = c.agente_id
  where c.id = new.cliente_id;

  if v_agente_correo is null then return new; end if;

  v_detalle := case when new.tipo = 'endoso' then coalesce(new.tipo_cambio,'Cambio a su póliza')
                     else coalesce(new.ramo_interes,'Cotización') end;

  perform net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization','Bearer '||v_key,'Content-Type','application/json'),
    body := jsonb_build_object(
      'from','Upco InsurGest <notificaciones@upco.app>',
      'to', jsonb_build_array(v_agente_correo),
      'subject', case when new.tipo = 'endoso' then 'Nueva solicitud de endoso' else 'Nueva solicitud de cotización' end,
      'html', format('<p>Hola %s,</p><p><strong>%s</strong> te mandó una solicitud: <strong>%s</strong>.</p><p>%s</p><p>Entra a tu panel de InsurGest para verla completa.</p>',
        coalesce(v_agente_nombre,'agente'), v_cliente_nombre, v_detalle, coalesce(new.descripcion,''))
    )
  );
  return new;
end;
$$;

create trigger trg_notificar_solicitud
after insert on solicitudes
for each row execute function notificar_nueva_solicitud();
