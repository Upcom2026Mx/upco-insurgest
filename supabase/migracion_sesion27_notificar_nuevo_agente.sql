-- Upco InsurGest — Avisa por correo al fundador cuando se registra un agente nuevo
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- Desde la Sesión 17 las cuentas se aprueban solas, así que ya no hay una pantalla de
-- "pendientes" que avisara de un registro nuevo por el simple hecho de tener que revisarlo.
-- Este trigger reemplaza esa visibilidad perdida: mismo patrón que notificar_solicitud_servicio
-- (Sesión 13) y notificar_nueva_solicitud (Sesión 6) — un correo vía Resend/pg_net al insertar.

create or replace function public.notificar_nuevo_agente() returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text;
  v_promotoria_nombre text;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'resend_api_key';
  if v_key is null then return new; end if;

  if new.promotoria_id is not null then
    select nombre_negocio into v_promotoria_nombre from promotorias where id = new.promotoria_id;
  end if;

  perform net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization','Bearer '||v_key,'Content-Type','application/json'),
    body := jsonb_build_object(
      'from','Upco InsurGest <notificaciones@upco.app>',
      'to', jsonb_build_array('springradio190@gmail.com'),
      'subject','Nuevo agente registrado: '||coalesce(new.nombre, new.correo),
      'html', format(
        '<p><strong>%s</strong> se acaba de registrar.</p>
        <p>Correo: %s<br/>Teléfono: %s<br/>Negocio: %s</p>
        <p>%s</p>
        <p><a href="https://insurgest.upco.app/admin/">Ver en el panel del fundador</a></p>',
        coalesce(new.nombre,'Sin nombre'),
        new.correo,
        coalesce(new.telefono,'—'),
        coalesce(new.nombre_negocio,'—'),
        case when v_promotoria_nombre is not null
          then '<strong>Llegó con código de la red: '||v_promotoria_nombre||'</strong> — confírmalo en "Red por confirmar" para que cuente en su cuota.'
          else 'Agente independiente, sin código de promotoría.'
        end
      )
    )
  );
  return new;
end;
$$;

drop trigger if exists trg_notificar_nuevo_agente on agentes;
create trigger trg_notificar_nuevo_agente
after insert on agentes
for each row execute function notificar_nuevo_agente();
