-- Upco InsurGest — Sesión 57: agrega la liga del blog al primer correo de prospección
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- Solo toca la plantilla de InsurGest para agencias de seguros (segmento agencias_seguros,
-- ruta insurgest, etapa 1 — el primer correo de la secuencia, el que de verdad funciona como
-- invitación). No se tocan las plantillas de Upco WEB ni las de escuelas/academias: el blog
-- es de InsurGest y no aplica a esos prospectos. Tampoco se agrega a las etapas 2 y 3 a
-- propósito — son correos de refuerzo y cierre con un solo CTA (probar gratis), y un enlace
-- secundario ahí compite con ese CTA en vez de reforzarlo.

update prospecto_plantillas
set cuerpo_html = replace(
  cuerpo_html,
  '<p style="font-size:12.5px;color:#8593AA;margin:0 0 16px">Sin tarjeta y sin compromiso.</p>',
  '<p style="font-size:12.5px;color:#8593AA;margin:0 0 16px">Sin tarjeta y sin compromiso.</p>' || chr(10) ||
  '<p style="font-size:13px;color:#53647D;margin:0 0 16px">Si quiere ver los datos completos detrás de esto — AMIS, McKinsey, Deloitte, INEGI — <a href="https://insurgest.upco.app/blog/digitalizacion-seguro-mexico/" style="color:#10284A;font-weight:700">los reunimos en una nota</a>.</p>'
)
where segmento = 'agencias_seguros' and ruta = 'insurgest' and etapa = 1;
