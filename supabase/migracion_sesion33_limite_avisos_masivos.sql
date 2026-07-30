-- Upco InsurGest — Sesión 33: tope de 5 envíos masivos (correo/push) cada 24 horas
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- El límite no es tanto por costo (Resend es barato) como por reputación del dominio: si una
-- cuenta manda avisos masivos sin control, los servidores de correo pueden empezar a marcar
-- upco.app como sospechoso — y eso afectaría a TODOS los agentes, incluidos los correos
-- automáticos críticos (avisos de vencimiento) de los que depende toda la plataforma. Por eso
-- el tope va a nivel de "cuántos envíos masivos por día", no de "cuántos destinatarios por
-- envío" — un agente con 200 clientes sigue pudiendo avisarles a todos de un jalón.

create table avisos_masivos_log (
  id uuid primary key default gen_random_uuid(),
  remitente_id uuid not null,
  remitente_tipo text not null check (remitente_tipo in ('agente','promotoria')),
  created_at timestamptz not null default now()
);
create index idx_avisos_masivos_log_remitente on avisos_masivos_log(remitente_id, created_at);

-- Sin políticas de select/insert para "authenticated": esta tabla solo se toca desde dentro de
-- funciones SECURITY DEFINER, nadie necesita leerla ni escribirla directo.
alter table avisos_masivos_log enable row level security;

create or replace function public.limite_avisos_alcanzado(p_remitente_id uuid) returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select count(*) >= 5 from avisos_masivos_log
  where remitente_id = p_remitente_id and created_at >= now() - interval '24 hours';
$$;

-- Para que la pantalla de Avisos pueda mostrar "te quedan N envíos hoy" antes de que truene.
create or replace function public.avisos_disponibles_hoy() returns int
language sql
stable
security definer
set search_path = public
as $$
  select greatest(0, 5 - count(*)::int) from avisos_masivos_log
  where remitente_id = auth.uid() and created_at >= now() - interval '24 hours';
$$;
grant execute on function public.avisos_disponibles_hoy() to authenticated;

-- ============ AGENTE -> SUS CLIENTES (con tope) ============
create or replace function public.agente_notificar_clientes(
  p_cliente_ids uuid[], p_asunto text, p_mensaje text, p_via_correo boolean, p_via_push boolean
) returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text; v_push_secret text; v_agente record; r record;
  v_correos int := 0; v_push int := 0;
begin
  select * into v_agente from agentes where id = auth.uid();
  if v_agente is null then raise exception 'No autorizado'; end if;
  if public.limite_avisos_alcanzado(auth.uid()) then
    raise exception 'Ya llegaste al límite de 5 envíos masivos en las últimas 24 horas. Intenta de nuevo más tarde.';
  end if;

  if p_via_correo then select decrypted_secret into v_key from vault.decrypted_secrets where name = 'resend_api_key'; end if;
  if p_via_push then select decrypted_secret into v_push_secret from vault.decrypted_secrets where name = 'push_internal_secret'; end if;

  for r in select id, nombre, correo from clientes where id = any(p_cliente_ids) and agente_id = auth.uid()
  loop
    if p_via_correo and v_key is not null and r.correo is not null then
      perform net.http_post(
        url := 'https://api.resend.com/emails',
        headers := jsonb_build_object('Authorization','Bearer '||v_key,'Content-Type','application/json'),
        body := jsonb_build_object(
          'from','Upco InsurGest <notificaciones@upco.app>',
          'to', jsonb_build_array(r.correo),
          'subject', p_asunto,
          'html', format('<p>Hola %s,</p><p>%s</p><p style="color:#8FA0B4;font-size:12px">Mensaje de %s a través de Upco InsurGest.</p>',
            split_part(r.nombre,' ',1), p_mensaje, coalesce(v_agente.nombre, v_agente.correo))
        )
      );
      v_correos := v_correos + 1;
    end if;
    if p_via_push and v_push_secret is not null then
      perform net.http_post(
        url := 'https://pxcvckqahkjlizgotvqw.supabase.co/functions/v1/send-push',
        headers := jsonb_build_object(
          'Content-Type','application/json',
          'Authorization','Bearer sb_publishable_F2WhknXrY8MLjI5ftd0H6w_-XXjej6I',
          'x-internal-secret', v_push_secret
        ),
        body := jsonb_build_object('cliente_id', r.id, 'title', p_asunto, 'body', p_mensaje, 'url', 'https://insurgest.upco.app')
      );
      v_push := v_push + 1;
    end if;
  end loop;

  insert into avisos_masivos_log(remitente_id, remitente_tipo) values (auth.uid(), 'agente');
  return json_build_object('correos_enviados', v_correos, 'push_disparados', v_push);
