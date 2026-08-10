-- Upco InsurGest — Sesión 49: los 6 correos de prospección, reescritos como piezas de venta
-- Correr con:  ~/bin/pg-insurgest -f supabase/migracion_sesion49_plantillas_venta.sql
--
-- Reemplaza los textos cargados en la Sesión 47. El dueño (mercadólogo) rechazó dos versiones
-- previas y el criterio que quedó es explícito:
--   1. NO es una carta. Nada de "Estimados" ni de despedidas: se abre con la promesa.
--   2. Lenguaje impersonal y abierto, en lugar de dirigirse a alguien en particular.
--   3. Upco se posiciona como empresa de tecnología para el SECTOR FINANCIERO Y ASEGURADOR,
--      no como proveedor "de agentes".
--   4. Un solo llamado a la acción por correo, al final. Nada compite con él.
--   5. Enlace a upco.app en los seis, para que sepan quién les escribe.
-- El texto del pie legal NO vive aquí: se agrega solo desde prospeccion_ajustes.pie_legal.
--
-- Estilos en línea a propósito: los clientes de correo ignoran las hojas de estilo. Se evitan
-- imágenes y se usa un solo botón — entre más maquetado, más probable es que Gmail lo mande a
-- la pestaña Promociones.

-- ============================ RUTA INSURGEST ============================
update prospecto_plantillas set
  asunto = 'La automatización de su cartera de pólizas',
  cuerpo_html = '<p style="font-size:19px;font-weight:700;line-height:1.3;margin:0 0 16px;color:#10284A">La automatización de su cartera, con la herramienta más completa para su agencia y para sus clientes.</p>
<p>Upco InsurGest reúne clientes, pólizas y unidades en un solo sistema, y se hace cargo del seguimiento que hoy consume horas.</p>
<p style="font-size:12px;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:#8593AA;margin:18px 0 8px">Para la agencia</p>
<ul style="margin:0 0 14px;padding-left:20px">
<li style="margin-bottom:6px">Aviso automático de cada póliza próxima a renovar</li>
<li style="margin-bottom:6px">Cartera y producción por agente en un solo tablero</li>
<li style="margin-bottom:6px">Pólizas, endosos, siniestros y documentos en un mismo expediente</li>
</ul>
<p style="font-size:12px;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:#8593AA;margin:18px 0 8px">Para el asegurado</p>
<ul style="margin:0 0 14px;padding-left:20px">
<li style="margin-bottom:6px">Portal privado con sus pólizas y documentos, protegido con NIP</li>
<li style="margin-bottom:6px">Avisos de renovación, verificación vehicular y servicio</li>
<li style="margin-bottom:6px">Todo bajo el nombre de la agencia</li>
</ul>
<p style="background:#F4F6FA;border:1px solid #DDE4EE;border-radius:8px;padding:12px 16px;margin:0 0 18px"><strong>Plan agencia — $999 MXN + IVA al mes</strong>, cinco agentes incluidos.</p>
<p style="margin:0 0 6px"><a href="https://insurgest.upco.app" style="display:inline-block;background:#10284A;color:#ffffff;text-decoration:none;padding:13px 24px;border-radius:9px;font-weight:700">Inicie su prueba de 30 días</a></p>
<p style="font-size:12.5px;color:#8593AA;margin:0 0 16px">Sin tarjeta y sin compromiso.</p>
<p style="font-size:12.5px;color:#8593AA;line-height:1.55">Upco — empresa mexicana de tecnología para el sector financiero y asegurador.<br><a href="https://upco.app" style="color:#1f4a80">upco.app</a></p>'
where ruta = 'insurgest' and etapa = 1;

update prospecto_plantillas set
  asunto = 'Un portal con su marca para cada asegurado',
  cuerpo_html = '<p style="font-size:19px;font-weight:700;line-height:1.3;margin:0 0 16px;color:#10284A">Sus clientes consultan sus pólizas cuando quieren. Con el nombre de su agencia, no con el nuestro.</p>
