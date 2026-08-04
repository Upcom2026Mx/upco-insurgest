-- Upco InsurGest — Sesión 46: indicadores financieros de Banxico
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- Guarda el tipo de cambio FIX, el valor de la UDI y la TIIE a 28 días, actualizados a
-- diario desde la API oficial del SIE de Banco de México, para mostrarlos en el panel del
-- agente (pestaña "Resumen").
--
-- ARQUITECTURA: pg_cron -> pg_net (disparar y olvidar) -> Edge Function -> escribe la tabla.
-- Se eligió así, y no leyendo la respuesta HTTP con net._http_response, porque pg_net es
-- asíncrono: devuelve un request_id y la respuesta llega después a una tabla que además se
-- purga sola. La Edge Function hace el fetch de forma síncrona y escribe ella misma, que es
-- exactamente el mismo patrón que ya usa revisar_vencimientos() para llamar a send-push.
--
-- ANTES DE CORRER ESTO hace falta:
--   1. Obtener el token gratuito en https://www.banxico.org.mx/SieAPIRest/service/v1/token
--   2. Cargarlo como secreto del proyecto en Edge Functions > Secrets con el nombre
--      BANXICO_TOKEN (a nivel proyecto, NO por función — está en un menú distinto al de
--      Settings de cada función).
--   3. Desplegar la función:
--      supabase functions deploy actualizar-indicadores --project-ref pxcvckqahkjlizgotvqw
--
-- El token NO va en este archivo ni en ninguno del repo: es público en GitHub.

-- ============ TABLA ============
-- PK natural por fecha, siguiendo el estilo de los catálogos del proyecto
-- (estados_verificacion usa `estado text primary key`), no el `id uuid` de las tablas
-- transaccionales. Guardar histórico permite mostrar la variación contra el día anterior
-- y, más adelante, una tendencia.
create table if not exists indicadores_financieros (
  fecha date primary key,
  usd_fix numeric(10,4),        -- pesos por dólar, tipo de cambio FIX (serie SF43718)
  udis numeric(10,6),           -- valor de la UDI en pesos (serie SP68257)
  tiie28 numeric(8,4),          -- TIIE a 28 días, en % (serie SF43783)
  actualizado_en timestamptz not null default now()
);

alter table indicadores_financieros enable row level security;

-- A diferencia de stripe_precios (que no lleva policy porque solo la lee el service role),
-- aquí el agente autenticado sí lo consulta desde el navegador para pintar el widget.
-- Es información pública de Banxico, no hay nada que aislar por cuenta.
drop policy if exists "cualquiera puede leer los indicadores" on indicadores_financieros;
create policy "cualquiera puede leer los indicadores" on indicadores_financieros
  for select using (true);

-- ============ VISTA: ÚLTIMO VALOR DE CADA INDICADOR ============
-- Las tres series NO comparten fecha: el FIX se publica por día hábil, la TIIE va un día
-- adelante, y la UDI Banxico la publica con hasta dos semanas de anticipación. Por eso
-- "la fila más reciente" no sirve para el panel — mostraría la UDI del futuro y escondería
-- el dólar. Esta vista resuelve cada indicador por su cuenta: su último valor publicado que
-- no sea posterior a hoy, más la variación contra su propio valor anterior.
create or replace view indicadores_ultimos as
with base as (
  select 'usd_fix' as indicador, fecha, usd_fix as valor
    from indicadores_financieros where usd_fix is not null and fecha <= current_date
  union all
  select 'udis', fecha, udis
    from indicadores_financieros where udis is not null and fecha <= current_date
  union all
  select 'tiie28', fecha, tiie28
    from indicadores_financieros where tiie28 is not null and fecha <= current_date
),
ordenado as (
  select indicador, fecha, valor,
         row_number() over (partition by indicador order by fecha desc) as rn,
         lead(valor) over (partition by indicador order by fecha desc) as valor_previo
  from base
)
select indicador, fecha, valor, valor - valor_previo as variacion
from ordenado
where rn = 1;

grant select on indicadores_ultimos to anon, authenticated;

-- ============ DISPARADOR HACIA LA EDGE FUNCTION ============
-- Se reutiliza a propósito el secreto push_internal_secret que ya existe en Vault y en los
-- Secrets del proyecto: es exactamente el mismo límite de confianza (proceso interno de la
-- base llamando a una Edge Function propia), y evita que el fundador tenga que configurar
-- un secreto más a mano.
create or replace function public.actualizar_indicadores_banxico()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_secret text;
begin
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'push_internal_secret';
  if v_secret is null then
    raise notice 'Falta configurar el secreto push_internal_secret en Vault';
    return;
  end if;

  perform net.http_post(
    url := 'https://pxcvckqahkjlizgotvqw.supabase.co/functions/v1/actualizar-indicadores',
    headers := jsonb_build_object(
      'Content-Type','application/json',
      'Authorization','Bearer sb_publishable_F2WhknXrY8MLjI5ftd0H6w_-XXjej6I',
      'x-internal-secret', v_secret
    ),
    body := '{}'::jsonb
  );
end;
$$;

revoke all on function public.actualizar_indicadores_banxico() from public, anon, authenticated;

-- ============ PROGRAMACIÓN DIARIA ============
-- 15:00 UTC = 09:00 hora de Ciudad de México (México ya no tiene horario de verano).
-- Banxico publica el FIX alrededor del mediodía UTC, así que a esta hora el dato del día
-- ya está disponible. No choca con los otros tres jobs del proyecto (0 14, 30 3, 0 6 1).
-- unschedule primero para que re-correr esta migración no truene por nombre duplicado.
select cron.unschedule('insurgest-banxico') where exists (select 1 from cron.job where jobname='insurgest-banxico');
select cron.schedule('insurgest-banxico','0 15 * * *', $$select public.actualizar_indicadores_banxico();$$);
