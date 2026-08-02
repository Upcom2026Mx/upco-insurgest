-- Upco InsurGest — Sesion 43: cartera propia de promotoria (fase 2 del roadmap acordado:
-- import -> cartera propia de promotoria -> siniestros)
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- Motivo de negocio (dado por el usuario, no derivable del codigo): hay polizas que se emiten
-- con la clave de la PROMOTORIA ante la aseguradora, no con la del agente, aunque el agente sea
-- quien atiende al cliente. Eso significa que la promotoria necesita poder dar de alta y
-- administrar sus propios clientes/polizas/vehiculos directo, igual que ya puede un agente.
--
-- Diseño: clientes.agente_id pasa a nullable y se agrega clientes.promotoria_id (tambien
-- nullable) — un cliente le pertenece a EXACTAMENTE UNO de los dos, nunca a ambos ni a ninguno.
-- Se generaliza con el mismo patron: solicitudes tambien gana promotoria_id (para que la liga
-- magica de un cliente de promotoria pueda pedir cambios/cotizaciones igual que la de un agente).
--
-- Vista duenos_clientes: en vez de duplicar cada funcion que hoy asume "el dueño es un agente"
-- (revisar_vencimientos, portal_cliente, notificar_nueva_solicitud), se unifica agentes+promotorias
-- en una sola vista y las funciones hacen JOIN contra coalesce(agente_id, promotoria_id) = duenos.id.
-- Menos codigo duplicado, menos riesgo de que un caso se actualice y el otro se le olvide.

-- ============ VISTA UNIFICADA: quien puede ser dueño de una cartera ============
create or replace view public.duenos_clientes as
select id, correo, nombre, nombre_negocio, telefono, alias_publico, tarjeta_activa, 'agente'::text as tipo
from agentes
union all
select id, correo, nombre, nombre_negocio, null::text as telefono, alias_publico, tarjeta_activa, 'promotoria'::text as tipo
from promotorias;

revoke all on public.duenos_clientes from public, anon, authenticated;

-- ============ CLIENTES: agente_id nullable + promotoria_id ============
alter table clientes add column promotoria_id uuid references promotorias(id) on delete cascade;
alter table clientes alter column agente_id drop not null;
alter table clientes add constraint clientes_dueno_check check (
  (agente_id is not null and promotoria_id is null) or (agente_id is null and promotoria_id is not null)
);
create index idx_clientes_promotoria on clientes(promotoria_id);

drop policy "agente ve sus clientes" on clientes;
drop policy "agente crea sus clientes" on clientes;
drop policy "agente edita sus clientes" on clientes;
drop policy "agente elimina sus clientes" on clientes;

create policy "dueño ve sus clientes" on clientes for select using (agente_id = auth.uid() or promotoria_id = auth.uid());
create policy "dueño crea sus clientes" on clientes for insert with check (agente_id = auth.uid() or promotoria_id = auth.uid());
create policy "dueño edita sus clientes" on clientes for update using (agente_id = auth.uid() or promotoria_id = auth.uid());
create policy "dueño elimina sus clientes" on clientes for delete using (agente_id = auth.uid() or promotoria_id = auth.uid());

-- ============ VEHICULOS y POLIZAS: RLS via clientes, ahora dueño-agnostica ============
drop policy "agente ve vehiculos de sus clientes" on vehiculos;
drop policy "agente crea vehiculos de sus clientes" on vehiculos;
drop policy "agente edita vehiculos de sus clientes" on vehiculos;
drop policy "agente elimina vehiculos de sus clientes" on vehiculos;

create policy "dueño ve vehiculos de sus clientes" on vehiculos for select using (
  exists(select 1 from clientes c where c.id = vehiculos.cliente_id and (c.agente_id = auth.uid() or c.promotoria_id = auth.uid())));
create policy "dueño crea vehiculos de sus clientes" on vehiculos for insert with check (
  exists(select 1 from clientes c where c.id = vehiculos.cliente_id and (c.agente_id = auth.uid() or c.promotoria_id = auth.uid())));
create policy "dueño edita vehiculos de sus clientes" on vehiculos for update using (
  exists(select 1 from clientes c where c.id = vehiculos.cliente_id and (c.agente_id = auth.uid() or c.promotoria_id = auth.uid())));
create policy "dueño elimina vehiculos de sus clientes" on vehiculos for delete using (
  exists(select 1 from clientes c where c.id = vehiculos.cliente_id and (c.agente_id = auth.uid() or c.promotoria_id = auth.uid())));

