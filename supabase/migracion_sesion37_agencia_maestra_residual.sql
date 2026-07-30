-- Upco InsurGest — Sesión 37: nivel de Agencia Master + cálculo de residual (promotoría y agencia)
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- Decisiones tomadas en la conversación con el usuario, documentadas aquí para que quede claro
-- qué se implementó exactamente:
--
--   1. UN SOLO NIVEL, no cascada: la agencia máster gana sobre la facturación de SUS
--      promotorías (cuota base $999 c/u), nunca sobre el bono que ya recibió la promotoría.
--      La promotoría gana sobre la facturación de SUS agentes adicionales ($249 c/u), nunca
--      sobre su propia cuota base de $999. Cada nivel cobra de una "rebanada" distinta —
--      nadie cobra comisión sobre la comisión de otro.
--   2. La base de cálculo del residual de la promotoría son los agentes que SÍ pagan de más
--      (posición > 5 en la red, ya confirmados) — no los primeros 5 que vienen incluidos
--      gratis en la cuota base. Es la interpretación económicamente consistente con el resto
--      del sistema (vista_posicion_red ya distingue esto); si el usuario prefiere la otra
--      lectura (contar los 12 agentes parejo a $249), es un cambio de una sola línea en
--      promotoria_mi_residual().
--   3. La tasa (tasa_residual) la fija el fundador manualmente por cuenta, nunca es automática
--      ni universal — "algunas promotorías", no todas.
--   4. Se paga como "aguinaldo" una vez al año, no mes a mes — pero se calcula y se guarda un
--      snapshot cada mes para que se vea acumulando en su panel durante el año.
--   5. La afiliación promotoría → agencia máster necesita confirmación explícita de la
--      agencia (mismo patrón que agente → promotoría con red_aprobada_en), para que nadie
--      pueda inflar su cuota de red solo escribiendo un código.

-- ============ TABLA: AGENCIAS MAESTRAS (mismo patrón que promotorías) ============
create table agencias_maestras (
  id uuid primary key references auth.users(id) on delete cascade,
  correo text not null,
  nombre text,
  nombre_negocio text,
  rfc text,
  codigo_invitacion text not null unique default upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6)),
  estatus_aprobacion text not null default 'pendiente' check (estatus_aprobacion in ('pendiente','aprobado','rechazado')),
  tasa_residual numeric not null default 0,
  acepto_terminos boolean not null default false,
  acepto_terminos_version text,
  acepto_terminos_fecha timestamptz,
  aprobado_en timestamptz,
  created_at timestamptz not null default now()
);

alter table agencias_maestras enable row level security;

create policy "agencia ve su propia fila" on agencias_maestras for select using (auth.uid() = id);
create policy "agencia crea su propia fila" on agencias_maestras for insert with check (auth.uid() = id);
create policy "agencia edita su propia fila" on agencias_maestras for update using (auth.uid() = id);

-- Mismo candado de 2FA que ya protege agentes/promotorías: se exige desde la tabla, no solo
-- desde la pantalla (ver Sesión 21 — un 2FA solo en la UI es teatro).
create policy "exige 2fa cuando esta activado" on agencias_maestras
  as restrictive for all to authenticated
  using (public.mfa_ok()) with check (public.mfa_ok());

-- ============ VÍNCULO PROMOTORÍA → AGENCIA MÁSTER ============
alter table promotorias add column agencia_maestra_id uuid references agencias_maestras(id) on delete set null;
alter table promotorias add column agencia_confirmada_en timestamptz;
alter table promotorias add column tasa_residual numeric not null default 0;

create or replace function public.es_agencia_maestra() returns boolean
language sql stable security definer set search_path = public
as $$
  select exists(select 1 from agencias_maestras where id = auth.uid());
$$;
grant execute on function public.es_agencia_maestra() to authenticated;

