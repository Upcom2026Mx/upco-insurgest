-- Upco InsurGest — Sesión 47: máquina de prospección (campaña a agencias de la CNSF)
-- Correr con:  ~/bin/pg-insurgest -f supabase/migracion_sesion47_prospectos.sql
-- (o pegar completo en Supabase > SQL Editor > New query > Run — el bloque corre como UNA
--  transacción: si la última línea falla, TODO se revierte. Ver nota del cron al final.)
--
-- Qué es: la lista de agencias del Directorio de Agentes Persona Moral de la CNSF, con una
-- secuencia de 3 correos por prospecto y seguimiento de aperturas/clics/rebotes.
--
-- DECISIÓN IMPORTANTE — dominio de envío separado:
-- Estos correos NO salen de upco.app. Salen de theupgradecompany.mx, un dominio aparte que
-- nunca ha enviado correo. El motivo es reputación: upco.app manda hoy los correos de sistema
-- (códigos de activación, avisos de póliza por vencer, notificaciones a clientes que pagan) y
-- si un porcentaje de la campaña marca spam, esos correos empiezan a caer en spam también.
-- El rastreo de aperturas/clics de Resend se activa SOLO en ese dominio, por la misma razón:
-- la propia documentación de Resend advierte que el pixel de rastreo hace que los servidores
-- clasifiquen el correo como marketing — algo que no queremos que le pase a upco.app.

-- ============================================================================
-- 1. AJUSTES DE LA CAMPAÑA (una sola fila)
-- ============================================================================
create table prospeccion_ajustes (
  id boolean primary key default true check (id),   -- fuerza una única fila
  activa boolean not null default false,            -- arranca APAGADA a propósito
  envios_por_dia int not null default 20 check (envios_por_dia between 1 and 500),
  corridas_por_dia int not null default 10 check (corridas_por_dia between 1 and 24),
  dias_a_seguimiento int not null default 4 check (dias_a_seguimiento between 1 and 30),
  dias_a_cierre int not null default 5 check (dias_a_cierre between 1 and 30),
  remitente text not null default 'Upco <hola@theupgradecompany.mx>',
  responder_a text not null default 'hola@upco.app',
  -- El pie enlaza al aviso de privacidad en vez de repetir nombre y domicilio en cada correo.
  -- Además de que se lee mucho mejor, cumple mejor: enlazar el aviso ES ponerlo a disposición
  -- del titular (aviso simplificado que remite al integral), cosa que una línea con el
  -- domicilio no hacía. Los datos completos del responsable siguen ahí, a un clic.
  pie_legal text not null default
    'Le escribimos a esta dirección porque aparece publicada en el Directorio de Agentes Persona Moral Autorizados de la CNSF, de acceso público. Para dejar de recibir correos, responda "BAJA".<br>Upco · <a href="https://insurgest.upco.app/terminos/" style="color:#8593AA">Aviso de privacidad</a>'
);
insert into prospeccion_ajustes(id) values (true);

alter table prospeccion_ajustes enable row level security;
create policy "admin ve ajustes de prospeccion" on prospeccion_ajustes for select using (public.es_admin());

-- ============================================================================
-- 2. PROSPECTOS
-- ============================================================================
create table prospectos (
  id uuid primary key default gen_random_uuid(),
  agencia text not null,
  correo text not null unique,
  dominio text,
  ruta text not null check (ruta in ('web','insurgest')),
  estado text,
  cp text,
  ciudad text,
  -- 0 = sin contactar, 1/2/3 = número de correos ya enviados
  etapa smallint not null default 0 check (etapa between 0 and 3),
  estatus text not null default 'activo'
    check (estatus in ('activo','respondio','baja','rebotado','queja','completado')),
  ultimo_envio_en timestamptz,
  importado_en timestamptz not null default now(),
  notas text
);

-- El cron busca exactamente por esto: quién sigue activo, en qué etapa va y cuándo se le
-- escribió por última vez. Sin este índice, cada corrida haría un scan completo de la tabla.
create index idx_prospectos_cola on prospectos(estatus, etapa, ultimo_envio_en);
create index idx_prospectos_ruta on prospectos(ruta, estatus);

