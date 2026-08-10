-- Upco InsurGest — Sesión 51: la máquina de prospección deja de ser "una campaña" y pasa a ser
-- "una campaña por segmento". Primer segmento nuevo: escuelas (para Upco WEB / futuro Upco Edu).
-- Correr completo en Supabase > SQL Editor > New query > Run (o con psql/pg-insurgest -f).
-- Corre como UNA transacción: si la última línea falla, TODO se revierte — normal en este proyecto.
--
-- QUÉ CAMBIA Y POR QUÉ:
-- La Sesión 47 construyó la máquina para UN solo público (agencias de seguros de la CNSF), con
-- dos "rutas" de copy (web/insurgest) pero una sola configuración de campaña compartida. Ahora
-- se necesita un segundo público (escuelas, fuente DENUE/INEGI) con su propio ritmo de envío,
-- su propio texto legal (la fuente de los datos ya NO es la CNSF) y sus propios 3 correos —
-- sin tocar ni pausar la campaña de agencias que ya está corriendo en producción.
--
-- Se generaliza agregando una columna `segmento` en los 3 lugares que antes asumían un solo
-- público: prospectos, prospecto_plantillas (ahora clave con segmento+ruta+etapa) y
-- prospeccion_ajustes (ahora UNA FILA POR SEGMENTO en vez de una fila única) — así cada
-- segmento se prende/pausa y se ajusta por separado, y enviar_lote_prospectos() recorre todos
-- los segmentos activos en cada corrida del cron.
--
-- IMPORTANTE — todas las funciones cuyo número de parámetros cambia se DROPEAN antes de
-- recrearse (create or replace no basta cuando cambia la firma: PostgREST se queda sirviendo
-- la versión vieja desde su caché de esquema, error PGRST202 — ya nos pasó en la Sesión 6).

-- ============================================================================
-- 1. PROSPECTOS: nuevas columnas de segmento
-- ============================================================================
alter table prospectos add column segmento text not null default 'agencias_seguros'
  check (segmento in ('agencias_seguros','escuelas'));
-- Nivel educativo solo aplica al segmento escuelas; queda null para agencias_seguros.
alter table prospectos add column nivel_educativo text
  check (nivel_educativo is null or nivel_educativo in ('preescolar','primaria','secundaria','media_superior','superior','otro'));
-- El dato que hace "sofisticado" al segmento escuelas: filtrar quién NO tiene sitio ya.
alter table prospectos add column tiene_sitio_web boolean;
alter table prospectos add column sitio_web_actual text;
-- De dónde salió el registro (cnsf, denue...) — útil el día que se agregue un tercer segmento
-- con otra fuente y para saber qué texto legal de origen corresponde a cada prospecto.
alter table prospectos add column fuente text not null default 'cnsf' check (fuente in ('cnsf','denue'));

-- El panel y el cron ahora filtran por segmento en casi cada consulta.
create index idx_prospectos_segmento on prospectos(segmento, estatus, etapa);

comment on column prospectos.agencia is
  'Nombre del prospecto (agencia de seguros, escuela, etc. según segmento) — el nombre de la columna quedó de la Sesión 47, no vale la pena una migración solo por renombrarla.';

-- ============================================================================
-- 2. PROSPECTO_PLANTILLAS: la clave ahora incluye segmento
-- ============================================================================
alter table prospecto_plantillas add column segmento text not null default 'agencias_seguros'
  check (segmento in ('agencias_seguros','escuelas'));
alter table prospecto_plantillas drop constraint prospecto_plantillas_pkey;
alter table prospecto_plantillas add primary key (segmento, ruta, etapa);

