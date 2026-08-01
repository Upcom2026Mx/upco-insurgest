-- Upco InsurGest — Sesión 39: botón "Solicitar mi comisión" para promotoría/agencia máster
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- Contexto: el residual/"aguinaldo" (Sesión 37) se calculaba y guardaba mes a mes pero solo se
-- pensaba pagar una vez al año. El usuario decidió que en realidad no le importa pagarlo en
-- cuanto se lo pidan — así que en vez de automatizar un prorrateo, se agrega un flujo de
-- solicitud voluntaria: la promotoría/agencia ve cuánto tiene acumulado SIN solicitar todavía
-- (todo lo snapshoteado en residuales_snapshot, menos lo que ya solicitó antes) y puede pedirlo
-- cuando quiera. El fundador lo marca como pagado a mano desde /admin cuando lo transfiere.

create table solicitudes_residual (
  id uuid primary key default gen_random_uuid(),
  remitente_id uuid not null,
  remitente_tipo text not null check (remitente_tipo in ('promotoria','agencia_maestra')),
  monto numeric not null,
  estatus text not null default 'solicitado' check (estatus in ('solicitado','pagado','rechazado')),
  nota_admin text,
  solicitado_en timestamptz not null default now(),
  atendido_en timestamptz
);

alter table solicitudes_residual enable row level security;

-- El remitente ve sus propias solicitudes (funciona para los dos tipos: su propio auth.uid()
-- nunca coincide con el id de nadie más, sea cual sea la tabla de origen).
create policy "remitente ve sus solicitudes de residual" on solicitudes_residual
  for select using (remitente_id = auth.uid());
create policy "admin ve todas las solicitudes de residual" on solicitudes_residual
  for select using (public.es_admin());
-- Sin políticas de insert/update para "authenticated": todo pasa por las funciones de abajo.

-- ============ PROMOTORÍA/AGENCIA: cuánto tienen pendiente de solicitar ============
create or replace function public.mi_residual_pendiente() returns json
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
  if not (public.es_promotoria() or public.es_agencia_maestra()) then
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
grant execute on function public.mi_residual_pendiente() to authenticated;

-- ============ PROMOTORÍA/AGENCIA: solicitar el pago de lo pendiente ============
create or replace function public.solicitar_residual() returns json
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

  -- Aviso al fundador — mismo patrón que el resto de notificaciones (Resend vía pg_net). Si
  -- por lo que sea no hay llave configurada, la solicitud igual queda registrada y visible
  -- en /admin — el correo es solo una comodidad, no la fuente de verdad.
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'resend_api_key';
  if v_key is not null then
    perform net.http_post(
      url := 'https://api.resend.com/emails',
      headers := jsonb_build_object('Authorization','Bearer '||v_key,'Content-Type','application/json'),
      body := jsonb_build_object(
        'from','Upco InsurGest <notificaciones@upco.app>',
        'to', jsonb_build_array('springradio190@gmail.com'),
        'reply_to', v_correo,
        'subject', format('Solicitud de comisión — %s', v_nombre),
        'html', format(
          '<p><strong>%s</strong> (%s, %s) solicitó el pago de su comisión acumulada: <strong>$%s MXN</strong>.</p><p>Revísalo y márcalo como pagado desde /admin → Comisiones.</p>',
          v_nombre, v_correo,
          case when v_tipo='promotoria' then 'promotoría' else 'agencia máster' end,
          to_char(v_pendiente,'FM999,999,990.00')
        )
      )
    );
  end if;

  return json_build_object('ok', true, 'monto', v_pendiente);
end;
$$;
grant execute on function public.solicitar_residual() to authenticated;

-- ============ ADMIN: ver y atender solicitudes ============
create or replace function public.admin_solicitudes_residual() returns json
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
        coalesce(pr.nombre_negocio, ag.nombre_negocio) as nombre,
        coalesce(pr.correo, ag.correo) as correo
      from solicitudes_residual sr
      left join promotorias pr on pr.id = sr.remitente_id and sr.remitente_tipo = 'promotoria'
      left join agencias_maestras ag on ag.id = sr.remitente_id and sr.remitente_tipo = 'agencia_maestra'
    ) t
  ), '[]'::json);
end;
$$;
grant execute on function public.admin_solicitudes_residual() to authenticated;

create or replace function public.admin_marcar_residual(p_id uuid, p_estatus text, p_nota text default null) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  if p_estatus not in ('pagado','rechazado','solicitado') then raise exception 'Estatus inválido'; end if;
  update solicitudes_residual set
    estatus = p_estatus,
    nota_admin = coalesce(p_nota, nota_admin),
    atendido_en = case when p_estatus in ('pagado','rechazado') then now() else null end
  where id = p_id;
end;
$$;
grant execute on function public.admin_marcar_residual(uuid,text,text) to authenticated;