-- ============ REGISTRO: mismo patrón que resolver_codigo_promotoria (agente → promotoría) ============
-- Se resuelve ANTES del insert (no después), para que la fila de promotorias nazca ya con
-- agencia_maestra_id puesto — igual que agentes ya hace con promotoria_id.
create or replace function public.resolver_codigo_agencia(p_codigo text) returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select id from agencias_maestras where codigo_invitacion = upper(trim(p_codigo));
$$;
grant execute on function public.resolver_codigo_agencia(text) to anon, authenticated;

-- ============ AGENCIA MÁSTER: VER Y CONFIRMAR SUS PROMOTORÍAS ============
create or replace function public.agencia_maestra_promotorias() returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_agencia_maestra() then raise exception 'No autorizado'; end if;
  return coalesce((
    select json_agg(t order by t.creado desc) from (
      select
        p.id, p.nombre, p.correo, p.nombre_negocio, p.estatus_aprobacion, p.agencia_confirmada_en,
        p.created_at as creado,
        (select count(*) from agentes a where a.promotoria_id = p.id and a.red_aprobada_en is not null) as agentes,
        (select count(*) from clientes c join agentes a on a.id = c.agente_id where a.promotoria_id = p.id) as clientes,
        (select count(*) from polizas po join clientes c on c.id = po.cliente_id join agentes a on a.id = c.agente_id where a.promotoria_id = p.id) as polizas
      from promotorias p
      where p.agencia_maestra_id = auth.uid()
    ) t
  ), '[]'::json);
end;
$$;
grant execute on function public.agencia_maestra_promotorias() to authenticated;

create or replace function public.agencia_maestra_confirmar_promotoria(p_promotoria_id uuid) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_agencia_maestra() then raise exception 'No autorizado'; end if;
  update promotorias set agencia_confirmada_en = now()
  where id = p_promotoria_id and agencia_maestra_id = auth.uid();
end;
$$;
grant execute on function public.agencia_maestra_confirmar_promotoria(uuid) to authenticated;

create or replace function public.agencia_maestra_sacar_promotoria(p_promotoria_id uuid) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_agencia_maestra() then raise exception 'No autorizado'; end if;
  update promotorias set agencia_maestra_id = null, agencia_confirmada_en = null
  where id = p_promotoria_id and agencia_maestra_id = auth.uid();
end;
$$;
grant execute on function public.agencia_maestra_sacar_promotoria(uuid) to authenticated;

create or replace function public.agencia_maestra_resumen() returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_agencia_maestra() then raise exception 'No autorizado'; end if;
  return json_build_object(
    'promotorias_totales', (select count(*) from promotorias where agencia_maestra_id = auth.uid()),
    'promotorias_confirmadas', (select count(*) from promotorias where agencia_maestra_id = auth.uid() and agencia_confirmada_en is not null),
    'promotorias_pendientes', (select count(*) from promotorias where agencia_maestra_id = auth.uid() and agencia_confirmada_en is null),
    'agentes_totales', (
      select count(*) from agentes a join promotorias p on p.id = a.promotoria_id
      where p.agencia_maestra_id = auth.uid() and a.red_aprobada_en is not null
    ),
    'clientes_totales', (
      select count(*) from clientes c join agentes a on a.id = c.agente_id join promotorias p on p.id = a.promotoria_id
      where p.agencia_maestra_id = auth.uid()
    )
  );
end;
$$;
grant execute on function public.agencia_maestra_resumen() to authenticated;

-- ============ CÁLCULO DE RESIDUAL (en vivo, para mostrar "cuánto llevas este mes") ============
-- Promotoría: 17%-o-lo-que-se-le-haya-fijado, sobre los agentes que de verdad pagan $249 extra
-- (posición > 5, ya confirmados) — nunca sobre su propia cuota base de $999.
create or replace function public.promotoria_mi_residual() returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tasa numeric; v_agentes_que_cuentan int; v_base numeric;
begin
  if not public.es_promotoria() then raise exception 'No autorizado'; end if;
  select tasa_residual into v_tasa from promotorias where id = auth.uid();

  select count(*) into v_agentes_que_cuentan
  from agentes a
  join public.vista_posicion_red v on v.id = a.id
  where a.promotoria_id = auth.uid() and a.red_aprobada_en is not null and v.posicion > 5;

  v_base := v_agentes_que_cuentan * 249;
  return json_build_object('tasa', v_tasa, 'agentes_que_cuentan', v_agentes_que_cuentan, 'base', v_base, 'residual_mensual', round(v_base * v_tasa, 2));
