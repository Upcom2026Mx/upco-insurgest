-- Upco InsurGest — Sesión 70: migra las 4 cuentas semilla de Agente Libre a la tabla correcta
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- Las cuentas "Agente Libre 01-04" se crearon (en otra conversación, antes de la Sesión 69)
-- como filas de `promotorias` — el único modelo que existía entonces. Bajo ese modelo,
-- mientras durara su propio periodo de prueba de 30 días, técnicamente podían darle acceso
-- gratis a sus primeros 5 agentes, justo lo contrario de lo que debe hacer un Agente Libre.
-- Se migran a `agentes_libres` (tabla nueva de la Sesión 69) conservando exactamente el mismo
-- id (mismo login), correo y código de invitación — nada cambia para quien reciba la liga.
-- Confirmado con el usuario antes de correr esto: ninguno de los 4 códigos se ha compartido
-- todavía con una persona real, y no hay ningún agente/cliente/solicitud ligado a estas 4
-- filas (verificado por SQL).

insert into agentes_libres (
  id, correo, nombre, nombre_negocio, rfc, codigo_invitacion,
  estatus_aprobacion, acepto_terminos, acepto_terminos_version, acepto_terminos_fecha,
  created_at, aprobado_en
)
select
  id, correo, nombre, nombre_negocio, rfc, codigo_invitacion,
  estatus_aprobacion, acepto_terminos, acepto_terminos_version, acepto_terminos_fecha,
  created_at, aprobado_en
from promotorias
where nombre_negocio ilike 'Agente Libre%';

delete from promotorias where nombre_negocio ilike 'Agente Libre%';
