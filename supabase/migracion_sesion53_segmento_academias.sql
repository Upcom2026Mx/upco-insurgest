-- Upco InsurGest — Sesión 53: tercer segmento de la máquina de prospección: academias
-- (escuelas de deporte, arte, idiomas y oficios — fuente DENUE, rama 6116/6114 del sector 61).
-- Correr con: pg-insurgest -f supabase/migracion_sesion53_segmento_academias.sql
--
-- Origen: el usuario notó que el importador de escuelas (Sesión 51) descarta ~8,800 registros
-- del sector 61 por no ser preescolar/primaria/secundaria/media superior/superior — y that "otro"
-- es en realidad un mercado real: academias de deporte, arte, idiomas y oficios. Reconocimiento
-- de datos (2026-08-10, 4 estados): 2,561 deporte / 1,951 arte / 1,226 oficios / 779 idiomas,
-- con correo real ~1,589 en conjunto, 87% sin sitio web. Se excluye a propósito "Servicios de
-- profesores particulares" (1,698): son personas físicas sueltas, no instituciones, y el pitch
-- de "sitio institucional" no les calza igual.
--
-- Misma regla de siempre: toda función cuya lista de parámetros cambia se DROPEA antes de
-- recrearse.

-- ============================================================================
-- 1. Nueva columna genérica: categoria (no reutiliza nivel_educativo, que es semánticamente
--    propio de escuelas — categoria sirve para cualquier segmento futuro: deporte/arte/
--    idiomas/oficios hoy, lo que sea mañana).
-- ============================================================================
alter table prospectos add column categoria text;

-- ============================================================================
-- 2. Ampliar los 3 check constraints de segmento
-- ============================================================================
alter table prospectos drop constraint prospectos_segmento_check;
alter table prospectos add constraint prospectos_segmento_check
  check (segmento in ('agencias_seguros','escuelas','academias'));

alter table prospecto_plantillas drop constraint prospecto_plantillas_segmento_check;
alter table prospecto_plantillas add constraint prospecto_plantillas_segmento_check
  check (segmento in ('agencias_seguros','escuelas','academias'));

alter table prospeccion_ajustes drop constraint prospeccion_ajustes_segmento_check;
alter table prospeccion_ajustes add constraint prospeccion_ajustes_segmento_check
  check (segmento in ('agencias_seguros','escuelas','academias'));

-- ============================================================================
-- 3. Ajustes de campaña para academias (arranca apagada, como los otros dos en su momento)
-- ============================================================================
insert into prospeccion_ajustes(
  segmento, activa, envios_por_dia, corridas_por_dia, dias_a_seguimiento, dias_a_cierre,
  remitente, responder_a, pie_legal
) values (
  'academias', false, 20, 10, 4, 5,
  'Upco <hola@theupgradecompany.mx>', 'hola@upco.app',
  'Le escribimos a esta dirección porque aparece publicada en el Directorio Estadístico Nacional de Unidades Económicas (DENUE) del INEGI, de acceso público. Para dejar de recibir correos, responda "BAJA".<br>Upco · <a href="https://web.upco.app/terminos/" style="color:#8593AA">Aviso de privacidad</a>'
);