end;
$$;
grant execute on function public.promotoria_mi_residual() to authenticated;

-- Agencia máster: sobre la cuota base ($999) de cada promotoría confirmada en su red — nunca
-- sobre el bono que ya recibe esa promotoría.
create or replace function public.agencia_maestra_mi_residual() returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tasa numeric; v_promotorias_que_cuentan int; v_base numeric;
begin
  if not public.es_agencia_maestra() then raise exception 'No autorizado'; end if;
  select tasa_residual into v_tasa from agencias_maestras where id = auth.uid();

  select count(*) into v_promotorias_que_cuentan
  from promotorias p
  where p.agencia_maestra_id = auth.uid() and p.agencia_confirmada_en is not null and p.estatus_aprobacion = 'aprobado';

  v_base := v_promotorias_que_cuentan * 999;
  return json_build_object('tasa', v_tasa, 'promotorias_que_cuentan', v_promotorias_que_cuentan, 'base', v_base, 'residual_mensual', round(v_base * v_tasa, 2));
end;
$$;
grant execute on function public.agencia_maestra_mi_residual() to authenticated;

-- ============ ACUMULADO ANUAL ("AGUINALDO") ============
-- Una fila por cuenta por mes — se ve crecer en el panel durante el año, se paga junto al
-- cierre de año. remitente_tipo genérico porque tanto promotorías como agencias usan la misma
-- tabla y la misma lógica de consulta.
create table residuales_snapshot (
  id uuid primary key default gen_random_uuid(),
  remitente_id uuid not null,
  remitente_tipo text not null check (remitente_tipo in ('promotoria','agencia_maestra')),
  periodo date not null, -- primer día del mes que representa
  monto numeric not null,
  created_at timestamptz not null default now(),
  unique (remitente_id, periodo)
);
alter table residuales_snapshot enable row level security;
-- Sin políticas para "authenticated": se lee solo a través de mi_residual_acumulado_anio()
-- (SECURITY DEFINER), nadie necesita seleccionar la tabla directo.

create or replace function public.mi_residual_acumulado_anio() returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(monto), 0) from residuales_snapshot
  where remitente_id = auth.uid() and date_trunc('year', periodo) = date_trunc('year', current_date);
$$;
grant execute on function public.mi_residual_acumulado_anio() to authenticated;

-- Corre una vez al mes (día 1) vía pg_cron: guarda el residual calculado de ese mes para cada
-- promotoría/agencia con tasa > 0, para que el acumulado del año se pueda sumar después.
create or replace function public.registrar_residuales_del_mes() returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_periodo date := date_trunc('month', current_date)::date;
  r record;
begin
  for r in
    select p.id, count(a.id) as agentes_que_cuentan, p.tasa_residual
    from promotorias p
    join agentes a on a.promotoria_id = p.id and a.red_aprobada_en is not null
    join public.vista_posicion_red v on v.id = a.id and v.posicion > 5
    where p.tasa_residual > 0
    group by p.id, p.tasa_residual
  loop
    insert into residuales_snapshot(remitente_id, remitente_tipo, periodo, monto)
    values (r.id, 'promotoria', v_periodo, round(r.agentes_que_cuentan * 249 * r.tasa_residual, 2))
    on conflict (remitente_id, periodo) do update set monto = excluded.monto;
  end loop;

  for r in
    select ag.id, count(p.id) as promotorias_que_cuentan, ag.tasa_residual
    from agencias_maestras ag
    join promotorias p on p.agencia_maestra_id = ag.id and p.agencia_confirmada_en is not null and p.estatus_aprobacion = 'aprobado'
    where ag.tasa_residual > 0
    group by ag.id, ag.tasa_residual
  loop
    insert into residuales_snapshot(remitente_id, remitente_tipo, periodo, monto)
    values (r.id, 'agencia_maestra', v_periodo, round(r.promotorias_que_cuentan * 999 * r.tasa_residual, 2))
    on conflict (remitente_id, periodo) do update set monto = excluded.monto;
  end loop;
