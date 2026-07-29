-- Upco InsurGest — Sesión 31: el fundador invita a probar InsurGest a cualquier correo
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- Mismo patrón de siempre (Resend vía pg_net), pero al revés de las demás notificaciones: aquí
-- el fundador es quien dispara el envío desde /admin, no un trigger automático. Guardamos un
-- registro de cada invitación para que quede historial de a quién ya se le mandó.

create table invitaciones_enviadas (
  id uuid primary key default gen_random_uuid(),
  correo text not null,
  nombre text,
  enviada_en timestamptz not null default now()
);

alter table invitaciones_enviadas enable row level security;

create policy "admin ve invitaciones enviadas" on invitaciones_enviadas for select using (public.es_admin());

create or replace function public.admin_enviar_invitacion(
  p_correo text,
  p_nombre text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text;
  v_id uuid;
  v_correo text := lower(trim(coalesce(p_correo,'')));
  v_nombre text := nullif(trim(coalesce(p_nombre,'')),'');
begin
  if not public.es_admin() then
    raise exception 'No autorizado';
  end if;
  if v_correo !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'Correo inválido';
  end if;

  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'resend_api_key';
  if v_key is null then
    raise exception 'No se pudo enviar: falta configurar el correo de notificaciones';
  end if;

  perform net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization','Bearer '||v_key,'Content-Type','application/json'),
    body := jsonb_build_object(
      'from','Upco InsurGest <notificaciones@upco.app>',
      'to', jsonb_build_array(v_correo),
      'reply_to','springradio190@gmail.com',
      'subject', case when v_nombre is not null then 'Te invitamos a probar Upco InsurGest, '||v_nombre else 'Te invitamos a probar Upco InsurGest' end,
      'html', format(
        '<p>Hola%s,</p>
        <p><strong>Los olvidos cuestan dinero.</strong> Upco InsurGest es el software para agentes de seguros independientes que ordena tu cartera, te avisa antes de que se te venza una póliza, y te ayuda a conseguir clientes nuevos con tu propia tarjeta digital.</p>
        <p>Te invitamos a probarlo gratis 30 días — tu cuenta queda activa de inmediato, sin esperar aprobación.</p>
        <p><a href="https://insurgest.upco.app/app/?registro=1" style="display:inline-block;background:#10284A;color:#ffffff;text-decoration:none;padding:14px 26px;border-radius:10px;font-weight:700">Crear mi cuenta gratis</a></p>
        <p style="color:#8FA0B4;font-size:13px">O copia esta liga: https://insurgest.upco.app/app/?registro=1</p>',
        case when v_nombre is not null then ' '||v_nombre else '' end
      )
    )
  );

  insert into invitaciones_enviadas(correo,nombre) values (v_correo,v_nombre)
  returning id into v_id;

  return v_id;
end;
$$;
revoke all on function public.admin_enviar_invitacion(text,text) from public;
grant execute on function public.admin_enviar_invitacion(text,text) to authenticated;

create or replace function public.admin_invitaciones() returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then
    raise exception 'No autorizado';
  end if;
  return coalesce((select json_agg(t order by t.enviada_en desc) from invitaciones_enviadas t), '[]'::json);
end;
$$;
revoke all on function public.admin_invitaciones() from public;
grant execute on function public.admin_invitaciones() to authenticated;
