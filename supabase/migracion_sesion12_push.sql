-- Upco InsurGest — Notificaciones push reales
-- Antes de correr esto, guarda 3 secretos en Supabase > Database > Vault > New secret,
-- con estos nombres exactos (los valores te los pasé aparte en el chat, nunca van en este
-- archivo ni en el repo — son secretos reales, no de ejemplo):
--   vapid_public_key
--   vapid_private_key
--   push_internal_secret
-- Pegar completo en Supabase > SQL Editor > New query > Run

-- ============ SUSCRIPCIONES PUSH ============
create table push_subscripciones (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid not null references clientes(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now()
);
alter table push_subscripciones enable row level security;
create index idx_push_subscripciones_cliente on push_subscripciones(cliente_id);

create or replace function public.portal_suscribir_push(p_token uuid, p_endpoint text, p_p256dh text, p_auth text) returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_cliente_id uuid;
begin
  select id into v_cliente_id from clientes where token_publico = p_token;
  if v_cliente_id is null then raise exception 'Liga inválida'; end if;

  insert into push_subscripciones (cliente_id, endpoint, p256dh, auth)
  values (v_cliente_id, p_endpoint, p_p256dh, p_auth)
  on conflict (endpoint) do update set cliente_id = excluded.cliente_id, p256dh = excluded.p256dh, auth = excluded.auth;
end;
$$;
grant execute on function public.portal_suscribir_push(uuid,text,text,text) to anon;

-- ============ AGREGAR ENVÍO DE PUSH AL AVISO DE MANTENIMIENTO ============
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
  v_token uuid;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'resend_api_key';
  select decrypted_secret into v_push_secret from vault.decrypted_secrets where name = 'push_internal_secret';
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

  -- ---- mantenimiento de flotilla próximo -> cliente (correo + push) ----
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
      and (km_ultimo_servicio + intervalo_mantenimiento_km - kilometraje_actual) <= 500;
  end loop;
end;
$$;