-- ---------- Los 3 correos del segmento escuelas ----------
-- Mismo criterio de la Sesión 49 (validado por el dueño para agencias): sin "Estimados", abre
-- con la promesa, un solo llamado a la acción, estilos en línea porque los clientes de correo
-- ignoran las hojas de estilo. Lo distinto aquí es el diferenciador real: el sitio DEMO. En vez
-- de describir el producto, el correo manda a verlo ya armado con el nombre de una escuela.
-- {NOMBRE} y {AGENCIA} son intercambiables (ver la función de envío) — el token se guarda como
-- {NOMBRE} en las plantillas nuevas por legibilidad, aunque la columna siga llamándose agencia.
insert into prospecto_plantillas(segmento, ruta, etapa, asunto, cuerpo_html) values
('escuelas','web',1,
 'Así se vería el sitio de {NOMBRE}',
 '<p style="font-size:19px;font-weight:700;line-height:1.3;margin:0 0 16px;color:#10284A">Le armamos un sitio de muestra con el nombre de {NOMBRE} para que lo vea funcionando, no descrito.</p>
<p>Somos Upco, empresa mexicana de tecnología. Hacemos sitios web para instituciones educativas — desde jardín de niños hasta universidad — pensados para que un padre de familia encuentre información real en menos de un minuto: oferta educativa, proceso de admisión y cómo contactar a la escuela.</p>
<p style="background:#F4F6FA;border:1px solid #DDE4EE;border-radius:8px;padding:12px 16px;margin:0 0 18px">Aquí puede ver un ejemplo real, con el mismo tipo de secciones que tendría el de {NOMBRE}:</p>
<p style="margin:0 0 16px"><a href="https://web.upco.app/demos/escuelas/" style="display:inline-block;background:#10284A;color:#ffffff;text-decoration:none;padding:13px 24px;border-radius:9px;font-weight:700">Ver el sitio de muestra</a></p>
<p>Dominio, hospedaje, desarrollo y correos profesionales del plantel, desde $1,800 MXN + IVA al año, listo en días.</p>
<p style="font-size:12.5px;color:#8593AA;line-height:1.55">Upco — empresa mexicana de tecnología.<br><a href="https://upco.app" style="color:#1f4a80">upco.app</a> · <a href="https://web.upco.app" style="color:#1f4a80">web.upco.app</a></p>'),

('escuelas','web',2,
 'Correos con el nombre del plantel, no con Gmail',
 '<p style="font-size:19px;font-weight:700;line-height:1.3;margin:0 0 16px;color:#10284A">contacto@{DOMINIO_EJEMPLO} en vez de un correo gratuito, incluido en el mismo paquete.</p>
<p>Le escribimos hace unos días sobre el sitio de muestra de {NOMBRE}. La parte que a los planteles termina de convencer no siempre es el sitio en sí, sino los correos: cuentas profesionales con el nombre de la escuela para dirección, administración e inscripciones, listas para usarse desde el primer día.</p>
<ul style="margin:0 0 14px;padding-left:20px">
<li style="margin-bottom:6px">Sitio de una página con la información que buscan los padres</li>
<li style="margin-bottom:6px">Formulario de contacto e inscripción</li>
<li style="margin-bottom:6px">Correos profesionales del plantel incluidos</li>
</ul>
<p style="margin:0 0 16px"><a href="https://web.upco.app/demos/escuelas/" style="display:inline-block;background:#10284A;color:#ffffff;text-decoration:none;padding:13px 24px;border-radius:9px;font-weight:700">Ver el sitio de muestra</a></p>
<p style="font-size:12.5px;color:#8593AA;line-height:1.55">Upco — empresa mexicana de tecnología.<br><a href="https://upco.app" style="color:#1f4a80">upco.app</a> · <a href="https://web.upco.app" style="color:#1f4a80">web.upco.app</a></p>'),

('escuelas','web',3,
 'Último correo sobre el sitio de {NOMBRE}',
 '<p style="font-size:19px;font-weight:700;line-height:1.3;margin:0 0 16px;color:#10284A">Último correo, no queremos llenarle la bandeja.</p>
<p>Si en algún momento le interesa, el sitio de muestra sigue disponible y los planes no cambian: desde $1,800 MXN + IVA al año, con entrega en días.</p>
<p style="margin:0 0 16px"><a href="https://web.upco.app/demos/escuelas/" style="display:inline-block;background:#10284A;color:#ffffff;text-decoration:none;padding:13px 24px;border-radius:9px;font-weight:700">Ver el sitio de muestra</a></p>
<p>Gracias por su tiempo, y mucho éxito con el ciclo escolar.</p>
<p style="font-size:12.5px;color:#8593AA;line-height:1.55">Upco — empresa mexicana de tecnología.<br><a href="https://upco.app" style="color:#1f4a80">upco.app</a></p>');

-- ============================================================================
-- 3. PROSPECCION_AJUSTES: una fila por segmento en vez de una fila única
-- ============================================================================
alter table prospeccion_ajustes add column segmento text;
update prospeccion_ajustes set segmento = 'agencias_seguros' where segmento is null;
alter table prospeccion_ajustes alter column segmento set not null;
alter table prospeccion_ajustes add constraint prospeccion_ajustes_segmento_check
  check (segmento in ('agencias_seguros','escuelas'));
alter table prospeccion_ajustes drop constraint prospeccion_ajustes_pkey;
alter table prospeccion_ajustes drop column id;
alter table prospeccion_ajustes add primary key (segmento);

insert into prospeccion_ajustes(
  segmento, activa, envios_por_dia, corridas_por_dia, dias_a_seguimiento, dias_a_cierre,
  remitente, responder_a, pie_legal
) values (
  'escuelas', false, 20, 10, 4, 5,
  'Upco <hola@theupgradecompany.mx>', 'hola@upco.app',
  'Le escribimos a esta dirección porque aparece publicada en el Directorio Estadístico Nacional de Unidades Económicas (DENUE) del INEGI, de acceso público. Para dejar de recibir correos, responda "BAJA".<br>Upco · <a href="https://web.upco.app/terminos/" style="color:#8593AA">Aviso de privacidad</a>'
);
-- Arranca apagada, igual que agencias_seguros en su momento: no manda nada hasta "Activar
-- campaña" en /admin, y hace falta el token de DENUE + la lista importada antes de eso de todas formas.

-- ============================================================================
-- 4. admin_importar_prospectos: ahora recibe el segmento y los campos propios de escuelas
-- ============================================================================
drop function if exists public.admin_importar_prospectos(jsonb);

create or replace function public.admin_importar_prospectos(p_filas jsonb, p_segmento text default 'agencias_seguros')
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
  v_nivel text;
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  if p_segmento not in ('agencias_seguros','escuelas') then raise exception 'Segmento no válido'; end if;

  for r in select * from jsonb_array_elements(p_filas)
  loop
    v_correo := lower(trim(coalesce(r->>'correo','')));

    if v_correo !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
       or coalesce(trim(r->>'agencia'),'') = '' then
      v_invalidos := v_invalidos + 1;
      continue;
    end if;

    if p_segmento = 'escuelas' then
      -- No hay producto tipo "InsurGest" para escuelas todavía: siempre se vende el sitio.
      v_ruta := 'web';
      v_nivel := nullif(trim(coalesce(r->>'nivel_educativo','')),'');
      if v_nivel is not null and v_nivel not in ('preescolar','primaria','secundaria','media_superior','superior','otro') then
        v_nivel := 'otro';
      end if;
    else
      -- Mismo criterio de la Sesión 47 para agencias: dominio gratuito => probablemente sin sitio.
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
      v_nivel := null;
    end if;

    insert into prospectos(
      agencia, correo, dominio, ruta, estado, cp, ciudad,
      segmento, nivel_educativo, tiene_sitio_web, sitio_web_actual, fuente
    )
    values (
      trim(r->>'agencia'),
      v_correo,
      split_part(v_correo,'@',2),
      v_ruta,
      nullif(trim(coalesce(r->>'estado','')),''),
      nullif(trim(coalesce(r->>'cp','')),''),
      nullif(trim(coalesce(r->>'ciudad','')),''),
      p_segmento,
      v_nivel,
      case when r ? 'tiene_sitio_web' then (r->>'tiene_sitio_web')::boolean else null end,
      nullif(trim(coalesce(r->>'sitio_web_actual','')),''),
      case when p_segmento = 'escuelas' then 'denue' else 'cnsf' end
    )
    on conflict (correo) do nothing;

    if found then v_insertados := v_insertados + 1; else v_omitidos := v_omitidos + 1; end if;
  end loop;

  return json_build_object('insertados', v_insertados, 'omitidos', v_omitidos, 'invalidos', v_invalidos);
end;
$$;
revoke all on function public.admin_importar_prospectos(jsonb,text) from public, anon, authenticated;
grant execute on function public.admin_importar_prospectos(jsonb,text) to authenticated;

-- ============================================================================
-- 5. enviar_lote_prospectos: ahora recorre TODOS los segmentos activos en cada corrida
-- ============================================================================
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
  v_enviados int;
  v_asunto text;
  v_html text;
  v_nombre_seguro text;
  v_detalle jsonb := '[]'::jsonb;
  v_total int := 0;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'resend_api_key_campana';
  if v_key is null then
    return json_build_object('enviados', 0, 'motivo', 'falta resend_api_key_campana en Vault');
  end if;

  v_inicio_dia := (date_trunc('day', now() at time zone 'America/Mexico_City')) at time zone 'America/Mexico_City';

  for a in select * from prospeccion_ajustes where activa order by segmento loop
    v_enviados := 0;

    select count(*) into v_enviados_hoy
      from prospecto_eventos e
      join prospectos pr on pr.id = e.prospecto_id
      where e.tipo = 'enviado' and e.ocurrio_en >= v_inicio_dia and pr.segmento = a.segmento;

    v_cupo_hoy := a.envios_por_dia - v_enviados_hoy;

    if v_cupo_hoy > 0 then
      v_cupo_corrida := least(v_cupo_hoy, ceil(a.envios_por_dia::numeric / a.corridas_por_dia)::int);

      for p in
        select * from prospectos
        where segmento = a.segmento
          and estatus = 'activo'
          and (
            etapa = 0
            or (etapa = 1 and ultimo_envio_en <= now() - make_interval(days => a.dias_a_seguimiento))
            or (etapa = 2 and ultimo_envio_en <= now() - make_interval(days => a.dias_a_cierre))
          )
        order by etapa desc, ultimo_envio_en asc nulls last, importado_en asc
        limit v_cupo_corrida
      loop
        select * into t from prospecto_plantillas where segmento = a.segmento and ruta = p.ruta and etapa = p.etapa + 1;
        continue when t is null;

        v_nombre_seguro := replace(replace(replace(p.agencia,'&','&amp;'),'<','&lt;'),'>','&gt;');
        v_asunto := replace(replace(t.asunto, '{AGENCIA}', p.agencia), '{NOMBRE}', p.agencia);
        v_html := replace(replace(t.cuerpo_html, '{AGENCIA}', v_nombre_seguro), '{NOMBRE}', v_nombre_seguro)
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
            'tags', jsonb_build_array(
              jsonb_build_object('name','prospecto_id','value', p.id::text),
              jsonb_build_object('name','etapa','value', (p.etapa + 1)::text)
            ),
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
    end if;

    v_detalle := v_detalle || jsonb_build_object('segmento', a.segmento, 'enviados', v_enviados);
    v_total := v_total + v_enviados;
  end loop;

  if v_total = 0 and jsonb_array_length(v_detalle) = 0 then
    return json_build_object('enviados', 0, 'motivo', 'ningún segmento activo');
  end if;

  return json_build_object('enviados', v_total, 'detalle', v_detalle);
end;
$$;
revoke all on function public.enviar_lote_prospectos() from public, anon, authenticated;

-- ============================================================================
-- 6. Panel: leer y operar, todo con p_segmento
-- ============================================================================
drop function if exists public.admin_prospeccion_resumen();

create or replace function public.admin_prospeccion_resumen(p_segmento text default 'agencias_seguros')
returns json
language plpgsql
security definer
set search_path = public
as $$
declare v_inicio_dia timestamptz;
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  v_inicio_dia := (date_trunc('day', now() at time zone 'America/Mexico_City')) at time zone 'America/Mexico_City';

  return json_build_object(
    'ajustes', (select row_to_json(t) from (select * from prospeccion_ajustes where segmento = p_segmento) t),
    'total', (select count(*) from prospectos where segmento = p_segmento),
    'sin_contactar', (select count(*) from prospectos where segmento = p_segmento and estatus='activo' and etapa=0),
    'en_secuencia', (select count(*) from prospectos where segmento = p_segmento and estatus='activo' and etapa between 1 and 2),
    'completados', (select count(*) from prospectos where segmento = p_segmento and estatus='completado'),
    'respondieron', (select count(*) from prospectos where segmento = p_segmento and estatus='respondio'),
    'bajas', (select count(*) from prospectos where segmento = p_segmento and estatus='baja'),
    'rebotados', (select count(*) from prospectos where segmento = p_segmento and estatus='rebotado'),
    'quejas', (select count(*) from prospectos where segmento = p_segmento and estatus='queja'),
    'sin_sitio_web', (select count(*) from prospectos where segmento = p_segmento and tiene_sitio_web = false),
    'por_ruta', (select coalesce(json_agg(x),'[]'::json) from (
        select ruta, count(*) as total from prospectos where segmento = p_segmento group by ruta order by ruta) x),
    'por_estado', (select coalesce(json_agg(x),'[]'::json) from (
        select coalesce(estado,'Sin estado') as estado, count(*) as total from prospectos
        where segmento = p_segmento group by estado order by total desc limit 15) x),
    'por_nivel', (select coalesce(json_agg(x),'[]'::json) from (
        select coalesce(nivel_educativo,'Sin clasificar') as nivel, count(*) as total from prospectos
        where segmento = p_segmento group by nivel_educativo order by total desc) x),
    'correos_enviados', (select count(*) from prospecto_eventos e join prospectos pr on pr.id=e.prospecto_id where e.tipo='enviado' and pr.segmento = p_segmento),
    'enviados_hoy', (select count(*) from prospecto_eventos e join prospectos pr on pr.id=e.prospecto_id where e.tipo='enviado' and e.ocurrio_en >= v_inicio_dia and pr.segmento = p_segmento),
    'abrieron', (select count(distinct e.prospecto_id) from prospecto_eventos e join prospectos pr on pr.id=e.prospecto_id where e.tipo='abierto' and pr.segmento = p_segmento),
    'clicaron', (select count(distinct e.prospecto_id) from prospecto_eventos e join prospectos pr on pr.id=e.prospecto_id where e.tipo='clic' and pr.segmento = p_segmento)
  );
end;
$$;
revoke all on function public.admin_prospeccion_resumen(text) from public, anon, authenticated;
grant execute on function public.admin_prospeccion_resumen(text) to authenticated;

drop function if exists public.admin_prospectos(text,text,text,int,text);

create or replace function public.admin_prospectos(
  p_estatus  text default null,
  p_ruta     text default null,
  p_busqueda text default null,
  p_limite   int  default 200,
  p_vista    text default null,
  p_segmento text default 'agencias_seguros'
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
        (select count(*) from prospecto_eventos e where e.prospecto_id=p.id and e.tipo='clic')    as clics
      from prospectos p
      where p.segmento = p_segmento
        and (p_estatus is null or p.estatus = p_estatus)
        and (p_ruta is null or p.ruta = p_ruta)
        and (v_q is null or p.agencia ilike '%'||v_q||'%' or p.correo ilike '%'||v_q||'%'
             or coalesce(p.estado,'') ilike '%'||v_q||'%')
        and (
          p_vista is null
          or (p_vista = 'sin_contactar' and p.estatus = 'activo' and p.etapa = 0)
          or (p_vista = 'en_secuencia'  and p.estatus = 'activo' and p.etapa between 1 and 2)
          or (p_vista = 'contactados'   and p.etapa > 0)
          or (p_vista = 'problema'      and p.estatus in ('rebotado','queja'))
          or (p_vista = 'sin_sitio_web' and p.tiene_sitio_web = false)
        )
      order by p.importado_en
      limit greatest(1, least(coalesce(p_limite,200), 1000))
    ) t
  ), '[]'::json);
end;
$$;
revoke all on function public.admin_prospectos(text,text,text,int,text,text) from public, anon, authenticated;
grant execute on function public.admin_prospectos(text,text,text,int,text,text) to authenticated;

drop function if exists public.admin_guardar_ajustes_prospeccion(boolean,int,int,int,int,text,text,text);

create or replace function public.admin_guardar_ajustes_prospeccion(
  p_segmento text,
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
    pie_legal = coalesce(nullif(trim(coalesce(p_pie_legal,'')),''), pie_legal)
  where segmento = p_segmento;
end;
$$;
revoke all on function public.admin_guardar_ajustes_prospeccion(text,boolean,int,int,int,int,text,text,text) from public, anon, authenticated;
grant execute on function public.admin_guardar_ajustes_prospeccion(text,boolean,int,int,int,int,text,text,text) to authenticated;

drop function if exists public.admin_plantillas_prospeccion();

create or replace function public.admin_plantillas_prospeccion(p_segmento text default 'agencias_seguros')
returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  return coalesce((select json_agg(t order by t.ruta, t.etapa) from prospecto_plantillas t where t.segmento = p_segmento), '[]'::json);
end;
$$;
revoke all on function public.admin_plantillas_prospeccion(text) from public, anon, authenticated;
grant execute on function public.admin_plantillas_prospeccion(text) to authenticated;

-- OJO: aunque p_segmento tiene default, la lista de TIPOS cambia de 4 a 5 elementos, y para
-- Postgres eso es una firma distinta (create or replace NO la reemplaza, crea un overload
-- nuevo y deja viva la de 4 parámetros con el cuerpo VIEJO — que ya no filtra por segmento y
-- podría actualizar dos plantillas de dos segmentos distintos a la vez si algo la invocara).
-- Misma regla de siempre: dropear antes de recrear.
drop function if exists public.admin_guardar_plantilla(text,smallint,text,text);

create or replace function public.admin_guardar_plantilla(
  p_ruta text, p_etapa smallint, p_asunto text, p_cuerpo_html text, p_segmento text default 'agencias_seguros'
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  update prospecto_plantillas
    set asunto = p_asunto, cuerpo_html = p_cuerpo_html
    where segmento = p_segmento and ruta = p_ruta and etapa = p_etapa;
end;
$$;
revoke all on function public.admin_guardar_plantilla(text,smallint,text,text,text) from public, anon, authenticated;
grant execute on function public.admin_guardar_plantilla(text,smallint,text,text,text) to authenticated;

-- admin_disparar_lote() no cambia de firma (sigue sin parámetros, solo llama a
-- enviar_lote_prospectos() que ahora recorre todos los segmentos activos) — no hace falta tocarla.

-- ============================================================================
-- 7. Comprobación
-- ============================================================================
do $$
declare v_filas int; v_plantillas int;
begin
  select count(*) into v_filas from prospeccion_ajustes;
  if v_filas <> 2 then raise exception 'Se esperaban 2 filas en prospeccion_ajustes (agencias_seguros + escuelas), hay %', v_filas; end if;

  select count(*) into v_plantillas from prospecto_plantillas where segmento='escuelas';
  if v_plantillas <> 3 then raise exception 'Se esperaban 3 plantillas de escuelas, hay %', v_plantillas; end if;

  raise notice 'Correcto: 2 segmentos en prospeccion_ajustes, 3 plantillas nuevas de escuelas.';
end;
$$;
