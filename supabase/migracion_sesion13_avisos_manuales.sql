-- Upco InsurGest — Avisos manuales (correo + push) desde el portal del agente y de la promotoría
-- Pegar completo en Supabase > SQL Editor > New query > Run

-- ============ push_subscripciones AHORA TAMBIÉN ACEPTA AGENTES ============
alter table push_subscripciones add column agente_id uuid references agentes(id) on delete cascade;
alter table push_subscripciones alter column cliente_id drop not null;
alter table push_subscripciones add constraint push_sub_cliente_o_agente check (
  (cliente_id is not null and agente_id is null) or (cliente_id is null and agente_id is not null)
);

-- ============ EL AGENTE SE SUSCRIBE A PUSH (con su propia sesión, no por token) ============
create or replace function public.agente_suscribir_push(p_endpoint text, p_p256dh text, p_auth text) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists(select 1 from agentes where id = auth.uid()) then
    raise exception 'No autorizado';
  end if;
  insert into push_subscripciones (agente_id, endpoint, p256dh, auth)
  values (auth.uid(), p_endpoint, p_p256dh, p_auth)
  on conflict (endpoint) do update set agente_id = excluded.agente_id, cliente_id = null, p256dh = excluded.p256dh, auth = excluded.auth;
end;
$$;
grant execute on function public.agente_suscribir_push(text,text,text) to authenticated;

-- ============ AGENTE -> SUS CLIENTES ============
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

  return json_build_object('correos_enviados', v_correos, 'push_disparados', v_push);
end;
$$;
grant execute on function public.agente_notificar_clientes(uuid[],text,text,boolean,boolean) to authenticated;

-- ============ CLIENTES DE TODA LA RED DE LA PROMOTORÍA (para el selector) ============
create or replace function public.promotoria_clientes() returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_promotoria() then raise exception 'No autorizado'; end if;
  return coalesce((
    select json_agg(json_build_object(
      'id', c.id, 'nombre', c.nombre, 'correo', c.correo,
      'agente_nombre', coalesce(a.nombre, a.correo)
    ) order by a.nombre nulls last, c.nombre)
    from clientes c join agentes a on a.id = c.agente_id
    where a.promotoria_id = auth.uid()
  ), '[]'::json);
end;
$$;
grant execute on function public.promotoria_clientes() to authenticated;

-- ============ PROMOTORÍA -> SUS AGENTES Y/O LOS CLIENTES DIRECTOS DE ESOS AGENTES ============
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

  return json_build_object('correos_enviados', v_correos, 'push_disparados', v_push);
end;
$$;
grant execute on function public.promotoria_notificar(uuid[],uuid[],text,text,boolean,boolean) to authenticated;
