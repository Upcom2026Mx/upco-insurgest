-- Upco InsurGest — Sesión 52: reescribe los 3 correos de escuelas con enfoque de venta real
-- Correr con: pg-insurgest -f supabase/migracion_sesion52_copy_venta_escuelas.sql
--
-- Motivo: el copy de la Sesión 51 vendía el sitio de muestra ("véalo funcionando") pero no
-- el BENEFICIO real de tener un sitio: nueva matrícula, presencia/estatus, y comunicación
-- clara de la propuesta educativa. El dueño lo pidió explícito el 2026-08-10.
--
-- Mismo criterio de estilo que la Sesión 49 (agencias): titular directo sin saludo de carta,
-- un solo llamado a la acción, estilos en línea.

update prospecto_plantillas set
  asunto = 'Cuando una familia busca escuela, ¿lo encuentra a usted o a la competencia?',
  cuerpo_html = '<p style="font-size:19px;font-weight:700;line-height:1.3;margin:0 0 16px;color:#10284A">Cada ciclo escolar, familias deciden dónde inscribir a sus hijos buscando primero en Google. Si {NOMBRE} no aparece ahí con información clara, esa familia ya eligió otro plantel sin que usted se enterara.</p>
<p>Le armamos un sitio de muestra con el nombre de {NOMBRE} para que vea exactamente lo que puede tener — no descrito, funcionando.</p>
<p style="font-size:12px;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:#8593AA;margin:18px 0 8px">Lo que un sitio propio le puede traer</p>
<ul style="margin:0 0 14px;padding-left:20px">
<li style="margin-bottom:6px"><b>Más solicitudes de informes e inscripción</b>, todo el año — no solo cuando alguien ve un anuncio</li>
<li style="margin-bottom:6px"><b>Presencia y prestigio</b>: un plantel serio se ve serio también en internet, y eso lo notan tanto los papás nuevos como los que ya están</li>
<li style="margin-bottom:6px"><b>Comunicación clara</b> de sus niveles, su método educativo y su proceso de admisión — sin depender de que alguien conteste el WhatsApp a tiempo</li>
</ul>
<p style="background:#F4F6FA;border:1px solid #DDE4EE;border-radius:8px;padding:12px 16px;margin:0 0 18px">Vea el ejemplo real, con el mismo tipo de secciones que tendría el sitio de {NOMBRE}:</p>
<p style="margin:0 0 16px"><a href="https://web.upco.app/demos/escuelas/" style="display:inline-block;background:#10284A;color:#ffffff;text-decoration:none;padding:13px 24px;border-radius:9px;font-weight:700">Ver el sitio de muestra</a></p>
<p>Dominio, hospedaje, desarrollo y correos profesionales del plantel, desde $1,800 MXN + IVA al año, listo en días.</p>
<p style="font-size:12.5px;color:#8593AA;line-height:1.55">Upco — empresa mexicana de tecnología.<br><a href="https://upco.app" style="color:#1f4a80">upco.app</a> · <a href="https://web.upco.app" style="color:#1f4a80">web.upco.app</a></p>'
where segmento = 'escuelas' and ruta = 'web' and etapa = 1;

update prospecto_plantillas set
  asunto = 'Lo que un correo con el nombre de su plantel dice de {NOMBRE}, antes de que alguien lea una palabra',
  cuerpo_html = '<p style="font-size:19px;font-weight:700;line-height:1.3;margin:0 0 16px;color:#10284A">Cuando una familia recibe un correo de contacto@{DOMINIO_EJEMPLO}, no de un Gmail, ya empezó a confiar en {NOMBRE} antes de leer una palabra.</p>
<p>Le escribimos hace unos días sobre el sitio de muestra. Hoy la parte que a los planteles termina de convencer: los correos profesionales van incluidos en el mismo paquete, sin costo aparte.</p>
<p style="font-size:12px;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:#8593AA;margin:18px 0 8px">Lo que esto resuelve de verdad</p>
<ul style="margin:0 0 14px;padding-left:20px">
<li style="margin-bottom:6px">Un sitio con la información que buscan los padres antes de agendar una visita</li>
<li style="margin-bottom:6px">Formulario de contacto e inscripción, para no perder a nadie por falta de respuesta a tiempo</li>
<li style="margin-bottom:6px">Correos profesionales para dirección, administración e inscripciones — misma imagen para todo el equipo</li>
</ul>
<p>Es la diferencia entre parecer un plantel de paso y parecer una institución que va a seguir ahí el próximo ciclo — que es justo lo que una familia quiere ver antes de inscribir a su hijo o hija por varios años.</p>
<p style="margin:0 0 16px"><a href="https://web.upco.app/demos/escuelas/" style="display:inline-block;background:#10284A;color:#ffffff;text-decoration:none;padding:13px 24px;border-radius:9px;font-weight:700">Ver el sitio de muestra</a></p>
<p style="font-size:12.5px;color:#8593AA;line-height:1.55">Upco — empresa mexicana de tecnología.<br><a href="https://upco.app" style="color:#1f4a80">upco.app</a> · <a href="https://web.upco.app" style="color:#1f4a80">web.upco.app</a></p>'
where segmento = 'escuelas' and ruta = 'web' and etapa = 2;

update prospecto_plantillas set
  asunto = 'Último correo — la matrícula del próximo ciclo se decide antes de que empiece',
  cuerpo_html = '<p style="font-size:19px;font-weight:700;line-height:1.3;margin:0 0 16px;color:#10284A">Último correo, no queremos llenarle la bandeja.</p>
<p>Las familias que van a inscribir a sus hijos el próximo ciclo ya están buscando escuela ahora, meses antes de que empiecen las clases. Cada mes sin presencia clara en internet es matrícula que se va con quien sí la tiene.</p>
<p>Si en algún momento le interesa, el sitio de muestra sigue disponible y los planes no cambian: desde $1,800 MXN + IVA al año, con entrega en días.</p>
<p style="margin:0 0 16px"><a href="https://web.upco.app/demos/escuelas/" style="display:inline-block;background:#10284A;color:#ffffff;text-decoration:none;padding:13px 24px;border-radius:9px;font-weight:700">Ver el sitio de muestra</a></p>
<p>Gracias por su tiempo, y mucho éxito con el ciclo escolar.</p>
<p style="font-size:12.5px;color:#8593AA;line-height:1.55">Upco — empresa mexicana de tecnología.<br><a href="https://upco.app" style="color:#1f4a80">upco.app</a></p>'
where segmento = 'escuelas' and ruta = 'web' and etapa = 3;

do $$
declare v_mal int;
begin
  select count(*) into v_mal from prospecto_plantillas
  where segmento = 'escuelas'
    and (cuerpo_html not like '%font-size:19px%' or cuerpo_html not like '%upco.app%');
  if v_mal > 0 then raise exception 'Quedaron % plantillas de escuelas sin el formato nuevo', v_mal; end if;
  raise notice 'Correcto: las 3 plantillas de escuelas tienen el copy de venta nuevo.';
end;
$$;
