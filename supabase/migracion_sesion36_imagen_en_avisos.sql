-- Upco InsurGest — Sesión 36: adjuntar una imagen (arte de aseguradora, póster de Canva) a los avisos
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- Solo aplica al correo — un push no puede llevar un póster completo, cuando mucho un ícono
-- pequeño, así que esto no toca la Edge Function de push. El bucket es público (como
-- 'tarjetas'): Resend necesita poder descargar la imagen desde una URL sin autenticación para
-- incrustarla en el correo del cliente.

insert into storage.buckets (id, name, public) values ('avisos-adjuntos', 'avisos-adjuntos', true)
on conflict (id) do nothing;

create policy "dueno sube su adjunto de avisos"
on storage.objects for insert
with check (bucket_id = 'avisos-adjuntos' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "dueno ve su adjunto de avisos"
on storage.objects for select
using (bucket_id = 'avisos-adjuntos' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "dueno actualiza su adjunto de avisos"
on storage.objects for update
using (bucket_id = 'avisos-adjuntos' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "dueno borra su adjunto de avisos"
on storage.objects for delete
using (bucket_id = 'avisos-adjuntos' and (storage.foldername(name))[1] = auth.uid()::text);

-- ============ AGENTE -> SUS CLIENTES (con imagen opcional) ============
-- Cambia la firma (nuevo parámetro), así que hay que quitar la versión vieja explícitamente:
-- si no, PostgREST se queda sirviendo la anterior desde su caché de esquema.
drop function if exists public.agente_notificar_clientes(uuid[],text,text,boolean,boolean);

create or replace function public.agente_notificar_clientes(
  p_cliente_ids uuid[], p_asunto text, p_mensaje text, p_via_correo boolean, p_via_push boolean,
  p_imagen_url text default null
) returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text; v_push_secret text; v_agente record; r record;
  v_correos int := 0; v_push int := 0;
  v_asunto_plano text := public.texto_plano_aviso(p_asunto);
  v_mensaje_plano text := public.texto_plano_aviso(p_mensaje);
  v_imagen_html text := case when p_imagen_url is not null
    then format('<p><img src="%s" alt="" style="max-width:100%%;border-radius:8px" /></p>', p_imagen_url)
    else '' end;
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
          'subject', v_asunto_plano,
          'html', format('<p>Hola %s,</p><p>%s</p>%s<p style="color:#8FA0B4;font-size:12px">Mensaje de %s a través de Upco InsurGest.</p>',
            split_part(r.nombre,' ',1), public.formatear_mensaje_aviso(p_mensaje), v_imagen_html, coalesce(v_agente.nombre, v_agente.correo))
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
        body := jsonb_build_object('cliente_id', r.id, 'title', v_asunto_plano, 'body', v_mensaje_plano, 'url', 'https://insurgest.upco.app')
      );
      v_push := v_push + 1;
    end if;
  end loop;

  insert into avisos_masivos_log(remitente_id, remitente_tipo) values (auth.uid(), 'agente');
  return json_build_object('correos_enviados', v_correos, 'push_disparados', v_push);
end;
$$;
grant execute on function public.agente_notificar_clientes(uuid[],text,text,boolean,boolean,text) to authenticated;

-- ============ PROMOTORÍA -> SUS AGENTES Y/O CLIENTES DIRECTOS (con imagen opcional) ============
drop function if exists public.promotoria_notificar(uuid[],uuid[],text,text,boolean,boolean);

create or replace function public.promotoria_notificar(
  p_agente_ids uuid[], p_cliente_ids uuid[], p_asunto text, p_mensaje text, p_via_correo boolean, p_via_push boolean,
  p_imagen_url text default null
) returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text; v_push_secret text; v_promo record; r record;
  v_correos int := 0; v_push int := 0;
  v_asunto_plano text := public.texto_plano_aviso(p_asunto);
  v_mensaje_plano text := public.texto_plano_aviso(p_mensaje);
  v_imagen_html text := case when p_imagen_url is not null
    then format('<p><img src="%s" alt="" style="max-width:100%%;border-radius:8px" /></p>', p_imagen_url)
    else '' end;
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
          'subject', v_asunto_plano,
          'html', format('<p>Hola %s,</p><p>%s</p>%s<p style="color:#8FA0B4;font-size:12px">Mensaje de tu promotoría %s.</p>',
            coalesce(r.nombre,'agente'), public.formatear_mensaje_aviso(p_mensaje), v_imagen_html, coalesce(v_promo.nombre_negocio, v_promo.correo))
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
        body := jsonb_build_object('agente_id', r.id, 'title', v_asunto_plano, 'body', v_mensaje_plano, 'url', 'https://insurgest.upco.app/app/')
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
          'subject', v_asunto_plano,
          'html', format('<p>Hola %s,</p><p>%s</p>%s', split_part(r.nombre,' ',1), public.formatear_mensaje_aviso(p_mensaje), v_imagen_html)
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
        body := jsonb_build_object('cliente_id', r.id, 'title', v_asunto_plano, 'body', v_mensaje_plano, 'url', 'https://insurgest.upco.app')
      );
      v_push := v_push + 1;
    end if;
  end loop;

  insert into avisos_masivos_log(remitente_id, remitente_tipo) values (auth.uid(), 'promotoria');
  return json_build_object('correos_enviados', v_correos, 'push_disparados', v_push);
end;
$$;
grant execute on function public.promotoria_notificar(uuid[],uuid[],text,text,boolean,boolean,text) to authenticated;
