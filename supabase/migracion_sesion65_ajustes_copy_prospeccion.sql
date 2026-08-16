-- Upco InsurGest — Sesión 65: tres ajustes de copy en prospecto_plantillas
-- Ya aplicados directo en producción; este archivo documenta el cambio para el
-- historial (UPDATE contra el texto exacto anterior — no rompe si ya se corrió).

-- 1. BUG: {DOMINIO_EJEMPLO} nunca se sustituía en enviar_lote_prospectos() (esa
--    función solo resuelve {AGENCIA} y {NOMBRE}) — se mandó tal cual, sin resolver,
--    en 17 correos reales (7 academias, 10 escuelas) antes de encontrarlo.
update prospecto_plantillas
  set asunto = replace(asunto, '{DOMINIO_EJEMPLO}', 'suacademia.mx'),
      cuerpo_html = replace(cuerpo_html, '{DOMINIO_EJEMPLO}', 'suacademia.mx')
  where segmento = 'academias' and ruta = 'web' and etapa = 2;

update prospecto_plantillas
  set asunto = replace(asunto, '{DOMINIO_EJEMPLO}', 'suescuela.mx'),
      cuerpo_html = replace(cuerpo_html, '{DOMINIO_EJEMPLO}', 'suescuela.mx')
  where segmento = 'escuelas' and ruta = 'web' and etapa = 2;

-- 2. Consistencia: agencias_seguros/web era la única de las 4 rutas sin liga a
--    blog en ningún correo. Se agrega al primero, reusando la nota de
--    digitalización del sector asegurador (misma audiencia que InsurGest).
update prospecto_plantillas
set cuerpo_html = replace(
  cuerpo_html,
  '<p style="font-size:12.5px;color:#8593AA;line-height:1.55">Upco — empresa mexicana de tecnología para el sector financiero y asegurador.<br><a href="https://upco.app" style="color:#1f4a80">upco.app</a></p>',
  '<p style="font-size:13px;color:#53647D;margin:0 0 16px">Si quiere ver los datos completos detrás de esto — AMIS, McKinsey, Deloitte, INEGI — <a href="https://insurgest.upco.app/blog/digitalizacion-seguro-mexico/" style="color:#10284A;font-weight:700">los reunimos en una nota</a>.</p>' || chr(10) ||
  '<p style="font-size:12.5px;color:#8593AA;line-height:1.55">Upco — empresa mexicana de tecnología para el sector financiero y asegurador.<br><a href="https://upco.app" style="color:#1f4a80">upco.app</a></p>'
)
where segmento='agencias_seguros' and ruta='web' and etapa=1
  and cuerpo_html not ilike '%/blog/%'; -- idempotente: no duplica si ya se corrió

-- 3. Tono, solo en agencias_seguros/web (el segmento que más le importa al
--    fundador): dos aperturas señalaban una carencia del prospecto en vez de
--    proponer, revirtiendo el criterio ya establecido para el resto de la
--    campaña (ver feedback-copy-proponer-no-senalar). InsurGest ya abría bien
--    en los tres y no se tocó -- es el de mejor desempeño del grupo.
update prospecto_plantillas
set cuerpo_html = replace(
  cuerpo_html,
  '<p style="font-size:19px;font-weight:700;line-height:1.3;margin:0 0 16px;color:#10284A">Su equipo, con el correo de la agencia. No con el de un servicio gratuito.</p>',
  '<p style="font-size:19px;font-weight:700;line-height:1.3;margin:0 0 16px;color:#10284A">Su equipo, con el correo de la agencia — el detalle que ya tienen resuelto las agencias más serias.</p>'
)
where segmento='agencias_seguros' and ruta='web' and etapa=2;

update prospecto_plantillas
set cuerpo_html = replace(
  cuerpo_html,
  '<p style="font-size:19px;font-weight:700;line-height:1.3;margin:0 0 16px;color:#10284A">Cuando alguien busca su agencia en Google, ¿qué encuentra?</p>',
  '<p style="font-size:19px;font-weight:700;line-height:1.3;margin:0 0 16px;color:#10284A">Su agencia, encontrable en Google — sin letras chiquitas.</p>'
)
where segmento='agencias_seguros' and ruta='web' and etapa=3;

-- Comprobación
do $$
declare v_rotos int;
begin
  select count(*) into v_rotos from prospecto_plantillas
    where cuerpo_html ilike '%{DOMINIO_EJEMPLO}%' or asunto ilike '%{DOMINIO_EJEMPLO}%';
  if v_rotos > 0 then raise exception 'Sigue roto: % plantillas con {DOMINIO_EJEMPLO}', v_rotos; end if;
  raise notice 'OK: sin placeholders rotos, blog agregado, tono de agencias/web corregido.';
end;
$$;
