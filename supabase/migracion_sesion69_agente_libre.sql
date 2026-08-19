-- Upco InsurGest — Sesión 69: nivel "Agente Libre", referido puro por encima de Agencia Máster
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- Agente Libre no paga suscripción y no trae ningún agente incluido gratis (a diferencia de
-- una promotoría normal). Puede referir directamente a agentes individuales, promotorías o
-- agencias máster con su mismo código, y gana:
--   - 17% recurrente sobre lo que paga cada agente referido directamente (agente individual
--     a precio completo, $299 — no hay "primeros 5 gratis" para este nivel).
--   - 3% recurrente sobre la cuota propia ($999) de cada promotoría/agencia máster referida.
--   - $150 (una sola vez) por agente nuevo, $450 (una sola vez) por promotoría/agencia máster
--     nueva.
-- Todo se gana solo cuando el referido hace su primer pago real (estatus_suscripcion pasa a
-- 'active' por primera vez), nunca durante los 30 días de prueba gratis.
--
-- Reusa al máximo el patrón ya probado de Agencia Máster/Promotoría: mismas 4 columnas de
-- identidad/aprobación, mismo estilo de resolver_codigo_*, mismas 3 ramas es_promotoria()/
-- es_agencia_maestra() ahora con una tercera es_agente_libre(), y el mismo cálculo por
-- conteo × cuota fija × tasa que ya usa registrar_residuales_del_mes() — no se inventa un
-- patrón nuevo de cobro real vía Stripe, se sigue la misma aproximación que ya está en producción.

-- ----------------------------------------------------------------------------
-- 1. Tabla agentes_libres — sin columnas de Stripe/plan (no pagan) ni
--    agencia_maestra_id (están arriba de esa jerarquía).
-- ----------------------------------------------------------------------------
create table agentes_libres (
  id uuid primary key references auth.users(id) on delete cascade,
  correo text not null,
  nombre text,
  nombre_negocio text,
  rfc text,
  codigo_invitacion text not null unique default upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6)),
  estatus_aprobacion text not null default 'pendiente' check (estatus_aprobacion in ('pendiente','aprobado','rechazado')),
  acepto_terminos boolean not null default false,
  acepto_terminos_version text,
  acepto_terminos_fecha timestamptz,
  created_at timestamptz not null default now(),
  aprobado_en timestamptz
);

alter table agentes_libres enable row level security;

create policy "agente_libre crea su propia fila" on agentes_libres
  for insert with check (auth.uid() = id);
create policy "agente_libre edita su propia fila" on agentes_libres
  for update using (auth.uid() = id);
create policy "agente_libre ve su propia fila" on agentes_libres
  for select using (auth.uid() = id);
create policy "exige 2fa cuando esta activado" on agentes_libres
  as restrictive to authenticated using (mfa_ok()) with check (mfa_ok());

-- ----------------------------------------------------------------------------
-- 2. Quién refirió a quién — independiente de agencia_maestra_id (son
--    relaciones distintas, un referido de Agente Libre puede o no tener
--    también una agencia máster operativa).
-- ----------------------------------------------------------------------------
alter table agentes add column if not exists agente_libre_id uuid references agentes_libres(id) on delete set null;
alter table promotorias add column if not exists agente_libre_id uuid references agentes_libres(id) on delete set null;
alter table agencias_maestras add column if not exists agente_libre_id uuid references agentes_libres(id) on delete set null;

-- ----------------------------------------------------------------------------
-- 3. Resolver de código — mismo patrón de una línea que resolver_codigo_promotoria/agencia.
-- ----------------------------------------------------------------------------
create or replace function public.resolver_codigo_agente_libre(p_codigo text)
returns uuid
language sql
stable security definer
set search_path = public
as $$
  select id from agentes_libres where codigo_invitacion = upper(trim(p_codigo)) and estatus_aprobacion = 'aprobado';
$$;

create or replace function public.es_agente_libre()
returns boolean
language sql
stable security definer
set search_path = public
as $$
  select exists(select 1 from agentes_libres where id = auth.uid() and estatus_aprobacion = 'aprobado');
$$;

-- ----------------------------------------------------------------------------
-- 4. Bono único por referido nuevo. unique(agente_libre_id, tipo, referido_id)
--    asegura que nunca se pague el mismo bono dos veces.
-- ----------------------------------------------------------------------------
create table bonos_agente_libre (
  id uuid primary key default gen_random_uuid(),
  agente_libre_id uuid not null references agentes_libres(id) on delete cascade,
  tipo text not null check (tipo in ('agente','promotoria','agencia_maestra')),
  referido_id uuid not null,
  monto numeric not null,
  otorgado_en timestamptz not null default now(),
  unique (agente_libre_id, tipo, referido_id)
);

alter table bonos_agente_libre enable row level security;
create policy "agente_libre ve sus propios bonos" on bonos_agente_libre
  for select using (agente_libre_id = auth.uid());