alter table prospectos enable row level security;
create policy "admin ve prospectos" on prospectos for select using (public.es_admin());

-- ============================================================================
-- 3. EVENTOS (envíos, aperturas, clics, rebotes)
-- ============================================================================
create table prospecto_eventos (
  id uuid primary key default gen_random_uuid(),
  prospecto_id uuid not null references prospectos(id) on delete cascade,
  etapa smallint,
  tipo text not null check (tipo in ('enviado','entregado','abierto','clic','rebotado','queja')),
  liga text,           -- solo para 'clic'
  ocurrio_en timestamptz not null default now()
);
create index idx_prospecto_eventos_prospecto on prospecto_eventos(prospecto_id, tipo);
-- El cupo del día se calcula contando los 'enviado' de hoy: esta consulta corre en cada corrida.
create index idx_prospecto_eventos_tipo_fecha on prospecto_eventos(tipo, ocurrio_en);

alter table prospecto_eventos enable row level security;
create policy "admin ve eventos de prospectos" on prospecto_eventos for select using (public.es_admin());

-- ============================================================================
-- 4. PLANTILLAS (editables desde /admin, no hardcodeadas en la función)
-- ============================================================================
create table prospecto_plantillas (
  ruta text not null check (ruta in ('web','insurgest')),
  etapa smallint not null check (etapa between 1 and 3),
  asunto text not null,
  cuerpo_html text not null,      -- sin pie legal: ese vive en prospeccion_ajustes
  primary key (ruta, etapa)
);

alter table prospecto_plantillas enable row level security;
create policy "admin ve plantillas" on prospecto_plantillas for select using (public.es_admin());

-- HTML deliberadamente mínimo (párrafos y ligas de texto, sin botones ni imágenes): un correo
-- frío muy maquetado se clasifica como promoción y baja la entrega. {AGENCIA} se sustituye al
-- enviar, escapando el nombre por si trae & o < (vienen del CSV de la CNSF tal cual).

