-- Upco InsurGest — Sesion 40: ruta publica /anf/{alias}, Analisis de Necesidades Financieras
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- Mismo patron que /r/{alias} (cotizador de retiro, Sesion 15): pagina publica sin login que
-- reusa tarjeta_publica (identidad del agente) y tarjeta_contactar (captura del lead) — cero
-- tabla ni RPC nuevo, solo se agrega 'anf' a la lista de alias reservados para que nadie pueda
-- registrar una tarjeta con ese nombre y romper la ruta.

create or replace function public.alias_reservado(p_alias text) returns boolean
language sql
immutable
as $$
  select p_alias in (
    'app','admin','promotor','maestra','a','p','pr','r','anf','precios','terminos','soporte','ayuda','contacto',
    'api','assets','static','index','sw','404','www','upco','insurgest','blog','login','registro'
  );
$$;
