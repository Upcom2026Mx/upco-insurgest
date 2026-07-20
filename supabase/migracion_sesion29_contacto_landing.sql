-- Upco InsurGest — Sesión 29: botón "Quiero más información" en la landing pública
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- Mismo patrón que tarjeta_contactar (Sesión 16) y solicitudes_servicio (Sesión 16): una tabla,
-- un RPC público sin login (para quien todavía no es agente) y un correo al fundador vía Resend.
-- A diferencia de tarjeta_contactar, aquí no hay un agente específico al que avisar — quien
-- pregunta desde la landing todavía no eligió a nadie, así que el aviso va directo al fundador.

create table contactos_landing (
  id uuid primary key default gen_random_uuid(),
  nombre text not null,
  correo text,
  telefono text,
  mensaje text,
  estatus text not null default 'nuevo' check (estatus in ('nuevo','atendido')),
  created_at timestamptz not null default now()
);

alter table contactos_landing enable row level security;

-- Solo el fundador puede leerlos/marcarlos — el formulario público inserta a través del RPC
-- de abajo, nunca directo sobre la tabla.
create policy "admin ve contactos de landing" on contactos_landing for select using (public.es_admin());
create policy "admin marca contactos de landing" on contactos_landing for update using (public.es_admin());

create or replace function public.landing_crear_contacto(
  p_nombre text,
  p_correo text default null,
  p_telefono text default null,
  p_mensaje text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if p_nombre is null or length(trim(p_nombre)) = 0 then
    raise exception 'Necesitamos tu nombre';
  end if;
  if coalesce(p_correo,'') = '' and coalesce(p_telefono,'') = '' then
    raise exception 'Déjanos un correo o un teléfono para poder contactarte';
  end if;

  insert into contactos_landing(nombre,correo,telefono,mensaje)
  values (
    trim(p_nombre),
    nullif(trim(coalesce(p_correo,'')),''),
    nullif(trim(coalesce(p_telefono,'')),''),
    nullif(trim(coalesce(p_mensaje,'')),'')
  )
  returning id into v_id;

  return v_id;
end;
$$;
revoke all on function public.landing_crear_contacto(text,text,text,text) from public;
grant execute on function public.landing_crear_contacto(text,text,text,text) to anon, authenticated;

-- Aviso al fundador. reply_to queda apuntando al correo de quien preguntó (cuando lo dejó) para
-- poder contestarle con solo darle "Responder" — es justo el punto de la función: que revisarlo
-- desde el correo alcance para generar confianza, sin tener que entrar a ningún panel.
create or replace function public.notificar_nuevo_contacto_landing() returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text;
  v_mensaje_html text;
  v_body jsonb;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'resend_api_key';
  if v_key is null then return new; end if;

  v_mensaje_html := case when new.mensaje is not null then '<p><em>'||new.mensaje||'</em></p>' else '' end;

  v_body := jsonb_build_object(
    'from','Upco InsurGest <notificaciones@upco.app>',
    'to', jsonb_build_array('springradio190@gmail.com'),
    'subject','Alguien quiere más información: '||new.nombre,
    'html', format(
      '<p><strong>%s</strong> pidió más información desde la página.</p><p>Correo: %s<br/>Teléfono: %s</p>%s',
      new.nombre, coalesce(new.correo,'—'), coalesce(new.telefono,'—'), v_mensaje_html
    )
  );
  if new.correo is not null then
    v_body := v_body || jsonb_build_object('reply_to', new.correo);
  end if;

  perform net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization','Bearer '||v_key,'Content-Type','application/json'),
    body := v_body
  );
  return new;
end;
$$;

drop trigger if exists trg_notificar_contacto_landing on contactos_landing;
create trigger trg_notificar_contacto_landing
after insert on contactos_landing
for each row execute function notificar_nuevo_contacto_landing();
