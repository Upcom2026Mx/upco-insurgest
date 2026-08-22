-- Upco InsurGest — Sesión 73: ajuste del esquema de comisiones del Agente Libre
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- Cinco cosas, todas dentro de registrar_residuales_del_mes():
--
-- 1. La base del 17% del Agente Libre pasa de $299 a $249. El agente que llega con su código
--    ahora paga la tarifa de agente afiliado ($249), no la individual ($299) — ese descuento es
--    justamente lo que el Agente Libre le lleva a su gente, y no se puede pagar comisión sobre
--    dinero que no se cobró.
--
-- 2. El 3% deja de calcularse sobre la cuota suelta del promotor y pasa a calcularse sobre la
--    facturación COMPLETA de esa red: el $999 del promotor más $249 por cada agente suyo arriba
--    del quinto. Para agencia máster se toma el árbol entero (su $999, más el $999 de cada
--    promotoría suya, más los agentes de esas promotorías). Así 17% + 3% suman exactamente 20%
--    de comisión repartida sobre los mismos pesos.
--
-- 3. Si el agente no paga, nadie cobra. El loop del promotor contaba a los agentes de red por
--    posición sin mirar su suscripción, así que se pagaba residual sobre dinero que nunca entró;
--    lo mismo la agencia máster con sus promotorías. Ahora los tres niveles exigen
--    estatus_suscripcion = 'active'.
--
-- 4. Bug de idempotencia (venía de la Sesión 69): los dos loops del Agente Libre cerraban con
--    "monto = residuales_snapshot.monto + excluded.monto", o sea SUMABAN en vez de reemplazar.
--    Si la función corría dos veces el mismo mes, al Agente Libre se le pagaba doble. Ahora las
--    partes se suman ANTES de insertar y se escribe una sola fila por período con semántica de
--    reemplazo, precedida de un delete del período para que un downline que se vacía no deje
--    una fila vieja inflada.
--
-- 5. Regla de exclusividad entre caminos: un agente cuenta para el 17% del Agente Libre solo si
--    NO pertenece a una promotoría. Si está en una red, el promotor cobra su 17% y el Agente
--    Libre cobra por la vía del 3% sobre esa red — nunca los dos sobre el mismo agente.
--    Igual entre niveles: una promotoría que cuelga de una agencia máster referida por el mismo
--    Agente Libre no se cuenta dos veces.
--
-- El Agente Libre NO incluye lugares gratis: a diferencia de la promotoría (5 incluidos en su
-- $999), todos los agentes que él trae pagan $249 desde el primero y todos cuentan para su 17%.
--
-- Verificado antes de aplicar: 0 promotorías y 0 agencias máster tienen hoy referidos sin pagar,
-- así que el filtro nuevo no le baja el residual a nadie ya existente.

create or replace function public.registrar_residuales_del_mes()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_periodo date := date_trunc('month', current_date)::date;
  r record;
