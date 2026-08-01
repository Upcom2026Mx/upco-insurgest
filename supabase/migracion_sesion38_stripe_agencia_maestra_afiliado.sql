-- Upco InsurGest — Sesión 38: campos de Stripe para Agencia Máster + precios de Agente afiliado
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- Agencia Máster nunca tuvo columnas de Stripe (se construyó primero el portal/residual, el
-- cobro se dejó pendiente a propósito). "Agente afiliado" es la tarifa de $249 para el agente
-- 6+ de una promotoría — el que paga es el propio agente (crea su cuenta y se afilia con el
-- código de la promotoría o de una asociación como AMASFAC), no la promotoría — por eso usa la
-- misma tabla `agentes` y el mismo Customer que ya tiene, solo con un precio distinto.

alter table agencias_maestras add column stripe_customer_id text;
alter table agencias_maestras add column stripe_subscription_id text;
alter table agencias_maestras add column estatus_suscripcion text;
alter table agencias_maestras add column plan_periodo text;
alter table agencias_maestras add column suscripcion_vigente_hasta timestamptz;
alter table agencias_maestras add column acceso_extendido_hasta timestamptz;

alter table stripe_precios drop constraint stripe_precios_tipo_check;
alter table stripe_precios add constraint stripe_precios_tipo_check
  check (tipo = any (array['agente','agente_afiliado','promotoria_base','agencia_maestra']));

insert into stripe_precios(tipo,periodo,price_id) values
  ('agencia_maestra','mensual','price_1Tzjw8PwWmIjubgwsNAYebvb'),
  ('agencia_maestra','trimestral','price_1Tzk0PPwWmIjubgwNTTT8dHR'),
  ('agencia_maestra','semestral','price_1Tzk25PwWmIjubgwxpZyZNLD'),
  ('agencia_maestra','anual','price_1Tzk4MPwWmIjubgwJKpSNOv6'),
  ('agente_afiliado','mensual','price_1TzjfFPwWmIjubgw3Z1YfNLy'),
  ('agente_afiliado','trimestral','price_1TzjgyPwWmIjubgwZsvRt8Dr'),
  ('agente_afiliado','semestral','price_1TzjiTPwWmIjubgwsTblaxJT'),
  ('agente_afiliado','anual','price_1TzjnkPwWmIjubgwGeg13qp3')
on conflict (tipo,periodo) do update set price_id = excluded.price_id;
