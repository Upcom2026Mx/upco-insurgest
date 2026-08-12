-- Upco InsurGest — Sesión 62: agrega la liga del blog también al segundo correo de prospección
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- Continúa lo de la Sesión 57: misma plantilla (agencias_seguros / insurgest), ahora en la
-- etapa 2. Sigue sin tocar Upco WEB, escuelas/academias ni la etapa 3 (cierre con un solo CTA).

update prospecto_plantillas
set cuerpo_html = replace(
  cuerpo_html,
  '<p style="font-size:12.5px;color:#8593AA;margin:0 0 16px">Cargue su cartera real y compruébelo.</p>',
  '<p style="font-size:12.5px;color:#8593AA;margin:0 0 16px">Cargue su cartera real y compruébelo.</p>' || chr(10) ||
  '<p style="font-size:13px;color:#53647D;margin:0 0 16px">Si quiere ver los datos completos detrás de esto — AMIS, McKinsey, Deloitte, INEGI — <a href="https://insurgest.upco.app/blog/digitalizacion-seguro-mexico/" style="color:#10284A;font-weight:700">los reunimos en una nota</a>.</p>'
)
where segmento = 'agencias_seguros' and ruta = 'insurgest' and etapa = 2;