-- ----------------------------------------------------------------------------
-- 5. Trigger: el bono se otorga solo cuando estatus_suscripcion pasa a 'active'
--    por primera vez (nunca durante prueba gratis, nunca dos veces). Se eligió
--    un trigger de base de datos en vez de tocar la Edge Function stripe-webhook
--    — el webhook ya actualiza estatus_suscripcion, reaccionar a ese cambio en
--    SQL es más seguro que modificar código que procesa pagos reales en vivo.
-- ----------------------------------------------------------------------------
create or replace function public.otorgar_bono_agente_libre()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tipo text;
  v_monto numeric;
begin
  if new.estatus_suscripcion = 'active'
     and coalesce(old.estatus_suscripcion,'') is distinct from 'active'
     and new.agente_libre_id is not null
  then
    if tg_table_name = 'agentes' then v_tipo := 'agente'; v_monto := 150;
    elsif tg_table_name = 'promotorias' then v_tipo := 'promotoria'; v_monto := 450;
    elsif tg_table_name = 'agencias_maestras' then v_tipo := 'agencia_maestra'; v_monto := 450;
    end if;

    insert into bonos_agente_libre(agente_libre_id, tipo, referido_id, monto)
    values (new.agente_libre_id, v_tipo, new.id, v_monto)
    on conflict (agente_libre_id, tipo, referido_id) do nothing;
  end if;
  return new;
end;
$$;

create trigger bono_agente_libre_agentes
  after update of estatus_suscripcion on agentes
  for each row execute function public.otorgar_bono_agente_libre();

create trigger bono_agente_libre_promotorias
  after update of estatus_suscripcion on promotorias
  for each row execute function public.otorgar_bono_agente_libre();

create trigger bono_agente_libre_agencias_maestras
  after update of estatus_suscripcion on agencias_maestras
  for each row execute function public.otorgar_bono_agente_libre();

-- ----------------------------------------------------------------------------
-- 6. residuales_snapshot / solicitudes_residual aceptan el nuevo remitente_tipo.
-- ----------------------------------------------------------------------------
alter table residuales_snapshot drop constraint residuales_snapshot_remitente_tipo_check;
alter table residuales_snapshot add constraint residuales_snapshot_remitente_tipo_check
  check (remitente_tipo = any (array['promotoria'::text,'agencia_maestra'::text,'agente_libre'::text]));

alter table solicitudes_residual drop constraint solicitudes_residual_remitente_tipo_check;
alter table solicitudes_residual add constraint solicitudes_residual_remitente_tipo_check
  check (remitente_tipo = any (array['promotoria'::text,'agencia_maestra'::text,'agente_libre'::text]));

-- ----------------------------------------------------------------------------
-- 7. registrar_residuales_del_mes() — se agregan 2 loops nuevos al final, mismo
--    estilo que los dos ya existentes (conteo × cuota fija, no monto real de Stripe).
--    Solo cuentan referidos con estatus_suscripcion='active' (pago real, no prueba).
-- ----------------------------------------------------------------------------
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

  -- Agente Libre — 17% sobre cada agente referido directamente (pagan $299 completo,
  -- sin exención de "primeros 5 gratis").
  for r in
    select al.id, count(a.id) as agentes_que_cuentan
    from agentes_libres al
    join agentes a on a.agente_libre_id = al.id and a.estatus_suscripcion = 'active'
    group by al.id
  loop
    insert into residuales_snapshot(remitente_id, remitente_tipo, periodo, monto)
    values (r.id, 'agente_libre', v_periodo, round(r.agentes_que_cuentan * 299 * 0.17, 2))
    on conflict (remitente_id, periodo) do update set monto = residuales_snapshot.monto + excluded.monto;
  end loop;

  -- Agente Libre — 3% sobre la cuota propia de cada promotoría/agencia máster referida.
  for r in
    select al.id,
      (select count(*) from promotorias p where p.agente_libre_id = al.id and p.estatus_suscripcion = 'active') as promotorias_que_cuentan,
      (select count(*) from agencias_maestras ag where ag.agente_libre_id = al.id and ag.estatus_suscripcion = 'active') as agencias_que_cuentan
    from agentes_libres al
  loop
    continue when r.promotorias_que_cuentan = 0 and r.agencias_que_cuentan = 0;
    insert into residuales_snapshot(remitente_id, remitente_tipo, periodo, monto)
    values (r.id, 'agente_libre', v_periodo, round((r.promotorias_que_cuentan + r.agencias_que_cuentan) * 999 * 0.03, 2))
    on conflict (remitente_id, periodo) do update set monto = residuales_snapshot.monto + excluded.monto;
  end loop;
end;
$$;

-- ----------------------------------------------------------------------------
-- 8. solicitar_residual() / mi_residual_pendiente() — tercera rama agente_libre.
-- ----------------------------------------------------------------------------
create or replace function public.solicitar_residual()
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid := auth.uid();
  v_tipo text;
  v_nombre text;
  v_correo text;
  v_acumulado numeric;
  v_ya_solicitado numeric;
  v_pendiente numeric;
  v_key text;
