-- Upco InsurGest — Sesión 58: agrega la liga del blog de digitalización educativa al primer
-- correo de la campaña de escuelas.
-- Correr con: pg-insurgest -f supabase/migracion_sesion58_liga_blog_escuelas.sql
--
-- Mismo criterio que la Sesión 57 (blog de InsurGest → correo de agencias_seguros/insurgest):
-- solo la etapa 1 (el correo que de verdad funciona como invitación), como enlace secundario
-- que no compite con el CTA principal ("Ver el sitio de muestra"). El blog vive en Upco WEB
-- (web.upco.app/blog/), no en este dominio, pero la plantilla vive en esta base porque toda
-- la máquina de prospección corre aquí.

update prospecto_plantillas
set cuerpo_html = replace(
  cuerpo_html,
  '<p>Dominio, hospedaje, desarrollo y correos profesionales del plantel, desde $1,800 MXN + IVA al año, listo en días.</p>',
  '<p>Dominio, hospedaje, desarrollo y correos profesionales del plantel, desde $1,800 MXN + IVA al año, listo en días.</p>' || chr(10) ||
  '<p style="font-size:13px;color:#53647D;margin:0 0 16px">Si le interesan los datos completos detrás de esto — revisamos casi 6,000 escuelas en el DENUE del INEGI — <a href="https://web.upco.app/blog/digitalizacion-educacion-mexico/" style="color:#10284A;font-weight:700">los reunimos en una nota</a>.</p>'
)
where segmento = 'escuelas' and ruta = 'web' and etapa = 1;

do $$
declare v_ok boolean;
begin
  select cuerpo_html like '%digitalizacion-educacion-mexico%' into v_ok
  from prospecto_plantillas where segmento='escuelas' and ruta='web' and etapa=1;
  if not v_ok then raise exception 'La liga del blog no quedó insertada en el correo 1 de escuelas'; end if;
  raise notice 'Correcto: liga del blog agregada al correo 1 de escuelas.';
end;
$$;