end;
$$;

select cron.schedule('registrar-residuales-mensual', '0 6 1 * *', $$select public.registrar_residuales_del_mes()$$);

-- ============ ADMIN: aprobar agencias, fijar tasas, ver todo ============
create or replace function public.admin_agencias_maestras() returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  return coalesce((
    select json_agg(t order by t.creado desc) from (
      select
        ag.id, ag.nombre, ag.correo, ag.nombre_negocio, ag.rfc, ag.estatus_aprobacion,
        ag.tasa_residual, ag.codigo_invitacion, ag.created_at as creado,
        (select count(*) from promotorias p where p.agencia_maestra_id = ag.id and p.agencia_confirmada_en is not null) as promotorias
      from agencias_maestras ag
    ) t
  ), '[]'::json);
end;
$$;
grant execute on function public.admin_agencias_maestras() to authenticated;

create or replace function public.admin_aprobar_agencia_maestra(p_agencia_id uuid) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  update agencias_maestras set estatus_aprobacion = 'aprobado', aprobado_en = now() where id = p_agencia_id;
end;
$$;
grant execute on function public.admin_aprobar_agencia_maestra(uuid) to authenticated;

create or replace function public.admin_rechazar_agencia_maestra(p_agencia_id uuid) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  update agencias_maestras set estatus_aprobacion = 'rechazado' where id = p_agencia_id;
end;
$$;
grant execute on function public.admin_rechazar_agencia_maestra(uuid) to authenticated;

-- Genérico para los dos tipos, para no duplicar el mismo RPC dos veces.
create or replace function public.admin_fijar_tasa_residual(p_remitente_id uuid, p_remitente_tipo text, p_tasa numeric) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  if p_remitente_tipo not in ('promotoria','agencia_maestra') then raise exception 'Tipo inválido'; end if;
  if p_tasa < 0 or p_tasa > 1 then raise exception 'La tasa debe ser un número entre 0 y 1 (ej. 0.17 para 17%%)'; end if;
  if p_remitente_tipo = 'promotoria' then
    update promotorias set tasa_residual = p_tasa where id = p_remitente_id;
  else
    update agencias_maestras set tasa_residual = p_tasa where id = p_remitente_id;
  end if;
end;
$$;
grant execute on function public.admin_fijar_tasa_residual(uuid,text,numeric) to authenticated;

-- admin_promotorias() (Sesión 23) ahora también expone tasa_residual, para que /admin pueda
-- mostrarla y editarla junto a cada promotoría.
create or replace function public.admin_promotorias() returns json
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if not public.es_admin() then
    raise exception 'No autorizado';
  end if;
  return coalesce((
    select json_agg(t order by t.creado desc) from (
      select
        p.id, p.nombre, p.correo, p.nombre_negocio, p.rfc, p.codigo_invitacion, p.estatus_aprobacion,
        p.estatus_suscripcion, p.plan_periodo, p.acceso_extendido_hasta, p.aprobado_en,
        p.suscripcion_vigente_hasta, p.tasa_residual,
        exists (select 1 from auth.mfa_factors f where f.user_id = p.id and f.status = 'verified') as tiene_2fa,
        p.created_at as creado,
        (select count(*) from agentes a where a.promotoria_id = p.id) as agentes
      from promotorias p
    ) t
  ), '[]'::json);
end;
$$;

-- alias_reservado() (Sesión 13) gana 'maestra' (nuevo portal) y 'pr'/'r' (ya existían como
-- rutas pero no estaban en la lista — se agregan de paso).
create or replace function public.alias_reservado(p_alias text) returns boolean
language sql
immutable
as $$
  select p_alias in (
    'app','admin','promotor','maestra','a','p','pr','r','precios','terminos','soporte','ayuda','contacto',
    'api','assets','static','index','sw','404','www','upco','insurgest','blog','login','registro'
  );
$$;
