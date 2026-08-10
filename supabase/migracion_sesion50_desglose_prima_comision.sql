-- Upco InsurGest — Sesión 50: desglose de la prima y comisión del agente
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- POR QUÉ: hasta ahora `polizas.prima` era un solo campo libre etiquetado "Prima total".
-- Nada obligaba a que significara lo mismo en todas las pólizas (unos capturaban la neta,
-- otros el total con IVA), así que el KPI del dashboard sumaba cifras no comparables. Y sobre
-- todo: de ese número NO se puede sacar la comisión, porque la comisión se paga sobre la
-- PRIMA NETA — nunca sobre el IVA ni sobre los derechos de póliza. Separar los campos es el
-- requisito previo para calcular comisiones bien.
--
-- Los impuestos se capturan a mano a propósito: el IVA no es parejo entre ramos (los seguros
-- de vida están exentos por el Art. 15-IX de la Ley del IVA, los de auto sí lo causan), así
-- que calcularlo automático al 16% estaría mal justo en las pólizas de Vida. Lo que sí se
-- calcula solo es la comisión.

alter table polizas add column if not exists prima_neta numeric(12,2);
alter table polizas add column if not exists derechos numeric(12,2);
alter table polizas add column if not exists iva numeric(12,2);

-- Porcentaje de comisión de ESTA póliza. Nulo = el agente no lleva control de comisión aquí,
-- y entonces la póliza simplemente no cuenta en los totales de comisión (no se asume cero).
-- Se guarda por póliza y no por agente porque el porcentaje varía muchísimo por ramo: auto
-- ronda 10% (8% en carga), pero Vida va de 20% a 70% según la aseguradora y el año.
alter table polizas add column if not exists comision_pct numeric(5,2)
  check (comision_pct is null or (comision_pct >= 0 and comision_pct <= 100));

-- Columna generada: el monto nunca se guarda a mano, se deriva. Así no puede quedar
-- desfasado si alguien edita la prima neta o el porcentaje después.
alter table polizas drop column if exists comision_monto;
alter table polizas add column comision_monto numeric(12,2)
  generated always as (
    case when prima_neta is not null and comision_pct is not null
      then round(prima_neta * comision_pct / 100, 2)
    end
  ) stored;

comment on column polizas.prima is 'Gran total que paga el cliente (neta + derechos + IVA + recargos si los hubiera). Es el campo que ya existía.';
comment on column polizas.prima_neta is 'Prima neta, sin impuestos ni derechos. Es la base sobre la que se calcula la comisión.';
comment on column polizas.comision_pct is 'Porcentaje de comisión del agente en esta póliza. Nulo = no se lleva control.';
comment on column polizas.comision_monto is 'Derivada: prima_neta * comision_pct / 100. No se captura.';