<p>Cada asegurado recibe un acceso privado protegido con NIP. Desde ahí resuelve solo lo que hoy llega por WhatsApp a media noche:</p>
<ul style="margin:0 0 14px;padding-left:20px">
<li style="margin-bottom:6px">Consulta sus pólizas y descarga sus documentos</li>
<li style="margin-bottom:6px">Solicita endosos y reporta siniestros con fotografías</li>
<li style="margin-bottom:6px">Registra sus vehículos y recibe avisos de verificación y servicio</li>
</ul>
<p>En un mercado que compite por precio, es de los pocos elementos que sostienen la permanencia del cliente.</p>
<p style="margin:18px 0 6px"><a href="https://insurgest.upco.app" style="display:inline-block;background:#10284A;color:#ffffff;text-decoration:none;padding:13px 24px;border-radius:9px;font-weight:700">Inicie su prueba de 30 días</a></p>
<p style="font-size:12.5px;color:#8593AA;margin:0 0 16px">Cargue su cartera real y compruébelo.</p>
<p style="font-size:12.5px;color:#8593AA;line-height:1.55">Upco — empresa mexicana de tecnología para el sector financiero y asegurador.<br><a href="https://upco.app" style="color:#1f4a80">upco.app</a></p>'
where ruta = 'insurgest' and etapa = 2;

update prospecto_plantillas set
  asunto = 'Treinta días para probarlo con su cartera real',
  cuerpo_html = '<p style="font-size:19px;font-weight:700;line-height:1.3;margin:0 0 16px;color:#10284A">Pruébelo con sus pólizas reales. Si no le ahorra trabajo, no cuesta nada.</p>
<p>La prueba no pide tarjeta. Cargue su cartera, deje correr los avisos automáticos una semana y compare contra su seguimiento manual.</p>
<p style="font-size:12px;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:#8593AA;margin:18px 0 8px">Planes vigentes</p>
<ul style="margin:0 0 14px;padding-left:20px">
<li style="margin-bottom:6px">Agencia — $999 MXN + IVA al mes, cinco agentes incluidos</li>
<li style="margin-bottom:6px">Agente adicional — $249 MXN + IVA al mes</li>
<li style="margin-bottom:6px">Agente individual — $299 MXN + IVA al mes</li>
</ul>
<p style="margin:18px 0 16px"><a href="https://insurgest.upco.app" style="display:inline-block;background:#10284A;color:#ffffff;text-decoration:none;padding:13px 24px;border-radius:9px;font-weight:700">Inicie su prueba hoy</a></p>
<p style="font-size:12.5px;color:#8593AA;line-height:1.55">Upco — empresa mexicana de tecnología para el sector financiero y asegurador.<br><a href="https://upco.app" style="color:#1f4a80">upco.app</a></p>'
where ruta = 'insurgest' and etapa = 3;

-- ============================ RUTA UPCO WEB ============================
-- Las características listadas son las reales del plan Arranque, tomadas de web.upco.app.
update prospecto_plantillas set
  asunto = 'El sitio web de su agencia, listo en días',
  cuerpo_html = '<p style="font-size:19px;font-weight:700;line-height:1.3;margin:0 0 16px;color:#10284A">La presencia digital de su agencia, resuelta de principio a fin.</p>
<p>Dominio, sitio y correos corporativos en un solo paquete. Sin proveedores separados y sin esperar meses.</p>
<p style="font-size:12px;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:#8593AA;margin:18px 0 8px">Incluye</p>
<ul style="margin:0 0 14px;padding-left:20px">
<li style="margin-bottom:6px">Sitio de una página con plantilla de marca</li>
<li style="margin-bottom:6px">Dominio .com o .com.mx, primer año incluido</li>
<li style="margin-bottom:6px">Dos correos profesionales con el nombre de su agencia</li>
<li style="margin-bottom:6px">Formulario de contacto y enlace a sus redes</li>
<li style="margin-bottom:6px">SEO básico y certificado de seguridad</li>
</ul>
<p style="background:#F4F6FA;border:1px solid #DDE4EE;border-radius:8px;padding:12px 16px;margin:0 0 18px"><strong>Desde $1,800 MXN + IVA al año.</strong> Entrega en días, no en meses.</p>
<p style="margin:0 0 16px"><a href="https://web.upco.app" style="display:inline-block;background:#10284A;color:#ffffff;text-decoration:none;padding:13px 24px;border-radius:9px;font-weight:700">Conozca los planes</a></p>
<p style="font-size:12.5px;color:#8593AA;line-height:1.55">Upco — empresa mexicana de tecnología para el sector financiero y asegurador.<br><a href="https://upco.app" style="color:#1f4a80">upco.app</a></p>'
where ruta = 'web' and etapa = 1;