-- ============================================================================
-- 4. Los 3 correos de academias — copy genérico, funciona igual para una academia de
--    natación, de idiomas, de arte o de oficios: clases, instructores, horarios, reservar
--    una clase de prueba. Nada específico a una disciplina, para no sonar desconectado de
--    quien lo reciba.
-- ============================================================================
insert into prospecto_plantillas(segmento, ruta, etapa, asunto, cuerpo_html) values
('academias','web',1,
 'Así se vería el sitio de {NOMBRE}',
 '<p style="font-size:19px;font-weight:700;line-height:1.3;margin:0 0 16px;color:#10284A">Cuando alguien busca dónde inscribirse a clases, ¿lo encuentra a usted o a quien sí tiene sitio web?</p>
<p>Somos Upco, empresa mexicana de tecnología. Le armamos un sitio de muestra con el nombre de {NOMBRE} para que vea exactamente lo que puede tener: sus niveles, sus horarios, sus instructores, y una forma directa de reservar una clase de prueba — sin depender de que alguien conteste el WhatsApp a tiempo.</p>
<p style="background:#F4F6FA;border:1px solid #DDE4EE;border-radius:8px;padding:12px 16px;margin:0 0 18px">Vea el ejemplo real, con el mismo tipo de secciones que tendría el de {NOMBRE}:</p>
<p style="margin:0 0 16px"><a href="https://web.upco.app/demos/academias/" style="display:inline-block;background:#10284A;color:#ffffff;text-decoration:none;padding:13px 24px;border-radius:9px;font-weight:700">Ver el sitio de muestra</a></p>
<p>Dominio, hospedaje, desarrollo y correo profesional, desde $1,800 MXN + IVA al año, listo en días.</p>
<p style="font-size:12.5px;color:#8593AA;line-height:1.55">Upco — empresa mexicana de tecnología.<br><a href="https://upco.app" style="color:#1f4a80">upco.app</a> · <a href="https://web.upco.app" style="color:#1f4a80">web.upco.app</a></p>'),

('academias','web',2,
 'Correos con el nombre de {NOMBRE}, no con Gmail o Hotmail',
 '<p style="font-size:19px;font-weight:700;line-height:1.3;margin:0 0 16px;color:#10284A">Cuando alguien recibe un correo de contacto@{DOMINIO_EJEMPLO}, ya confía más en {NOMBRE} antes de leer una palabra.</p>
<p>Le escribimos hace unos días sobre el sitio de muestra. La parte que termina de convencer: los correos profesionales van incluidos, sin costo aparte.</p>
<ul style="margin:0 0 14px;padding-left:20px">
<li style="margin-bottom:6px">Un sitio con horarios, niveles e instructores claros — antes de que alguien pregunte por WhatsApp</li>
<li style="margin-bottom:6px">Formulario para reservar una clase de prueba, disponible las 24 horas</li>
<li style="margin-bottom:6px">Correos profesionales para inscripciones y administración</li>
</ul>
<p>Es la diferencia entre parecer un negocio de paso y parecer una academia seria, que es justo lo que alguien quiere ver antes de inscribirse por varios meses.</p>
<p style="margin:0 0 16px"><a href="https://web.upco.app/demos/academias/" style="display:inline-block;background:#10284A;color:#ffffff;text-decoration:none;padding:13px 24px;border-radius:9px;font-weight:700">Ver el sitio de muestra</a></p>
<p style="font-size:12.5px;color:#8593AA;line-height:1.55">Upco — empresa mexicana de tecnología.<br><a href="https://upco.app" style="color:#1f4a80">upco.app</a> · <a href="https://web.upco.app" style="color:#1f4a80">web.upco.app</a></p>'),

('academias','web',3,
 'Último correo sobre el sitio de {NOMBRE}',
 '<p style="font-size:19px;font-weight:700;line-height:1.3;margin:0 0 16px;color:#10284A">Último correo, no queremos llenarle la bandeja.</p>
<p>Cada mes sin presencia clara en internet son alumnos nuevos que se inscriben con quien sí la tiene. Si en algún momento le interesa, el sitio de muestra sigue disponible y los planes no cambian: desde $1,800 MXN + IVA al año, con entrega en días.</p>
<p style="margin:0 0 16px"><a href="https://web.upco.app/demos/academias/" style="display:inline-block;background:#10284A;color:#ffffff;text-decoration:none;padding:13px 24px;border-radius:9px;font-weight:700">Ver el sitio de muestra</a></p>
<p>Gracias por su tiempo, y mucho éxito con {NOMBRE}.</p>
<p style="font-size:12.5px;color:#8593AA;line-height:1.55">Upco — empresa mexicana de tecnología.<br><a href="https://upco.app" style="color:#1f4a80">upco.app</a></p>');

-- ============================================================================
-- 5. admin_importar_prospectos: rama para academias (igual que escuelas: ruta siempre 'web',
--    y ahora también lee categoria genérica)
-- ============================================================================
drop function if exists public.admin_importar_prospectos(jsonb,text);

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
  v_categoria text;
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  if p_segmento not in ('agencias_seguros','escuelas','academias') then raise exception 'Segmento no válido'; end if;

  for r in select * from jsonb_array_elements(p_filas)
  loop
    v_correo := lower(trim(coalesce(r->>'correo','')));

    if v_correo !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
       or coalesce(trim(r->>'agencia'),'') = '' then
      v_invalidos := v_invalidos + 1;
      continue;
    end if;

    v_nivel := null;
    v_categoria := null;

    if p_segmento = 'escuelas' then
      v_ruta := 'web';
      v_nivel := nullif(trim(coalesce(r->>'nivel_educativo','')),'');
      if v_nivel is not null and v_nivel not in ('preescolar','primaria','secundaria','media_superior','superior','otro') then
        v_nivel := 'otro';
      end if;
    elsif p_segmento = 'academias' then
      v_ruta := 'web';
      v_categoria := nullif(trim(coalesce(r->>'categoria','')),'');
    else
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
    end if;

    insert into prospectos(
      agencia, correo, dominio, ruta, estado, cp, ciudad,
      segmento, nivel_educativo, tiene_sitio_web, sitio_web_actual, fuente, categoria
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
      case when p_segmento in ('escuelas','academias') then 'denue' else 'cnsf' end,
      v_categoria
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
-- 6. admin_prospeccion_resumen: agrega desglose por_categoria (paralelo a por_nivel)
-- ============================================================================
drop function if exists public.admin_prospeccion_resumen(text);

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
    'por_categoria', (select coalesce(json_agg(x),'[]'::json) from (
        select coalesce(categoria,'Sin clasificar') as categoria, count(*) as total from prospectos
        where segmento = p_segmento group by categoria order by total desc) x),
    'correos_enviados', (select count(*) from prospecto_eventos e join prospectos pr on pr.id=e.prospecto_id where e.tipo='enviado' and pr.segmento = p_segmento),
    'enviados_hoy', (select count(*) from prospecto_eventos e join prospectos pr on pr.id=e.prospecto_id where e.tipo='enviado' and e.ocurrio_en >= v_inicio_dia and pr.segmento = p_segmento),
    'abrieron', (select count(distinct e.prospecto_id) from prospecto_eventos e join prospectos pr on pr.id=e.prospecto_id where e.tipo='abierto' and pr.segmento = p_segmento),
    'clicaron', (select count(distinct e.prospecto_id) from prospecto_eventos e join prospectos pr on pr.id=e.prospecto_id where e.tipo='clic' and pr.segmento = p_segmento)
  );
end;
$$;
revoke all on function public.admin_prospeccion_resumen(text) from public, anon, authenticated;
grant execute on function public.admin_prospeccion_resumen(text) to authenticated;

-- ============================================================================
-- 7. Comprobación
-- ============================================================================
do $$
declare v_filas int; v_plantillas int;
begin
  select count(*) into v_filas from prospeccion_ajustes where segmento='academias';
  if v_filas <> 1 then raise exception 'Se esperaba 1 fila de ajustes para academias, hay %', v_filas; end if;

  select count(*) into v_plantillas from prospecto_plantillas where segmento='academias';
  if v_plantillas <> 3 then raise exception 'Se esperaban 3 plantillas de academias, hay %', v_plantillas; end if;

  raise notice 'Correcto: segmento academias listo (ajustes + 3 plantillas + categoria + resumen).';
end;
$$;
