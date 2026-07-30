-- Upco InsurGest — Sesión 32: tarjeta digital pública para promotorías
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- Mismo patrón que la tarjeta del agente (Sesión 16), pero a nivel promotoría: alias propio,
-- WhatsApp/correo de la promotoría, y sus propios prospectos. Se usa una tabla separada
-- (prospectos_promotoria) en vez de reutilizar "solicitudes" a propósito — esa tabla ya tiene
-- su lógica de agente_id/cliente_id bien probada, y tocarla para meter un tercer dueño posible
-- (promotoria_id) arriesgaba romper algo que ya funciona. El bucket 'tarjetas' sí se reutiliza
-- tal cual: sus políticas solo revisan la carpeta contra auth.uid(), sin importar si el dueño
-- es un agente o una promotoría.

alter table promotorias add column alias_publico text unique;
alter table promotorias add column tarjeta_activa boolean not null default false;
alter table promotorias add column tarjeta_titulo text;
alter table promotorias add column tarjeta_bio text;
alter table promotorias add column tarjeta_whatsapp text;
alter table promotorias add column tarjeta_correo_publico text;
alter table promotorias add column tarjeta_foto_path text;
alter table promotorias add column tarjeta_foto_url text;

create table prospectos_promotoria (
  id uuid primary key default gen_random_uuid(),
  promotoria_id uuid not null references promotorias(id) on delete cascade,
  nombre text not null,
  correo text,
  telefono text,
  ramo_interes text,
  descripcion text,
  estatus text not null default 'nueva' check (estatus in ('nueva','atendida')),
  created_at timestamptz not null default now()
);
create index idx_prospectos_promotoria on prospectos_promotoria(promotoria_id);

alter table prospectos_promotoria enable row level security;
create policy "promotoria ve sus prospectos" on prospectos_promotoria for select using (promotoria_id = auth.uid());
create policy "promotoria marca sus prospectos" on prospectos_promotoria for update using (promotoria_id = auth.uid());

-- ============ CONFIGURAR LA TARJETA (promotoría) ============
create or replace function public.promotoria_alias_disponible(p_alias text) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v text := lower(trim(p_alias));
begin
  if v !~ '^[a-z0-9][a-z0-9-]{2,29}$' then return false; end if;
  if public.alias_reservado(v) then return false; end if;
  return not exists (select 1 from promotorias where alias_publico = v and id <> auth.uid());
end;
$$;
grant execute on function public.promotoria_alias_disponible(text) to authenticated;

