-- Upco InsurGest — Sesión 56: blindar el HTML del correo de invitación contra "modo oscuro"
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- El HTML de admin_enviar_invitacion no fijaba color de fondo ni de texto en sus párrafos —
-- dependía del color por default del cliente de correo. En clientes que aplican modo oscuro
-- automático sin repintar bien el texto (Outlook sobre todo), eso puede dejar texto oscuro
-- sobre fondo oscuro, casi ilegible. Se reescribe el cuerpo con fondo y color explícitos en
-- cada elemento (patrón "bulletproof" de correo HTML) para que se vea igual sin importar el
-- cliente o el tema del destinatario. Firma y lógica de la función no cambian, solo el HTML.

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
      'reply_to','hola@upco.app',
      'subject', case when v_nombre is not null then 'Te invitamos a probar Upco InsurGest, '||v_nombre else 'Te invitamos a probar Upco InsurGest' end,
      'html', format(
        '<div style="background-color:#F4F7FB;padding:32px 16px;">
          <div style="max-width:560px;margin:0 auto;background-color:#ffffff;border-radius:12px;padding:32px 28px;font-family:-apple-system,''Segoe UI'',Arial,sans-serif;">
            <p style="margin:0 0 16px;color:#0a1c35;font-size:15px;line-height:1.6;">Hola%s,</p>
            <p style="margin:0 0 16px;color:#0a1c35;font-size:15px;line-height:1.6;"><strong style="color:#10284A;">Los olvidos cuestan dinero.</strong> Upco InsurGest es el software para agentes de seguros independientes que ordena tu cartera, te avisa antes de que se te venza una póliza, y te ayuda a conseguir clientes nuevos con tu propia tarjeta digital.</p>
            <p style="margin:0 0 24px;color:#0a1c35;font-size:15px;line-height:1.6;">Te invitamos a probarlo gratis 30 días — tu cuenta queda activa de inmediato, sin esperar aprobación.</p>
            <p style="margin:0 0 12px;"><a href="https://insurgest.upco.app/app/?registro=1" style="display:inline-block;background-color:#10284A;color:#ffffff;text-decoration:none;padding:14px 26px;border-radius:10px;font-weight:700;font-size:14.5px;">Crear mi cuenta gratis</a></p>
            <p style="margin:0;color:#8FA0B4;font-size:13px;">O copia esta liga: https://insurgest.upco.app/app/?registro=1</p>
          </div>
        </div>',
        case when v_nombre is not null then ' '||v_nombre else '' end
      )
    )
  );

  insert into invitaciones_enviadas(correo,nombre) values (v_correo,v_nombre)
  returning id into v_id;

  return v_id;
end;
$$;