update prospecto_plantillas set
  asunto = 'Dos correos con el nombre de su agencia, incluidos',
  cuerpo_html = '<p style="font-size:19px;font-weight:700;line-height:1.3;margin:0 0 16px;color:#10284A">Su equipo, con el correo de la agencia. No con el de un servicio gratuito.</p>
<p>El paquete incluye dos cuentas con el dominio de su agencia, listas para la papelería, la firma y cada cotización que emiten. Sin costo aparte del sitio.</p>
<p>Es el detalle que hace que una agencia autorizada se lea como una casa con equipo detrás.</p>
<p style="background:#F4F6FA;border:1px solid #DDE4EE;border-radius:8px;padding:12px 16px;margin:18px 0">Le confirmamos el mismo día qué dominio está disponible con el nombre de su agencia. Solo responda este correo con el nombre.</p>
<p style="margin:0 0 16px"><a href="https://web.upco.app" style="display:inline-block;background:#10284A;color:#ffffff;text-decoration:none;padding:13px 24px;border-radius:9px;font-weight:700">Conozca los planes</a></p>
<p style="font-size:12.5px;color:#8593AA;line-height:1.55">Upco — empresa mexicana de tecnología para el sector financiero y asegurador.<br><a href="https://upco.app" style="color:#1f4a80">upco.app</a></p>'
where ruta = 'web' and etapa = 2;

update prospecto_plantillas set
  asunto = 'Su agencia en internet, desde $1,800 al año',
  cuerpo_html = '<p style="font-size:19px;font-weight:700;line-height:1.3;margin:0 0 16px;color:#10284A">Cuando alguien busca su agencia en Google, ¿qué encuentra?</p>
<p>Dominio, sitio, correos corporativos y certificado de seguridad, desde $1,800 MXN + IVA al año, con entrega en días.</p>
<p>Y si además administra cartera, <strong>Upco InsurGest</strong> automatiza el seguimiento de vencimientos de sus pólizas, con treinta días de prueba sin tarjeta.</p>
<p style="margin:18px 0 16px"><a href="https://web.upco.app" style="display:inline-block;background:#10284A;color:#ffffff;text-decoration:none;padding:13px 24px;border-radius:9px;font-weight:700">Conozca los planes</a></p>
<p style="font-size:12.5px;color:#8593AA;line-height:1.55">Upco — empresa mexicana de tecnología para el sector financiero y asegurador.<br><a href="https://upco.app" style="color:#1f4a80">upco.app</a> · <a href="https://insurgest.upco.app" style="color:#1f4a80">insurgest.upco.app</a></p>'
where ruta = 'web' and etapa = 3;

-- Comprobación: las 6 deben haber quedado con el formato nuevo.
do $$
declare v_mal int;
begin
  select count(*) into v_mal from prospecto_plantillas
  where cuerpo_html not like '%font-size:19px%'      -- el titular que abre cada pieza
     or cuerpo_html not like '%upco.app%'            -- el enlace corporativo
     or cuerpo_html like '%Estimados%'               -- resabio de la versión carta
     or cuerpo_html like '%Buen día%';
  if v_mal > 0 then
    raise exception 'Quedaron % plantillas sin el formato nuevo', v_mal;
  end if;
  raise notice 'Correcto: las 6 plantillas tienen titular, enlace a upco.app y ningún saludo de carta.';
end;
$$;
