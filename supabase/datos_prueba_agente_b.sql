-- Upco InsurGest — Datos de prueba para agente-prueba-b@upco.app
-- Crea 3 clientes con vehículos y pólizas variadas (vigente, por vencer, vencida)
-- para poder ver el dashboard y la liga mágica con datos reales de ejemplo.
-- Pegar completo en Supabase > SQL Editor > New query > Run

with agente as (
  select id from agentes where correo = 'agente-prueba-b@upco.app'
),
c1 as (
  insert into clientes (agente_id, tipo_persona, nombre, rfc, correo, telefono)
  select id, 'fisica', 'Laura Fernández Ruiz', 'FERL880512AB1', 'laura.fernandez@example.com', '5512345678' from agente
  returning id
),
v1 as (
  insert into vehiculos (cliente_id, placas, estado, marca, modelo, anio, tipo_vehiculo, fecha_verificacion)
  select id, 'ABC1234', 'Ciudad de México', 'Nissan', 'Versa', 2021, 'familiar', current_date + interval '20 days' from c1
  returning id
),
c2 as (
  insert into clientes (agente_id, tipo_persona, nombre, rfc, correo, telefono)
  select id, 'moral', 'Comercializadora del Bajío SA de CV', 'CBA150101XY2', 'contacto@combajio.com.mx', '4771234567' from agente
  returning id
),
c3 as (
  insert into clientes (agente_id, tipo_persona, nombre, rfc, correo, telefono)
  select id, 'fisica', 'Ricardo Torres Mendoza', 'TOMR760310CD3', 'ricardo.torres@example.com', '8112223344' from agente
  returning id
),
v3 as (
  insert into vehiculos (cliente_id, placas, estado, marca, modelo, anio, tipo_vehiculo)
  select id, 'XYZ9988', 'Nuevo León', 'Chevrolet', 'Aveo', 2018, 'familiar' from c3
  returning id
)
insert into polizas (cliente_id, vehiculo_id, ramo, aseguradora, numero_poliza, fecha_inicio, fecha_fin, prima, forma_pago, estatus)
select id, (select id from v1), 'Auto', 'Quálitas', 'QLT-88291', current_date - interval '4 months', current_date + interval '8 months', 14500, 'anual', 'vigente' from c1
union all
select id, null, 'Vida', 'GNP', 'GNP-VID-3321', current_date - interval '11 months', current_date + interval '10 days', 9800, 'anual', 'vigente' from c1
union all
select id, null, 'Auto', 'AXA', 'AXA-FLT-5567', current_date - interval '5 months', current_date + interval '7 months', 21300, 'semestral', 'vigente' from c2
union all
select id, (select id from v3), 'Auto', 'HDI Seguros', 'HDI-2201', current_date - interval '14 months', current_date - interval '2 months', 13200, 'anual', 'vigente' from c3;

-- Ligas mágicas de los clientes recién creados, para copiar y compartir
select c.nombre, 'https://insurgest.upco.app/p/' || c.token_publico as liga_magica
from clientes c
join agentes a on a.id = c.agente_id
where a.correo = 'agente-prueba-b@upco.app'
order by c.nombre;
