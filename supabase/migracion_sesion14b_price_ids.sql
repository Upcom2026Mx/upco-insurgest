-- Upco InsurGest — Llenar los price_id reales de Stripe en stripe_precios
-- Pegar completo en Supabase > SQL Editor > New query > Run

UPDATE stripe_precios SET price_id = 'price_1TttpCPwWmIjubgwL4Dn24Hk' WHERE tipo = 'agente' AND periodo = 'mensual';
UPDATE stripe_precios SET price_id = 'price_1TttzOPwWmIjubgwvkUwBfJ9' WHERE tipo = 'agente' AND periodo = 'trimestral';
UPDATE stripe_precios SET price_id = 'price_1Ttu24PwWmIjubgwdkIpe9np' WHERE tipo = 'agente' AND periodo = 'semestral';
UPDATE stripe_precios SET price_id = 'price_1Ttu4QPwWmIjubgwXouXGMOR' WHERE tipo = 'agente' AND periodo = 'anual';

UPDATE stripe_precios SET price_id = 'price_1Ttu7nPwWmIjubgwwdSkcc37' WHERE tipo = 'promotoria_base' AND periodo = 'mensual';
UPDATE stripe_precios SET price_id = 'price_1Ttu96PwWmIjubgwzjS0RqbD' WHERE tipo = 'promotoria_base' AND periodo = 'trimestral';
UPDATE stripe_precios SET price_id = 'price_1TtuAbPwWmIjubgw31O91fgo' WHERE tipo = 'promotoria_base' AND periodo = 'semestral';
UPDATE stripe_precios SET price_id = 'price_1TtuCePwWmIjubgwMejIG5DK' WHERE tipo = 'promotoria_base' AND periodo = 'anual';

-- Verificación rápida: deberían salir 8 filas, todas con price_id no nulo
select * from stripe_precios order by tipo, periodo;
