-- Upco InsurGest — Sesión 59: agrega la liga del blog de digitalización educativa al primer
-- correo de la campaña de academias.
-- Correr con: pg-insurgest -f supabase/migracion_sesion59_liga_blog_academias.sql
--
-- El usuario pidió la liga en las DOS campañas de la máquina de Upco WEB (escuelas ya la
-- tiene desde la Sesión 58). El texto se redacta genérico a propósito ("instituciones
-- educativas", no "escuelas"): el artículo analiza datos de escuelas formales (preescolar a
-- prepa), pero el argumento de fondo — familias que buscan en internet, brecha de sitio web,
-- inscripciones que se van con quien sí aparece — aplica igual a una academia de natación,
-- de idiomas o de arte.

update prospecto_plantillas
set cuerpo_html = replace(
  cuerpo_html,
  '<p>Dominio, hospedaje, desarrollo y correo profesional, desde $1,800 MXN + IVA al año, listo en días.</p>',
  '<p>Dominio, hospedaje, desarrollo y correo profesional, desde $1,800 MXN + IVA al año, listo en días.</p>' || chr(10) ||
  '<p style="font-size:13px;color:#53647D;margin:0 0 16px">Si le interesan los datos detrás de esto — revisamos casi 6,000 instituciones educativas en el DENUE del INEGI — <a href="https://web.upco.app/blog/digitalizacion-educacion-mexico/" style="color:#10284A;font-weight:700">los reunimos en una nota</a>.</p>'
)
where segmento = 'academias' and ruta = 'web' and etapa = 1;

do $$
declare v_ok boolean;
begin
  select cuerpo_html like '%digitalizacion-educacion-mexico%' into v_ok
  from prospecto_plantillas where segmento='academias' and ruta='web' and etapa=1;
  if not v_ok then raise exception 'La liga del blog no quedó insertada en el correo 1 de academias'; end if;
  raise notice 'Correcto: liga del blog agregada al correo 1 de academias.';
end;
$$;