-- ---------- RUTA WEB (agencias con correo gratuito) ----------
insert into prospecto_plantillas(ruta, etapa, asunto, cuerpo_html) values
('web', 1, 'Sitio web y correos propios para {AGENCIA}',
'<p>Buen día,</p>
<p>Somos Upco. Trabajamos con agencias de seguros en México y llegamos a {AGENCIA} por el Directorio de Agentes Persona Moral de la CNSF.</p>
<p>Le escribimos porque estamos armando sitios web para agencias, y creemos que a ustedes les puede sumar.</p>
<p>La idea es sencilla: que cuando alguien reciba su tarjeta o los recomiende, encuentre una página que respalde lo que ustedes ya son. Dominio propio, correos con el nombre de la agencia (contacto@suagencia.mx), y un sitio de una hoja hecho para que la gente les escriba.</p>
<p>Desde $1,800 + IVA al año, y queda listo en días.</p>
<p>Aquí puede ver los planes y qué incluye cada uno: <a href="https://web.upco.app">web.upco.app</a></p>
<p>Si le interesa, con gusto le armamos una propuesta con el nombre de su agencia. Y si no es para ustedes, respóndanos "BAJA" y no le volvemos a escribir.</p>
<p>Equipo Upco<br>hola@upco.app</p>'),

('web', 2, 'Los correos con el nombre de la agencia van incluidos',
'<p>Buen día,</p>
<p>Le escribimos hace unos días sobre el sitio para {AGENCIA}. Le contamos la parte del paquete que a las agencias les termina gustando más, y que no siempre es lo primero que se ve:</p>
<p>Los correos con el dominio de la agencia. contacto@suagencia.mx para el buzón general, y uno con el nombre de cada persona del equipo. En la tarjeta, en la firma, en cada cotización que mandan.</p>
<p>Es lo que hace que la agencia se lea como una casa con equipo detrás. Va incluido en el paquete junto con el sitio, no se cobra aparte.</p>
<p>¿Quiere que le revisemos qué dominio está disponible con el nombre de su agencia? Contéstenos el nombre y se lo buscamos hoy mismo.</p>
<p>Equipo Upco<br>hola@upco.app</p>'),

('web', 3, 'Último correo sobre el sitio',
'<p>Buen día,</p>
<p>Es nuestro último correo sobre esto, no queremos llenarle la bandeja.</p>
<p>Si en algún momento quiere ver los planes del sitio, aquí están y no cambian: <a href="https://web.upco.app">web.upco.app</a></p>
<p>Y le dejamos otra cosa por si le sirve más: también hacemos Upco InsurGest, un sistema para que las agencias lleven el control de sus pólizas y avisen solas cuándo toca cada renovación. Tiene 30 días de prueba sin pedir tarjeta: <a href="https://insurgest.upco.app">insurgest.upco.app</a></p>
<p>Gracias por su tiempo, y mucho éxito con la agencia.</p>
<p>Equipo Upco<br>hola@upco.app</p>'),

-- ---------- RUTA INSURGEST (agencias con dominio propio) ----------
('insurgest', 1, 'Un sistema de pólizas hecho en México para agencias',
'<p>Buen día,</p>
<p>Somos Upco. Llegamos a {AGENCIA} por el Directorio de Agentes Persona Moral de la CNSF.</p>
<p>Le escribimos para presentarle Upco InsurGest, un sistema de control de pólizas hecho en México y pensado para agencias como la suya.</p>
<p>Lo que hace, en corto: cargan su cartera y el sistema trabaja solo. Les avisa a ustedes de cada póliza que entra a renovación, y le avisa a su cliente de su póliza, de su verificación vehicular y del servicio de su auto. Todo con el nombre de la agencia.</p>
<p>El plan de agencia son $999 + IVA al mes e incluye 5 agentes, con 30 días de prueba sin tarjeta.</p>
<p>Aquí puede ver todo lo que trae: <a href="https://insurgest.upco.app/promotorias/">insurgest.upco.app/promotorias</a></p>
<p>Si quiere, se lo mostramos funcionando en 20 minutos con su propia cartera.</p>
<p>Equipo Upco<br>hola@upco.app</p>'),

('insurgest', 2, 'Lo que su agencia le puede regalar a sus clientes',
'<p>Buen día,</p>
<p>Le escribimos hace unos días sobre InsurGest. Le contamos la parte que a las agencias les termina de cerrar la idea, porque no es para ustedes: es para su cliente.</p>
<p>Cada cliente recibe una liga privada, protegida con NIP. Desde ahí ve sus pólizas, descarga sus PDFs, pide un endoso, levanta un siniestro con fotos, y registra sus autos para que el sistema le avise de la verificación y del servicio.</p>
<p>Visto de otro modo: es un servicio que la agencia le da a su cliente, con el nombre de ustedes. De las pocas cosas que hacen que alguien se quede por el trato y no por el precio.</p>
<p>Se lo podemos mostrar funcionando en 20 minutos, con una póliza real de las suyas.</p>
<p>Equipo Upco<br>hola@upco.app</p>'),

('insurgest', 3, 'Último correo, y le dejamos la liga de prueba',
'<p>Buen día,</p>
<p>Último correo, no queremos insistir de más.</p>
<p>Si prefiere verlo por su cuenta y sin hablar con nadie, la prueba de 30 días no pide tarjeta: <a href="https://insurgest.upco.app">insurgest.upco.app</a></p>
<p>Y por si le sirve tener los números claros: el plan de agencia son $999 + IVA al mes con 5 agentes incluidos, y $249 por cada agente adicional. Si fueran un agente solo, son $299.</p>
<p>Cuando sea buen momento, aquí estamos. Mucho éxito con la agencia.</p>
<p>Equipo Upco<br>hola@upco.app</p>');

-- ============================================================================
-- 5. IMPORTAR LA LISTA (desde el CSV, vía /admin)
-- ============================================================================
-- Recibe un arreglo JSON de filas. Ignora en silencio las que ya existan (unique por correo),
-- así se puede volver a importar el CSV actualizado de la CNSF sin duplicar ni reiniciar a
-- nadie que ya vaya a medio camino de la secuencia.
create or replace function public.admin_importar_prospectos(p_filas jsonb)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_insertados int := 0;
  v_omitidos int := 0;
  v_invalidos int := 0;
  r jsonb;
  v_correo text;
  v_ruta text;
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;

  for r in select * from jsonb_array_elements(p_filas)
  loop
    v_correo := lower(trim(coalesce(r->>'correo','')));

    if v_correo !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
       or coalesce(trim(r->>'agencia'),'') = '' then
      v_invalidos := v_invalidos + 1;
      continue;
    end if;

    -- La ruta puede venir dada; si no, se deduce del dominio del correo, que es exactamente
    -- el criterio de segmentación: dominio gratuito => probablemente sin sitio web.
    v_ruta := nullif(trim(coalesce(r->>'ruta','')),'');
    if v_ruta is null or v_ruta not in ('web','insurgest') then
      v_ruta := case
        when split_part(v_correo,'@',2) in (
          'gmail.com','hotmail.com','outlook.com','yahoo.com','yahoo.com.mx','live.com',
          'live.com.mx','prodigy.net.mx','msn.com','icloud.com','me.com','aol.com',
          'hotmail.es','outlook.es','hotmail.com.mx','yahoo.es'
        ) then 'web'
        else 'insurgest'
      end;
    end if;

    insert into prospectos(agencia, correo, dominio, ruta, estado, cp, ciudad)
    values (
      trim(r->>'agencia'),
      v_correo,
      split_part(v_correo,'@',2),
      v_ruta,
      nullif(trim(coalesce(r->>'estado','')),''),
      nullif(trim(coalesce(r->>'cp','')),''),
      nullif(trim(coalesce(r->>'ciudad','')),'')
    )
    on conflict (correo) do nothing;

    if found then v_insertados := v_insertados + 1; else v_omitidos := v_omitidos + 1; end if;
  end loop;

  return json_build_object('insertados', v_insertados, 'omitidos', v_omitidos, 'invalidos', v_invalidos);
end;
$$;
revoke all on function public.admin_importar_prospectos(jsonb) from public, anon, authenticated;
grant execute on function public.admin_importar_prospectos(jsonb) to authenticated;

-- ============================================================================
-- 6. EL CRON: mandar el lote que toca
-- ============================================================================
-- Corre cada hora en horario hábil y manda una fracción del tope diario, en vez de disparar
-- los 100 de golpe a las 9am. Un goteo parejo a lo largo del día se parece más a correo
-- humano y es mejor para la reputación de un dominio que apenas se está calentando.
create or replace function public.enviar_lote_prospectos()
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  a record;
  p record;
  t record;
  v_key text;
  v_enviados_hoy int;
  v_cupo_hoy int;
  v_cupo_corrida int;
  v_inicio_dia timestamptz;
  v_enviados int := 0;
  v_asunto text;
  v_html text;
  v_agencia_segura text;
begin
  select * into a from prospeccion_ajustes where id;
  if a is null or not a.activa then
    return json_build_object('enviados', 0, 'motivo', 'campaña pausada');
  end if;

  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'resend_api_key';
  if v_key is null then
    return json_build_object('enviados', 0, 'motivo', 'falta resend_api_key en Vault');
  end if;

  -- Cupo del día en horario de México (el servidor corre en UTC). México no tiene horario de
  -- verano desde 2022, así que el desfase es fijo.
  v_inicio_dia := (date_trunc('day', now() at time zone 'America/Mexico_City')) at time zone 'America/Mexico_City';
  select count(*) into v_enviados_hoy
    from prospecto_eventos where tipo = 'enviado' and ocurrio_en >= v_inicio_dia;

  v_cupo_hoy := a.envios_por_dia - v_enviados_hoy;
  if v_cupo_hoy <= 0 then
    return json_build_object('enviados', 0, 'motivo', 'tope diario alcanzado');
  end if;

  v_cupo_corrida := least(v_cupo_hoy, ceil(a.envios_por_dia::numeric / a.corridas_por_dia)::int);

  for p in
    select * from prospectos
    where estatus = 'activo'
      and (
        etapa = 0
        or (etapa = 1 and ultimo_envio_en <= now() - make_interval(days => a.dias_a_seguimiento))
        or (etapa = 2 and ultimo_envio_en <= now() - make_interval(days => a.dias_a_cierre))
      )
    -- Los que ya empezaron la secuencia van primero: dejar a alguien a medias es peor que
    -- tardar un día más en abrir un prospecto nuevo.
    order by etapa desc, ultimo_envio_en asc nulls last, importado_en asc
    limit v_cupo_corrida
  loop
    select * into t from prospecto_plantillas where ruta = p.ruta and etapa = p.etapa + 1;
    continue when t is null;

    v_agencia_segura := replace(replace(replace(p.agencia,'&','&amp;'),'<','&lt;'),'>','&gt;');
    v_asunto := replace(t.asunto, '{AGENCIA}', p.agencia);
    v_html := replace(t.cuerpo_html, '{AGENCIA}', v_agencia_segura)
              || '<hr style="border:0;border-top:1px solid #DDE4EE;margin:24px 0">'
              || '<p style="color:#8593AA;font-size:12px;line-height:1.5">' || a.pie_legal || '</p>';

    perform net.http_post(
      url := 'https://api.resend.com/emails',
      headers := jsonb_build_object('Authorization','Bearer '||v_key,'Content-Type','application/json'),
      body := jsonb_build_object(
        'from', a.remitente,
        'to', jsonb_build_array(p.correo),
        'reply_to', a.responder_a,
        'subject', v_asunto,
        'html', v_html,
        -- Los tags vuelven en el webhook de Resend: así se sabe de qué prospecto y de qué
        -- correo de la secuencia fue cada apertura, clic o rebote, sin tener que guardar el
        -- email_id (pg_net es asíncrono y no devuelve la respuesta del POST en el momento).
        'tags', jsonb_build_array(
          jsonb_build_object('name','prospecto_id','value', p.id::text),
          jsonb_build_object('name','etapa','value', (p.etapa + 1)::text)
        ),
        -- Le da al destinatario un botón de baja en su propio cliente de correo. Los
        -- proveedores lo premian en entregabilidad, y una baja siempre es mejor que una
        -- queja de spam.
        'headers', jsonb_build_object(
          'List-Unsubscribe', '<mailto:' || a.responder_a || '?subject=BAJA>'
        )
      )
    );

    update prospectos
      set etapa = p.etapa + 1,
          ultimo_envio_en = now(),
          estatus = case when p.etapa + 1 >= 3 then 'completado' else estatus end
      where id = p.id;

    insert into prospecto_eventos(prospecto_id, etapa, tipo)
      values (p.id, p.etapa + 1, 'enviado');

    v_enviados := v_enviados + 1;
  end loop;

  return json_build_object('enviados', v_enviados, 'cupo_restante_hoy', v_cupo_hoy - v_enviados);
end;
$$;
-- IMPRESCINDIBLE, y ojo con el detalle: no basta con revocar de PUBLIC. Supabase le otorga
-- EXECUTE a anon y authenticated de forma EXPLÍCITA (default privileges del schema public),
-- así que un "revoke from public" los deja intactos — se verificó en producción con
-- has_function_privilege() y efectivamente anon seguía pudiendo ejecutarla.
-- Esta función es SECURITY DEFINER y no tiene candado interno: sin revocar los tres roles,
-- cualquiera con la anon key (que va embebida en el código público) podría disparar envíos de
-- la campaña a voluntad. Solo la llaman el cron y admin_disparar_lote(), que corre como el
-- dueño y por eso no necesita grant.
revoke all on function public.enviar_lote_prospectos() from public, anon, authenticated;

-- ============================================================================
-- 7. REGISTRAR EVENTOS DEL WEBHOOK DE RESEND
-- ============================================================================
-- La llama la Edge Function resend-webhook (con service_role) después de verificar la firma.
-- Un rebote o una queja de spam sacan al prospecto de la secuencia de inmediato: seguir
-- escribiéndole a un buzón que rebota es la forma más rápida de quemar el dominio.
create or replace function public.registrar_evento_prospecto(
  p_prospecto_id uuid,
  p_etapa smallint,
  p_tipo text,
  p_liga text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from prospectos where id = p_prospecto_id) then return; end if;

  insert into prospecto_eventos(prospecto_id, etapa, tipo, liga)
    values (p_prospecto_id, p_etapa, p_tipo, p_liga);

  if p_tipo = 'rebotado' then
    update prospectos set estatus = 'rebotado' where id = p_prospecto_id;
  elsif p_tipo = 'queja' then
    update prospectos set estatus = 'queja' where id = p_prospecto_id;
  end if;
end;
$$;
-- Nadie más que la Edge Function (service_role) puede llamarla: ni un agente autenticado ni
-- anon deben poder inventar aperturas o marcar prospectos como rebotados.
revoke all on function public.registrar_evento_prospecto(uuid,smallint,text,text) from public, anon, authenticated;
grant execute on function public.registrar_evento_prospecto(uuid,smallint,text,text) to service_role;

-- ============================================================================
-- 8. PANEL: leer y operar
-- ============================================================================
create or replace function public.admin_prospeccion_resumen() returns json
language plpgsql
security definer
set search_path = public
as $$
declare v_inicio_dia timestamptz;
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  v_inicio_dia := (date_trunc('day', now() at time zone 'America/Mexico_City')) at time zone 'America/Mexico_City';

  return json_build_object(
    'ajustes', (select row_to_json(t) from (select * from prospeccion_ajustes where id) t),
    'total', (select count(*) from prospectos),
    'sin_contactar', (select count(*) from prospectos where estatus='activo' and etapa=0),
    'en_secuencia', (select count(*) from prospectos where estatus='activo' and etapa between 1 and 2),
    'completados', (select count(*) from prospectos where estatus='completado'),
    'respondieron', (select count(*) from prospectos where estatus='respondio'),
    'bajas', (select count(*) from prospectos where estatus='baja'),
    'rebotados', (select count(*) from prospectos where estatus='rebotado'),
    'quejas', (select count(*) from prospectos where estatus='queja'),
    'por_ruta', (select coalesce(json_agg(x),'[]'::json) from (
        select ruta, count(*) as total from prospectos group by ruta order by ruta) x),
    'correos_enviados', (select count(*) from prospecto_eventos where tipo='enviado'),
    'enviados_hoy', (select count(*) from prospecto_eventos where tipo='enviado' and ocurrio_en >= v_inicio_dia),
    -- Aperturas y clics se cuentan por prospecto único, no por evento: un mismo correo abierto
    -- cinco veces es una persona interesada, no cinco.
    'abrieron', (select count(distinct prospecto_id) from prospecto_eventos where tipo='abierto'),
    'clicaron', (select count(distinct prospecto_id) from prospecto_eventos where tipo='clic')
  );
end;
$$;
revoke all on function public.admin_prospeccion_resumen() from public, anon, authenticated;
grant execute on function public.admin_prospeccion_resumen() to authenticated;

create or replace function public.admin_prospectos(
  p_estatus text default null,
  p_ruta text default null,
  p_busqueda text default null,
  p_limite int default 200
) returns json
language plpgsql
security definer
set search_path = public
as $$
declare v_q text;
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  v_q := nullif(trim(coalesce(p_busqueda,'')),'');

  return coalesce((
    select json_agg(t order by t.importado_en) from (
      select p.*,
        (select count(*) from prospecto_eventos e where e.prospecto_id=p.id and e.tipo='abierto') as aperturas,
        (select count(*) from prospecto_eventos e where e.prospecto_id=p.id and e.tipo='clic') as clics
      from prospectos p
      where (p_estatus is null or p.estatus = p_estatus)
        and (p_ruta is null or p.ruta = p_ruta)
        and (v_q is null or p.agencia ilike '%'||v_q||'%' or p.correo ilike '%'||v_q||'%'
             or coalesce(p.estado,'') ilike '%'||v_q||'%')
      order by p.importado_en
      limit greatest(1, least(coalesce(p_limite,200), 1000))
    ) t
  ), '[]'::json);
end;
$$;
revoke all on function public.admin_prospectos(text,text,text,int) from public, anon, authenticated;
grant execute on function public.admin_prospectos(text,text,text,int) to authenticated;

-- Marcar a mano lo que llega al buzón: "contestó" o "pidió baja". Cualquiera de los dos lo
-- saca de la secuencia inmediatamente.
create or replace function public.admin_marcar_prospecto(p_id uuid, p_estatus text, p_notas text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  if p_estatus not in ('activo','respondio','baja','completado') then
    raise exception 'Estatus no válido';
  end if;
  update prospectos
    set estatus = p_estatus,
        notas = coalesce(nullif(trim(coalesce(p_notas,'')),''), notas)
    where id = p_id;
end;
$$;
revoke all on function public.admin_marcar_prospecto(uuid,text,text) from public, anon, authenticated;
grant execute on function public.admin_marcar_prospecto(uuid,text,text) to authenticated;

create or replace function public.admin_guardar_ajustes_prospeccion(
  p_activa boolean,
  p_envios_por_dia int,
  p_corridas_por_dia int,
  p_dias_a_seguimiento int,
  p_dias_a_cierre int,
  p_remitente text,
  p_responder_a text,
  p_pie_legal text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  update prospeccion_ajustes set
    activa = p_activa,
    envios_por_dia = p_envios_por_dia,
    corridas_por_dia = p_corridas_por_dia,
    dias_a_seguimiento = p_dias_a_seguimiento,
    dias_a_cierre = p_dias_a_cierre,
    remitente = p_remitente,
    responder_a = p_responder_a,
    -- null deja el que ya estaba: así el panel puede guardar solo el ritmo sin arriesgarse a
    -- borrar el pie legal por mandar un campo vacío.
    pie_legal = coalesce(nullif(trim(coalesce(p_pie_legal,'')),''), pie_legal)
  where id;
end;
$$;
revoke all on function public.admin_guardar_ajustes_prospeccion(boolean,int,int,int,int,text,text,text) from public, anon, authenticated;
grant execute on function public.admin_guardar_ajustes_prospeccion(boolean,int,int,int,int,text,text,text) to authenticated;

create or replace function public.admin_plantillas_prospeccion() returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  return coalesce((select json_agg(t order by t.ruta, t.etapa) from prospecto_plantillas t), '[]'::json);
end;
$$;
revoke all on function public.admin_plantillas_prospeccion() from public, anon, authenticated;
grant execute on function public.admin_plantillas_prospeccion() to authenticated;

create or replace function public.admin_guardar_plantilla(
  p_ruta text, p_etapa smallint, p_asunto text, p_cuerpo_html text
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  update prospecto_plantillas
    set asunto = p_asunto, cuerpo_html = p_cuerpo_html
    where ruta = p_ruta and etapa = p_etapa;
end;
$$;
revoke all on function public.admin_guardar_plantilla(text,smallint,text,text) from public, anon, authenticated;
grant execute on function public.admin_guardar_plantilla(text,smallint,text,text) to authenticated;

-- Botón "Mandar ahora" del panel, para no esperar a la siguiente hora en punto al probar.
create or replace function public.admin_disparar_lote() returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  return public.enviar_lote_prospectos();
end;
$$;
revoke all on function public.admin_disparar_lote() from public, anon, authenticated;
grant execute on function public.admin_disparar_lote() to authenticated;

-- ============================================================================
-- 9. PROGRAMAR EL CRON
-- ============================================================================
-- Cada hora en punto de 15:00 a 00:00 UTC = 9:00 a 18:00 en CDMX (10 corridas, que es el
-- default de corridas_por_dia). Si esta línea falla porque pg_cron no está activo, TODO lo
-- anterior de este archivo se revierte — activa la extensión en Database > Extensions y
-- vuelve a correr el archivo COMPLETO, no solo esta línea.
select cron.schedule(
  'enviar-lote-prospectos',
  '0 15-23,0 * * *',
  $$select public.enviar_lote_prospectos();$$
);

-- Arranca apagada (prospeccion_ajustes.activa = false): el cron correrá y no hará nada hasta
-- que le des "Activar campaña" en /admin. Es a propósito — así se puede correr esta migración
-- antes de que el dominio esté verificado en Resend, sin mandarle nada a nadie.