begin
  -- ------------------------------------------------------------------------
  -- Promotoría — su tasa sobre los agentes de su red arriba del quinto que PAGAN.
  -- ------------------------------------------------------------------------
  for r in
    select p.id, count(a.id) as agentes_que_cuentan, p.tasa_residual
    from promotorias p
    join agentes a on a.promotoria_id = p.id
      and a.red_aprobada_en is not null
      and a.estatus_suscripcion = 'active'
    join public.vista_posicion_red v on v.id = a.id and v.posicion > 5
    where p.tasa_residual > 0
    group by p.id, p.tasa_residual
  loop
    insert into residuales_snapshot(remitente_id, remitente_tipo, periodo, monto)
    values (r.id, 'promotoria', v_periodo, round(r.agentes_que_cuentan * 249 * r.tasa_residual, 2))
    on conflict (remitente_id, periodo) do update set monto = excluded.monto;
  end loop;

  -- ------------------------------------------------------------------------
  -- Agencia máster — su tasa sobre cada promotoría suya que PAGA.
  -- ------------------------------------------------------------------------
  for r in
    select ag.id, count(p.id) as promotorias_que_cuentan, ag.tasa_residual
    from agencias_maestras ag
    join promotorias p on p.agencia_maestra_id = ag.id
      and p.agencia_confirmada_en is not null
      and p.estatus_aprobacion = 'aprobado'
      and p.estatus_suscripcion = 'active'
    where ag.tasa_residual > 0
    group by ag.id, ag.tasa_residual
  loop
    insert into residuales_snapshot(remitente_id, remitente_tipo, periodo, monto)
    values (r.id, 'agencia_maestra', v_periodo, round(r.promotorias_que_cuentan * 999 * r.tasa_residual, 2))
    on conflict (remitente_id, periodo) do update set monto = excluded.monto;
  end loop;

  -- ------------------------------------------------------------------------
  -- Agente Libre — una sola fila por período: 17% de sus agentes directos más 3%
  -- de la red completa de cada promotoría y del árbol completo de cada agencia
  -- máster que haya referido.
  -- ------------------------------------------------------------------------
  delete from residuales_snapshot
    where remitente_tipo = 'agente_libre' and periodo = v_periodo;

  for r in
    select al.id,
      -- 17% de cada agente directo que paga. "Directo" = sin promotoría: si el agente
      -- entró a una red, ese agente lo cobra el promotor y el Agente Libre lo cobra
      -- por la vía del 3%, nunca los dos.
      (
        select count(*) from agentes a
        where a.agente_libre_id = al.id
          and a.promotoria_id is null
          and a.estatus_suscripcion = 'active'
      ) * 249 * 0.17
      +
      -- 3% de la facturación completa de cada promotoría referida directamente:
      -- su $999 más $249 por cada agente suyo arriba del quinto que pague. Se excluyen
      -- las promotorías que ya entran por el árbol de una agencia máster del mismo
      -- Agente Libre, para no contarlas dos veces.
      coalesce((
        select sum(999 + (
          select count(*) from agentes a
          join public.vista_posicion_red v on v.id = a.id and v.posicion > 5
          where a.promotoria_id = p.id
            and a.red_aprobada_en is not null
            and a.estatus_suscripcion = 'active'
        ) * 249)
        from promotorias p
        where p.agente_libre_id = al.id
          and p.estatus_suscripcion = 'active'
          and not exists (
            select 1 from agencias_maestras ag2
            where ag2.id = p.agencia_maestra_id
              and ag2.agente_libre_id = al.id
              and ag2.estatus_suscripcion = 'active'
          )
      ), 0) * 0.03
      +
      -- 3% del árbol completo de cada agencia máster referida: su $999, más el $999 de
      -- cada promotoría suya que pague, más los $249 de los agentes de esas promotorías
      -- arriba del quinto que paguen.
      coalesce((
        select sum(999 + coalesce((
          select sum(999 + (
            select count(*) from agentes a
            join public.vista_posicion_red v on v.id = a.id and v.posicion > 5
            where a.promotoria_id = p.id
              and a.red_aprobada_en is not null
              and a.estatus_suscripcion = 'active'
          ) * 249)
          from promotorias p
          where p.agencia_maestra_id = ag.id
            and p.agencia_confirmada_en is not null
            and p.estatus_aprobacion = 'aprobado'
            and p.estatus_suscripcion = 'active'
        ), 0))
        from agencias_maestras ag
        where ag.agente_libre_id = al.id
          and ag.estatus_suscripcion = 'active'
      ), 0) * 0.03
      as monto
    from agentes_libres al
  loop
    continue when coalesce(r.monto, 0) <= 0;
    insert into residuales_snapshot(remitente_id, remitente_tipo, periodo, monto)
    values (r.id, 'agente_libre', v_periodo, round(r.monto, 2))
    on conflict (remitente_id, periodo) do update set monto = excluded.monto;
  end loop;
end;
$$;

-- ----------------------------------------------------------------------------
-- Candado de tarifa — quién tiene derecho a pagar $249 ("agente_afiliado").
--
-- create-checkout-session recibe el "tipo" desde el navegador y buscaba el precio sin
-- comprobar que la cuenta tuviera derecho a esa tarifa: cualquiera que supiera invocar la
-- función podía pedir 'agente_afiliado' y pagar $249 en vez de $299. El candado tiene que
-- vivir del lado del servidor, y aquí queda la regla única que usan el checkout y el panel.
--
-- Dos caminos legítimos al $249, por motivos distintos:
--   - el agente 6+ de la red de una promotoría (los 5 primeros van incluidos en su $999)
--   - el agente que llegó con el código de un Agente Libre (ese descuento es justamente lo
--     que el Agente Libre le lleva a su gente)
-- ----------------------------------------------------------------------------
create or replace function public.agente_puede_tarifa_afiliado(p_agente_id uuid)
returns boolean
language sql
stable security definer
set search_path = public
as $$
  select exists (
    select 1 from agentes a
    where a.id = p_agente_id and a.agente_libre_id is not null
  ) or exists (
    select 1 from agentes a
    join public.vista_posicion_red v on v.id = a.id
    where a.id = p_agente_id and a.red_aprobada_en is not null and v.posicion > 5
  );
$$;