end;
$$;
grant execute on function public.agente_notificar_clientes(uuid[],text,text,boolean,boolean) to authenticated;

-- ============ PROMOTORÍA -> SUS AGENTES Y/O CLIENTES DIRECTOS (con tope) ============
create or replace function public.promotoria_notificar(
  p_agente_ids uuid[], p_cliente_ids uuid[], p_asunto text, p_mensaje text, p_via_correo boolean, p_via_push boolean
) returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text; v_push_secret text; v_promo record; r record;
  v_correos int := 0; v_push int := 0;
begin
  if not public.es_promotoria() then raise exception 'No autorizado'; end if;
  select * into v_promo from promotorias where id = auth.uid();
  if public.limite_avisos_alcanzado(auth.uid()) then
    raise exception 'Ya llegaste al límite de 5 envíos masivos en las últimas 24 horas. Intenta de nuevo más tarde.';
  end if;

  if p_via_correo then select decrypted_secret into v_key from vault.decrypted_secrets where name = 'resend_api_key'; end if;
  if p_via_push then select decrypted_secret into v_push_secret from vault.decrypted_secrets where name = 'push_internal_secret'; end if;

  -- a agentes de su red
  for r in select id, nombre, correo from agentes where id = any(p_agente_ids) and promotoria_id = auth.uid()
  loop
    if p_via_correo and v_key is not null and r.correo is not null then
      perform net.http_post(
        url := 'https://api.resend.com/emails',
        headers := jsonb_build_object('Authorization','Bearer '||v_key,'Content-Type','application/json'),
        body := jsonb_build_object(
          'from','Upco InsurGest <notificaciones@upco.app>',
          'to', jsonb_build_array(r.correo),
          'subject', p_asunto,
          'html', format('<p>Hola %s,</p><p>%s</p><p style="color:#8FA0B4;font-size:12px">Mensaje de tu promotoría %s.</p>',
            coalesce(r.nombre,'agente'), p_mensaje, coalesce(v_promo.nombre_negocio, v_promo.correo))
        )
      );
      v_correos := v_correos + 1;
    end if;
    if p_via_push and v_push_secret is not null then
      perform net.http_post(
        url := 'https://pxcvckqahkjlizgotvqw.supabase.co/functions/v1/send-push',
        headers := jsonb_build_object(
          'Content-Type','application/json',
          'Authorization','Bearer sb_publishable_F2WhknXrY8MLjI5ftd0H6w_-XXjej6I',
          'x-internal-secret', v_push_secret
        ),
        body := jsonb_build_object('agente_id', r.id, 'title', p_asunto, 'body', p_mensaje, 'url', 'https://insurgest.upco.app/app/')
      );
      v_push := v_push + 1;
    end if;
  end loop;

  -- a clientes directos de sus agentes
  for r in
    select c.id, c.nombre, c.correo
    from clientes c join agentes a on a.id = c.agente_id
    where c.id = any(p_cliente_ids) and a.promotoria_id = auth.uid()
  loop
    if p_via_correo and v_key is not null and r.correo is not null then
      perform net.http_post(
        url := 'https://api.resend.com/emails',
        headers := jsonb_build_object('Authorization','Bearer '||v_key,'Content-Type','application/json'),
        body := jsonb_build_object(
          'from','Upco InsurGest <notificaciones@upco.app>',
          'to', jsonb_build_array(r.correo),
          'subject', p_asunto,
          'html', format('<p>Hola %s,</p><p>%s</p>', split_part(r.nombre,' ',1), p_mensaje)
        )
      );
      v_correos := v_correos + 1;
    end if;
    if p_via_push and v_push_secret is not null then
      perform net.http_post(
        url := 'https://pxcvckqahkjlizgotvqw.supabase.co/functions/v1/send-push',
        headers := jsonb_build_object(
          'Content-Type','application/json',
          'Authorization','Bearer sb_publishable_F2WhknXrY8MLjI5ftd0H6w_-XXjej6I',
          'x-internal-secret', v_push_secret
        ),
        body := jsonb_build_object('cliente_id', r.id, 'title', p_asunto, 'body', p_mensaje, 'url', 'https://insurgest.upco.app')
      );
      v_push := v_push + 1;
    end if;
  end loop;

  insert into avisos_masivos_log(remitente_id, remitente_tipo) values (auth.uid(), 'promotoria');
  return json_build_object('correos_enviados', v_correos, 'push_disparados', v_push);
end;
$$;
grant execute on function public.promotoria_notificar(uuid[],uuid[],text,text,boolean,boolean) to authenticated;