create or replace function public.promotoria_guardar_tarjeta(
  p_alias text,
  p_activa boolean,
  p_titulo text default null,
  p_bio text default null,
  p_whatsapp text default null,
  p_correo_publico text default null,
  p_foto_path text default null,
  p_foto_url text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v text := lower(trim(p_alias));
begin
  if not public.es_promotoria() then
    raise exception 'No autorizado';
  end if;
  if v !~ '^[a-z0-9][a-z0-9-]{2,29}$' then
    raise exception 'La dirección solo puede llevar minúsculas, números y guiones (3 a 30 caracteres)';
  end if;
  if public.alias_reservado(v) then
    raise exception 'Esa dirección está reservada, elige otra';
  end if;
  if exists (select 1 from promotorias where alias_publico = v and id <> auth.uid()) then
    raise exception 'Esa dirección ya la tiene otra promotoría, elige otra';
  end if;

  update promotorias set
    alias_publico = v,
    tarjeta_activa = p_activa,
    tarjeta_titulo = p_titulo,
    tarjeta_bio = p_bio,
    tarjeta_whatsapp = p_whatsapp,
    tarjeta_correo_publico = p_correo_publico,
    tarjeta_foto_path = coalesce(p_foto_path, tarjeta_foto_path),
    tarjeta_foto_url = coalesce(p_foto_url, tarjeta_foto_url)
  where id = auth.uid();
end;
$$;
grant execute on function public.promotoria_guardar_tarjeta(text,boolean,text,text,text,text,text,text) to authenticated;

-- ============ VER LA TARJETA (público, sin login) ============
create or replace function public.tarjeta_promotoria_publica(p_alias text) returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v json;
begin
  select json_build_object(
    'nombre_negocio', p.nombre_negocio,
    'titulo', p.tarjeta_titulo,
    'bio', p.tarjeta_bio,
    'whatsapp', p.tarjeta_whatsapp,
    'correo', p.tarjeta_correo_publico,
    'foto_url', p.tarjeta_foto_url,
    'alias', p.alias_publico
  ) into v
  from promotorias p
  where p.alias_publico = lower(trim(p_alias))
    and p.tarjeta_activa = true
    and p.estatus_aprobacion = 'aprobado';

  return v;
end;
$$;
revoke all on function public.tarjeta_promotoria_publica(text) from public;
grant execute on function public.tarjeta_promotoria_publica(text) to anon, authenticated;

-- ============ CONTACTAR DESDE LA TARJETA (público, sin login) ============
create or replace function public.tarjeta_promotoria_contactar(
  p_alias text,
  p_nombre text,
  p_correo text default null,
  p_telefono text default null,
  p_ramo_interes text default null,
  p_descripcion text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_promotoria_id uuid;
  v_id uuid;
begin
  select id into v_promotoria_id from promotorias
  where alias_publico = lower(trim(p_alias)) and tarjeta_activa = true and estatus_aprobacion = 'aprobado';
  if v_promotoria_id is null then
    raise exception 'Tarjeta no disponible';
  end if;
  if p_nombre is null or length(trim(p_nombre)) = 0 then
    raise exception 'Necesitamos tu nombre';
  end if;
  if coalesce(p_correo,'') = '' and coalesce(p_telefono,'') = '' then
    raise exception 'Déjanos un correo o un teléfono para poder contactarte';
  end if;

  insert into prospectos_promotoria(promotoria_id,nombre,correo,telefono,ramo_interes,descripcion)
  values (v_promotoria_id, trim(p_nombre), nullif(trim(coalesce(p_correo,'')),''), nullif(trim(coalesce(p_telefono,'')),''), nullif(trim(coalesce(p_ramo_interes,'')),''), nullif(trim(coalesce(p_descripcion,'')),''))
  returning id into v_id;

  return v_id;
end;
$$;
revoke all on function public.tarjeta_promotoria_contactar(text,text,text,text,text,text) from public;
grant execute on function public.tarjeta_promotoria_contactar(text,text,text,text,text,text) to anon, authenticated;

-- ============ BANDEJA DE PROSPECTOS (promotoría) ============
create or replace function public.promotoria_prospectos() returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_promotoria() then
    raise exception 'No autorizado';
  end if;
  return coalesce((
    select json_agg(t order by t.created_at desc) from prospectos_promotoria t where t.promotoria_id = auth.uid()
  ), '[]'::json);
end;
$$;
grant execute on function public.promotoria_prospectos() to authenticated;

create or replace function public.promotoria_marcar_prospecto(p_id uuid, p_estatus text) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_promotoria() then
    raise exception 'No autorizado';
  end if;
  if p_estatus not in ('nueva','atendida') then
    raise exception 'Estatus inválido';
  end if;
  update prospectos_promotoria set estatus = p_estatus where id = p_id and promotoria_id = auth.uid();
end;
$$;
grant execute on function public.promotoria_marcar_prospecto(uuid,text) to authenticated;

-- ============ AVISO POR CORREO AL RECIBIR UN PROSPECTO ============
create or replace function public.notificar_nuevo_prospecto_promotoria() returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text;
  v_correo text;
  v_nombre_negocio text;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'resend_api_key';
  if v_key is null then return new; end if;

  select correo, nombre_negocio into v_correo, v_nombre_negocio from promotorias where id = new.promotoria_id;
  if v_correo is null then return new; end if;

  perform net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization','Bearer '||v_key,'Content-Type','application/json'),
    body := jsonb_build_object(
      'from','Upco InsurGest <notificaciones@upco.app>',
      'to', jsonb_build_array(v_correo),
      'subject','Nuevo prospecto desde tu tarjeta',
      'html', format(
        '<p>Hola%s,</p><p><strong>%s</strong> te mandó sus datos desde tu tarjeta digital.</p><p>Correo: %s<br/>Teléfono: %s</p><p>%s</p><p>Entra a tu panel de InsurGest para verlo completo.</p>',
        case when v_nombre_negocio is not null then ' '||v_nombre_negocio else '' end,
        new.nombre, coalesce(new.correo,'—'), coalesce(new.telefono,'—'), coalesce(new.descripcion,'')
      )
    )
  );
  return new;
end;
$$;

drop trigger if exists trg_notificar_prospecto_promotoria on prospectos_promotoria;
create trigger trg_notificar_prospecto_promotoria
after insert on prospectos_promotoria
for each row execute function notificar_nuevo_prospecto_promotoria();