begin
  if public.es_promotoria() then
    v_tipo := 'promotoria';
    select coalesce(nombre_negocio, correo), correo into v_nombre, v_correo from promotorias where id = v_id;
  elsif public.es_agencia_maestra() then
    v_tipo := 'agencia_maestra';
    select coalesce(nombre_negocio, correo), correo into v_nombre, v_correo from agencias_maestras where id = v_id;
  elsif public.es_agente_libre() then
    v_tipo := 'agente_libre';
    select coalesce(nombre_negocio, correo), correo into v_nombre, v_correo from agentes_libres where id = v_id;
  else
    raise exception 'No autorizado';
  end if;

  if exists(select 1 from solicitudes_residual where remitente_id = v_id and estatus = 'solicitado') then
    raise exception 'Ya tienes una solicitud en proceso — espera a que se confirme antes de mandar otra.';
  end if;

  select coalesce(sum(monto),0) into v_acumulado from residuales_snapshot where remitente_id = v_id;
  select coalesce(sum(monto),0) into v_ya_solicitado from solicitudes_residual
    where remitente_id = v_id and estatus in ('solicitado','pagado');
  v_pendiente := greatest(v_acumulado - v_ya_solicitado, 0);

  if v_pendiente <= 0 then
    raise exception 'No tienes comisión pendiente por solicitar todavía.';
  end if;

  insert into solicitudes_residual(remitente_id, remitente_tipo, monto) values (v_id, v_tipo, v_pendiente);

  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'resend_api_key';
  if v_key is not null then
    perform net.http_post(
      url := 'https://api.resend.com/emails',
      headers := jsonb_build_object('Authorization','Bearer '||v_key,'Content-Type','application/json'),
      body := jsonb_build_object(
        'from','Upco InsurGest <notificaciones@upco.app>',
        'to', jsonb_build_array('hola@upco.app'),
        'reply_to', v_correo,
        'subject', format('Solicitud de comisión — %s', v_nombre),
        'html', format(
          '<p><strong>%s</strong> (%s, %s) solicitó el pago de su comisión acumulada: <strong>$%s MXN</strong>.</p><p>Revísalo y márcalo como pagado desde /admin → Comisiones.</p>',
          v_nombre, v_correo,
          case v_tipo when 'promotoria' then 'promotoría' when 'agencia_maestra' then 'agencia máster' else 'agente libre' end,
          to_char(v_pendiente,'FM999,999,990.00')
        )
      )
    );
  end if;

  return json_build_object('ok', true, 'monto', v_pendiente);
end;
$$;

create or replace function public.mi_residual_pendiente()
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid := auth.uid();
  v_acumulado numeric;
  v_ya_solicitado numeric;
  v_abierta boolean;
begin
  if not (public.es_promotoria() or public.es_agencia_maestra() or public.es_agente_libre()) then
    raise exception 'No autorizado';
  end if;

  select coalesce(sum(monto),0) into v_acumulado from residuales_snapshot where remitente_id = v_id;
  select coalesce(sum(monto),0) into v_ya_solicitado from solicitudes_residual
    where remitente_id = v_id and estatus in ('solicitado','pagado');
  select exists(select 1 from solicitudes_residual where remitente_id = v_id and estatus = 'solicitado') into v_abierta;

  return json_build_object(
    'pendiente_por_solicitar', greatest(v_acumulado - v_ya_solicitado, 0),
    'solicitud_abierta', v_abierta
  );
end;
$$;

-- ----------------------------------------------------------------------------
-- 9. admin_solicitudes_residual() — agrega el join a agentes_libres.
-- ----------------------------------------------------------------------------
create or replace function public.admin_solicitudes_residual()
returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  return coalesce((
    select json_agg(t order by t.solicitado_en desc) from (
      select
        sr.id, sr.remitente_id, sr.remitente_tipo, sr.monto, sr.estatus, sr.nota_admin,
        sr.solicitado_en, sr.atendido_en,
        coalesce(pr.nombre_negocio, ag.nombre_negocio, al.nombre_negocio) as nombre,
        coalesce(pr.correo, ag.correo, al.correo) as correo
      from solicitudes_residual sr
      left join promotorias pr on pr.id = sr.remitente_id and sr.remitente_tipo = 'promotoria'
      left join agencias_maestras ag on ag.id = sr.remitente_id and sr.remitente_tipo = 'agencia_maestra'
      left join agentes_libres al on al.id = sr.remitente_id and sr.remitente_tipo = 'agente_libre'
    ) t
  ), '[]'::json);
end;
$$;

-- Nota de permisos: no se agregan GRANT/REVOKE explícitos aquí a propósito.
-- resolver_codigo_agente_libre() y es_agente_libre() quedan con el mismo permiso
-- PUBLIC por default que ya tienen resolver_codigo_promotoria()/es_promotoria()
-- (nunca tuvieron un revoke explícito — verificado por has_function_privilege
-- antes de escribir esta migración). registrar_residuales_del_mes(),
-- solicitar_residual(), mi_residual_pendiente() y admin_solicitudes_residual()
-- ya tenían sus permisos correctos desde antes, y CREATE OR REPLACE FUNCTION
-- no los toca mientras la firma (nombre + tipos de parámetros) no cambie —
-- que es justo el caso aquí, solo se reescribió el cuerpo.