drop policy "agente ve polizas de sus clientes" on polizas;
drop policy "agente crea polizas de sus clientes" on polizas;
drop policy "agente edita polizas de sus clientes" on polizas;
drop policy "agente elimina polizas de sus clientes" on polizas;

create policy "dueño ve polizas de sus clientes" on polizas for select using (
  exists(select 1 from clientes c where c.id = polizas.cliente_id and (c.agente_id = auth.uid() or c.promotoria_id = auth.uid())));
create policy "dueño crea polizas de sus clientes" on polizas for insert with check (
  exists(select 1 from clientes c where c.id = polizas.cliente_id and (c.agente_id = auth.uid() or c.promotoria_id = auth.uid())));
create policy "dueño edita polizas de sus clientes" on polizas for update using (
  exists(select 1 from clientes c where c.id = polizas.cliente_id and (c.agente_id = auth.uid() or c.promotoria_id = auth.uid())));
create policy "dueño elimina polizas de sus clientes" on polizas for delete using (
  exists(select 1 from clientes c where c.id = polizas.cliente_id and (c.agente_id = auth.uid() or c.promotoria_id = auth.uid())));

-- ============ SOLICITUDES: agente_id nullable + promotoria_id ============
alter table solicitudes add column promotoria_id uuid references promotorias(id) on delete cascade;
alter table solicitudes alter column agente_id drop not null;
alter table solicitudes add constraint solicitudes_dueno_check check (
  (agente_id is not null and promotoria_id is null) or (agente_id is null and promotoria_id is not null)
);
create index idx_solicitudes_promotoria on solicitudes(promotoria_id);

drop policy "agente ve sus solicitudes" on solicitudes;
drop policy "agente marca sus solicitudes" on solicitudes;
create policy "dueño ve sus solicitudes" on solicitudes for select using (agente_id = auth.uid() or promotoria_id = auth.uid());
create policy "dueño marca sus solicitudes" on solicitudes for update using (agente_id = auth.uid() or promotoria_id = auth.uid());

-- ============ portal_crear_solicitud: hereda el dueño real del cliente (agente o promotoria) ============
create or replace function public.portal_crear_solicitud(
  p_token uuid, p_tipo text, p_tipo_cambio text default null, p_ramo_interes text default null,
  p_descripcion text default null, p_foto_path text default null, p_poliza_id uuid default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cliente_id uuid;
  v_agente_id uuid;
  v_promotoria_id uuid;
  v_id uuid;
begin
  select id, agente_id, promotoria_id into v_cliente_id, v_agente_id, v_promotoria_id from clientes where token_publico = p_token;
  if v_cliente_id is null then
    raise exception 'Liga inválida';
  end if;
  if p_tipo not in ('endoso','cotizacion') then
    raise exception 'Tipo de solicitud inválido';
  end if;

  insert into solicitudes(cliente_id,agente_id,promotoria_id,tipo,tipo_cambio,ramo_interes,descripcion,foto_path,poliza_id)
  values (v_cliente_id,v_agente_id,v_promotoria_id,p_tipo,p_tipo_cambio,p_ramo_interes,p_descripcion,p_foto_path,p_poliza_id)
  returning id into v_id;

  return v_id;
end;
$$;

-- ============ notificar_nueva_solicitud: avisa al dueño real (agente o promotoria) ============
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
  from duenos_clientes d where d.id = coalesce(new.agente_id, new.promotoria_id);

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

-- ============ portal_cliente: el "agente" que ve el cliente puede ser una promotoria ============
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
  where c2.id = c.id;

  return resultado;
end;
$$;

-- ============ revisar_vencimientos: bloques 1, 2 y 5 generalizados a duenos_clientes ============
-- Los bloques 3 (verificación vehicular) y 4 (mantenimiento de flotilla) no tocan agentes/dueños
-- directo, así que ya funcionaban igual sin importar el tipo de dueño — no se tocan.
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
    select d.id as dueno_id, d.correo as dueno_correo, coalesce(d.nombre, d.nombre_negocio) as dueno_nombre
    from duenos_clientes d
    where d.correo is not null
      and exists (
        select 1 from polizas p join clientes c on c.id = p.cliente_id
        where coalesce(c.agente_id, c.promotoria_id) = d.id
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
      and p.fecha_fin between current_date and current_date + 15
      and p.estatus not in ('renovada','cancelada')
      and (p.aviso_agente_en is null or p.aviso_agente_en < now() - interval '7 days');
  end loop;

  -- ---- 2) pólizas por vencer -> CLIENTE (correo + push) ----
  for r in
    select c.id as cliente_id, c.correo as cliente_correo, c.nombre as cliente_nombre,
           c.token_publico as token, d.nombre as dueno_nombre, d.nombre_negocio as dueno_negocio, d.telefono as dueno_telefono
    from clientes c join duenos_clientes d on d.id = coalesce(c.agente_id, c.promotoria_id)
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
    select d.id as dueno_id, d.correo as dueno_correo, coalesce(d.nombre, d.nombre_negocio) as dueno_nombre
    from duenos_clientes d
    where d.correo is not null
      and exists (
        select 1 from clientes c
        where coalesce(c.agente_id, c.promotoria_id) = d.id
          and c.fecha_nacimiento is not null
          and extract(month from c.fecha_nacimiento) = extract(month from current_date)
          and extract(day from c.fecha_nacimiento) = extract(day from current_date)
      )
  loop
    select coalesce(string_agg(format('<li>%s</li>', c.nombre), ''), '') into v_filas
    from clientes c
    where coalesce(c.agente_id, c.promotoria_id) = r.dueno_id
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

-- ============ promotoria_notificar: ahora también puede avisar a sus propios clientes directos ============
-- El bloque de "clientes directos de sus agentes" queda igual; se agrega un bloque nuevo para los
-- clientes que le pertenecen directo a la promotoría (promotoria_id = auth.uid()).
create or replace function public.promotoria_notificar(
  p_agente_ids uuid[], p_cliente_ids uuid[], p_asunto text, p_mensaje text,
  p_via_correo boolean, p_via_push boolean, p_imagen_url text default null
) returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text; v_push_secret text; v_promo record; r record;
  v_correos int := 0; v_push int := 0;
  v_asunto_plano text := public.texto_plano_aviso(p_asunto);
  v_mensaje_plano text := public.texto_plano_aviso(p_mensaje);
  v_imagen_html text := case when p_imagen_url is not null
    then format('<p><img src="%s" alt="" style="max-width:100%%;border-radius:8px" /></p>', p_imagen_url)
    else '' end;
begin
  if not public.es_promotoria() then raise exception 'No autorizado'; end if;
  select * into v_promo from promotorias where id = auth.uid();
  if public.limite_avisos_alcanzado(auth.uid()) then
    raise exception 'Ya llegaste al límite de 5 envíos masivos en las últimas 24 horas. Intenta de nuevo más tarde.';
  end if;

  if p_via_correo then select decrypted_secret into v_key from vault.decrypted_secrets where name = 'resend_api_key'; end if;
  if p_via_push then select decrypted_secret into v_push_secret from vault.decrypted_secrets where name = 'push_internal_secret'; end if;

  -- a agentes de su red
  for r in select id, nombre, correo from agentes where id = any(p_agente_ids) and promotoria_id = auth.uid()
  loop
    if p_via_correo and v_key is not null and r.correo is not null then
      perform net.http_post(
        url := 'https://api.resend.com/emails',
        headers := jsonb_build_object('Authorization','Bearer '||v_key,'Content-Type','application/json'),
        body := jsonb_build_object(
          'from','Upco InsurGest <notificaciones@upco.app>',
          'to', jsonb_build_array(r.correo),
          'subject', v_asunto_plano,
          'html', format('<p>Hola %s,</p><p>%s</p>%s<p style="color:#8FA0B4;font-size:12px">Mensaje de tu promotoría %s.</p>',
            coalesce(r.nombre,'agente'), public.formatear_mensaje_aviso(p_mensaje), v_imagen_html, coalesce(v_promo.nombre_negocio, v_promo.correo))
        )
      );
      v_correos := v_correos + 1;
    end if;
    if p_via_push and v_push_secret is not null then
      perform net.http_post(
        url := 'https://pxcvckqahkjlizgotvqw.supabase.co/functions/v1/send-push',
        headers := jsonb_build_object(
          'Content-Type','application/json',
          'Authorization','Bearer sb_publishable_F2WhknXrY8MLjI5ftd0H6w_-XXjej6I',
          'x-internal-secret', v_push_secret
        ),
        body := jsonb_build_object('agente_id', r.id, 'title', v_asunto_plano, 'body', v_mensaje_plano, 'url', 'https://insurgest.upco.app/app/')
      );
      v_push := v_push + 1;
    end if;
  end loop;

  -- a clientes directos de sus agentes O a clientes que son suyos directo
  for r in
    select c.id, c.nombre, c.correo
    from clientes c left join agentes a on a.id = c.agente_id
    where c.id = any(p_cliente_ids) and (a.promotoria_id = auth.uid() or c.promotoria_id = auth.uid())
  loop
    if p_via_correo and v_key is not null and r.correo is not null then
      perform net.http_post(
        url := 'https://api.resend.com/emails',
        headers := jsonb_build_object('Authorization','Bearer '||v_key,'Content-Type','application/json'),
        body := jsonb_build_object(
          'from','Upco InsurGest <notificaciones@upco.app>',
          'to', jsonb_build_array(r.correo),
          'subject', v_asunto_plano,
          'html', format('<p>Hola %s,</p><p>%s</p>%s', split_part(r.nombre,' ',1), public.formatear_mensaje_aviso(p_mensaje), v_imagen_html)
        )
      );
      v_correos := v_correos + 1;
    end if;
    if p_via_push and v_push_secret is not null then
      perform net.http_post(
        url := 'https://pxcvckqahkjlizgotvqw.supabase.co/functions/v1/send-push',
        headers := jsonb_build_object(
          'Content-Type','application/json',
          'Authorization','Bearer sb_publishable_F2WhknXrY8MLjI5ftd0H6w_-XXjej6I',
          'x-internal-secret', v_push_secret
        ),
        body := jsonb_build_object('cliente_id', r.id, 'title', v_asunto_plano, 'body', v_mensaje_plano, 'url', 'https://insurgest.upco.app')
      );
      v_push := v_push + 1;
    end if;
  end loop;

  insert into avisos_masivos_log(remitente_id, remitente_tipo) values (auth.uid(), 'promotoria');
  return json_build_object('correos_enviados', v_correos, 'push_disparados', v_push);
end;
$$;

-- ============ IMPORT CSV: equivalente de agente_importar_clientes(), para promotoria ============
create or replace function public.promotoria_importar_clientes(p_filas jsonb) returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_promotoria_id uuid := auth.uid();
  v_fila jsonb;
  v_insertados int := 0;
  v_omitidos jsonb := '[]'::jsonb;
  v_indice int := 0;
  v_tipo_persona text;
  v_nombre text;
  v_rfc text;
  v_curp text;
  v_correo text;
  v_telefono text;
  v_notas text;
  v_duplicado boolean;
begin
  if not public.es_promotoria() then
    raise exception 'No autorizado';
  end if;
  if jsonb_array_length(p_filas) > 1000 then
    raise exception 'Máximo 1000 clientes por importación — divide tu archivo en partes más chicas.';
  end if;

  for v_fila in select * from jsonb_array_elements(p_filas)
  loop
    v_indice := v_indice + 1;
    v_tipo_persona := lower(trim(coalesce(v_fila->>'tipo_persona','fisica')));
    v_nombre := nullif(trim(coalesce(v_fila->>'nombre','')),'');
    v_rfc := nullif(upper(trim(coalesce(v_fila->>'rfc',''))),'');
    v_curp := nullif(upper(trim(coalesce(v_fila->>'curp',''))),'');
    v_correo := nullif(lower(trim(coalesce(v_fila->>'correo',''))),'');
    v_telefono := nullif(trim(coalesce(v_fila->>'telefono','')),'');
    v_notas := nullif(trim(coalesce(v_fila->>'notas','')),'');

    if v_nombre is null then
      v_omitidos := v_omitidos || jsonb_build_object('fila', v_indice, 'nombre', coalesce(v_fila->>'nombre',''), 'motivo', 'Falta el nombre');
      continue;
    end if;
    if v_tipo_persona not in ('fisica','moral') then
      v_tipo_persona := 'fisica';
    end if;
    if v_tipo_persona = 'moral' then
      v_curp := null;
    end if;

    v_duplicado := false;
    if v_rfc is not null then
      select exists(select 1 from clientes where promotoria_id = v_promotoria_id and rfc = v_rfc) into v_duplicado;
    end if;
    if not v_duplicado and v_correo is not null then
      select exists(select 1 from clientes where promotoria_id = v_promotoria_id and correo = v_correo) into v_duplicado;
    end if;
    if v_duplicado then
      v_omitidos := v_omitidos || jsonb_build_object('fila', v_indice, 'nombre', v_nombre, 'motivo', 'Ya tienes un cliente con ese RFC o correo');
      continue;
    end if;

    insert into clientes(promotoria_id, tipo_persona, nombre, rfc, curp, correo, telefono, notas)
    values (v_promotoria_id, v_tipo_persona, v_nombre, v_rfc, v_curp, v_correo, v_telefono, v_notas);
    v_insertados := v_insertados + 1;
  end loop;

  return json_build_object('insertados', v_insertados, 'omitidos', v_omitidos);
end;
$$;
grant execute on function public.promotoria_importar_clientes(jsonb) to authenticated;

-- ============ promotoria_clientes: ahora también lista sus propios clientes directos ============
create or replace function public.promotoria_clientes() returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_promotoria() then raise exception 'No autorizado'; end if;
  return coalesce((
    select json_agg(json_build_object(
      'id', c.id, 'nombre', c.nombre, 'correo', c.correo,
      'agente_nombre', case when c.promotoria_id is not null then 'Directo de tu promotoría' else coalesce(a.nombre, a.correo) end
    ) order by coalesce(a.nombre,''), c.nombre)
    from clientes c left join agentes a on a.id = c.agente_id
    where a.promotoria_id = auth.uid() or c.promotoria_id = auth.uid()
  ), '[]'::json);
end;
$$;

-- ============ Equivalentes de promotoría para las 3 funciones que hoy solo existen para agente ============
-- (cumpleaños próximos, resetear NIP, código de activación) — mismo patrón que
-- agente_notificar_clientes/promotoria_notificar y agente_importar_clientes/promotoria_importar_clientes:
-- funciones separadas por rol en vez de una sola genérica, siguiendo la convención ya establecida.

create or replace function public.promotoria_cumpleanos_proximos(p_dias integer default 14) returns json
language sql
stable
security definer
set search_path = public
as $$
  with base as (
    select
      c.id, c.nombre, c.telefono, c.correo, c.fecha_nacimiento,
      extract(month from c.fecha_nacimiento)::int as mes,
      case when extract(month from c.fecha_nacimiento)=2 and extract(day from c.fecha_nacimiento)=29
        then 28 else extract(day from c.fecha_nacimiento)::int end as dia_seguro
    from clientes c
    where c.promotoria_id = auth.uid() and c.fecha_nacimiento is not null
  ),
  con_fecha as (
    select *, make_date(extract(year from current_date)::int, mes, dia_seguro) as cumple_este_anio
    from base
  ),
  con_proximo as (
    select *,
      case when cumple_este_anio >= current_date then cumple_este_anio
           else make_date(extract(year from current_date)::int + 1, mes, dia_seguro)
      end as proximo_cumple
    from con_fecha
  )
  select coalesce(json_agg(json_build_object(
    'id', id, 'nombre', nombre, 'telefono', telefono, 'correo', correo,
    'proximo_cumple', proximo_cumple,
    'dias_para_cumple', (proximo_cumple - current_date)
  ) order by proximo_cumple), '[]'::json)
  from con_proximo
  where (proximo_cumple - current_date) <= p_dias;
$$;
grant execute on function public.promotoria_cumpleanos_proximos(integer) to authenticated;

create or replace function public.promotoria_resetear_nip(p_cliente_id uuid) returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not exists (select 1 from clientes where id = p_cliente_id and promotoria_id = auth.uid()) then
    raise exception 'No autorizado';
  end if;
  delete from portal_dispositivos where cliente_id = p_cliente_id;
  update clientes set nip_hash = null, nip_definido_en = null, nip_intentos = 0, nip_bloqueado_hasta = null
  where id = p_cliente_id;
end;
$$;
grant execute on function public.promotoria_resetear_nip(uuid) to authenticated;

create or replace function public.promotoria_codigo_activacion(p_cliente_id uuid) returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_codigo text;
begin
  select id, nip_hash, correo, codigo_activacion, codigo_expira into c
  from clientes where id = p_cliente_id and promotoria_id = auth.uid();
  if c.id is null then
    raise exception 'No autorizado';
  end if;
  if c.nip_hash is not null then
    raise exception 'Este cliente ya tiene NIP';
  end if;

  if c.codigo_activacion is null or c.codigo_expira < now() then
    v_codigo := public.generar_codigo_6();
    update clientes set codigo_activacion = v_codigo, codigo_expira = now() + interval '24 hours', codigo_intentos = 0
    where id = c.id;
  else
    v_codigo := c.codigo_activacion;
  end if;

  return json_build_object('codigo', v_codigo, 'expira', (select codigo_expira from clientes where id = c.id));
end;
$$;
grant execute on function public.promotoria_codigo_activacion(uuid) to authenticated;
