-- Upco InsurGest — Tarjeta digital pública del agente + prospectos + solicitudes de servicio
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- ANTES DE CORRER: crear el bucket de fotos en Storage > New bucket
--   nombre: tarjetas    |    Public bucket: SÍ (marcado)
-- Es el único bucket público del proyecto, a propósito: la foto de una tarjeta de presentación
-- es material que el agente publica deliberadamente. Un bucket privado con signed URL expiraría
-- y dejaría la tarjeta rota sin avisar.

-- ============ COLUMNAS DE LA TARJETA EN agentes ============
alter table agentes add column alias_publico text unique;
alter table agentes add column tarjeta_activa boolean not null default false;
alter table agentes add column tarjeta_titulo text;         -- ej. "Agente de seguros certificado"
alter table agentes add column tarjeta_bio text;
alter table agentes add column tarjeta_ramos text[];
alter table agentes add column tarjeta_whatsapp text;
alter table agentes add column tarjeta_correo_publico text; -- puede ser distinto al de su cuenta
alter table agentes add column tarjeta_foto_path text;
alter table agentes add column tarjeta_foto_url text;

-- ============ solicitudes: ahora también acepta prospectos (gente que aún no es cliente) ============
-- Hasta hoy toda solicitud venía de un cliente existente y el agente se deducía por el cliente.
-- Un prospecto no tiene cliente, así que el agente tiene que venir escrito en la propia fila.
alter table solicitudes add column agente_id uuid references agentes(id) on delete cascade;

update solicitudes s
set agente_id = c.agente_id
from clientes c
where c.id = s.cliente_id and s.agente_id is null;

alter table solicitudes alter column agente_id set not null;
alter table solicitudes alter column cliente_id drop not null;

alter table solicitudes add column prospecto_nombre text;
alter table solicitudes add column prospecto_correo text;
alter table solicitudes add column prospecto_telefono text;

-- O es de un cliente existente, o es un prospecto con nombre. Nunca las dos, nunca ninguna.
alter table solicitudes add constraint solicitudes_cliente_o_prospecto check (
  (cliente_id is not null and prospecto_nombre is null) or
  (cliente_id is null and prospecto_nombre is not null)
);

create index idx_solicitudes_agente on solicitudes(agente_id);

-- Las políticas viejas llegaban al agente cruzando por clientes; con cliente_id nulo eso deja de
-- funcionar (y de paso el join sobraba, ahora que agente_id está en la fila).
drop policy if exists "agente ve solicitudes de sus clientes" on solicitudes;
drop policy if exists "agente marca solicitudes de sus clientes" on solicitudes;

create policy "agente ve sus solicitudes" on solicitudes for select using (agente_id = auth.uid());
create policy "agente marca sus solicitudes" on solicitudes for update using (agente_id = auth.uid());

-- Mismo motivo en Storage: dejar de cruzar por clientes.
drop policy if exists "agente ve fotos de solicitudes de sus clientes" on storage.objects;
drop policy if exists "agente borra fotos de solicitudes de sus clientes" on storage.objects;

create policy "agente ve fotos de sus solicitudes"
on storage.objects for select
using (
  bucket_id = 'solicitudes' and
  exists (select 1 from solicitudes s where s.foto_path = storage.objects.name and s.agente_id = auth.uid())
);

create policy "agente borra fotos de sus solicitudes"
on storage.objects for delete
using (
  bucket_id = 'solicitudes' and
  exists (select 1 from solicitudes s where s.foto_path = storage.objects.name and s.agente_id = auth.uid())
);

-- portal_crear_solicitud ahora tiene que llenar agente_id también.
create or replace function public.portal_crear_solicitud(
  p_token uuid,
  p_tipo text,
  p_tipo_cambio text default null,
  p_ramo_interes text default null,
  p_descripcion text default null,
  p_foto_path text default null,
  p_poliza_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cliente_id uuid;
  v_agente_id uuid;
  v_id uuid;
begin
  select id, agente_id into v_cliente_id, v_agente_id from clientes where token_publico = p_token;
  if v_cliente_id is null then
    raise exception 'Liga inválida';
  end if;
  if p_tipo not in ('endoso','cotizacion') then
    raise exception 'Tipo de solicitud inválido';
  end if;

  insert into solicitudes(cliente_id,agente_id,tipo,tipo_cambio,ramo_interes,descripcion,foto_path,poliza_id)
  values (v_cliente_id,v_agente_id,p_tipo,p_tipo_cambio,p_ramo_interes,p_descripcion,p_foto_path,p_poliza_id)
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.portal_crear_solicitud(uuid,text,text,text,text,text,uuid) from public;
grant execute on function public.portal_crear_solicitud(uuid,text,text,text,text,text,uuid) to anon, authenticated;

-- El correo de aviso también cruzaba por clientes; ahora usa agente_id y sabe nombrar al prospecto.
create or replace function public.notificar_nueva_solicitud() returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text;
  v_agente_correo text;
  v_agente_nombre text;
  v_de text;
  v_detalle text;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'resend_api_key';
  if v_key is null then return new; end if;

  select a.correo, a.nombre into v_agente_correo, v_agente_nombre
  from agentes a where a.id = new.agente_id;

  if v_agente_correo is null then return new; end if;

  if new.cliente_id is not null then
    select nombre into v_de from clientes where id = new.cliente_id;
  else
    v_de := new.prospecto_nombre || ' (prospecto de tu tarjeta)';
  end if;

  v_detalle := case when new.tipo = 'endoso' then coalesce(new.tipo_cambio,'Cambio a su póliza')
                     else coalesce(new.ramo_interes,'Cotización') end;

  perform net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization','Bearer '||v_key,'Content-Type','application/json'),
    body := jsonb_build_object(
      'from','Upco InsurGest <notificaciones@upco.app>',
      'to', jsonb_build_array(v_agente_correo),
      'subject', case when new.cliente_id is null then 'Nuevo prospecto desde tu tarjeta'
                      when new.tipo = 'endoso' then 'Nueva solicitud de endoso'
                      else 'Nueva solicitud de cotización' end,
      'html', format('<p>Hola %s,</p><p><strong>%s</strong> te mandó una solicitud: <strong>%s</strong>.</p><p>%s</p><p>%s</p><p>Entra a tu panel de InsurGest para verla completa.</p>',
        coalesce(v_agente_nombre,'agente'), v_de, v_detalle, coalesce(new.descripcion,''),
        case when new.cliente_id is null then
          coalesce('Contacto: '||coalesce(new.prospecto_correo,'')||' '||coalesce(new.prospecto_telefono,''),'')
        else '' end)
    )
  );
  return new;
end;
$$;

-- ============ CONFIGURAR LA TARJETA (agente) ============
-- Rutas que ya existen o que podríamos querer después: nadie puede quedarse con ellas de alias.
create or replace function public.alias_reservado(p_alias text) returns boolean
language sql
immutable
as $$
  select p_alias in (
    'app','admin','promotor','a','p','precios','terminos','soporte','ayuda','contacto',
    'api','assets','static','index','sw','404','www','upco','insurgest','blog','login','registro'
  );
$$;

create or replace function public.alias_disponible(p_alias text) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v text := lower(trim(p_alias));
begin
  if v !~ '^[a-z0-9][a-z0-9-]{2,29}$' then return false; end if;
  if public.alias_reservado(v) then return false; end if;
  return not exists (select 1 from agentes where alias_publico = v and id <> auth.uid());
end;
$$;
grant execute on function public.alias_disponible(text) to authenticated;

create or replace function public.agente_guardar_tarjeta(
  p_alias text,
  p_activa boolean,
  p_titulo text default null,
  p_bio text default null,
  p_ramos text[] default null,
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
  if v !~ '^[a-z0-9][a-z0-9-]{2,29}$' then
    raise exception 'La dirección solo puede llevar minúsculas, números y guiones (3 a 30 caracteres)';
  end if;
  if public.alias_reservado(v) then
    raise exception 'Esa dirección está reservada, elige otra';
  end if;
  if exists (select 1 from agentes where alias_publico = v and id <> auth.uid()) then
    raise exception 'Esa dirección ya la tiene otro agente, elige otra';
  end if;

  update agentes set
    alias_publico = v,
    tarjeta_activa = p_activa,
    tarjeta_titulo = p_titulo,
    tarjeta_bio = p_bio,
    tarjeta_ramos = p_ramos,
    tarjeta_whatsapp = p_whatsapp,
    tarjeta_correo_publico = p_correo_publico,
    tarjeta_foto_path = coalesce(p_foto_path, tarjeta_foto_path),
    tarjeta_foto_url = coalesce(p_foto_url, tarjeta_foto_url)
  where id = auth.uid();
end;
$$;
grant execute on function public.agente_guardar_tarjeta(text,boolean,text,text,text[],text,text,text,text) to authenticated;

-- ============ VER LA TARJETA (público, sin login) ============
-- Superficie mínima a propósito: solo lo que el agente eligió publicar. Nunca su correo de
-- cuenta, su RFC, ni nada de sus clientes.
create or replace function public.tarjeta_publica(p_alias text) returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v json;
begin
  select json_build_object(
    'nombre', a.nombre,
    'nombre_negocio', a.nombre_negocio,
    'titulo', a.tarjeta_titulo,
    'bio', a.tarjeta_bio,
    'ramos', a.tarjeta_ramos,
    'telefono', a.telefono,
    'whatsapp', a.tarjeta_whatsapp,
    'correo', a.tarjeta_correo_publico,
    'foto_url', a.tarjeta_foto_url,
    'numero_cedula', a.numero_cedula,
    'tipos_cedula', a.tipos_cedula,
    'alias', a.alias_publico
  ) into v
  from agentes a
  where a.alias_publico = lower(trim(p_alias))
    and a.tarjeta_activa = true
    and a.estatus_aprobacion = 'aprobado';

  return v;  -- null si no existe, está apagada, o el agente no está aprobado
end;
$$;
revoke all on function public.tarjeta_publica(text) from public;
grant execute on function public.tarjeta_publica(text) to anon, authenticated;

-- ============ CONTACTAR DESDE LA TARJETA (público, sin login) ============
create or replace function public.tarjeta_contactar(
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
  v_agente_id uuid;
  v_id uuid;
begin
  select id into v_agente_id from agentes
  where alias_publico = lower(trim(p_alias)) and tarjeta_activa = true and estatus_aprobacion = 'aprobado';
  if v_agente_id is null then
    raise exception 'Tarjeta no disponible';
  end if;
  if p_nombre is null or length(trim(p_nombre)) = 0 then
    raise exception 'Necesitamos tu nombre';
  end if;
  if coalesce(p_correo,'') = '' and coalesce(p_telefono,'') = '' then
    raise exception 'Déjanos un correo o un teléfono para poder contactarte';
  end if;

  insert into solicitudes(agente_id,tipo,ramo_interes,descripcion,prospecto_nombre,prospecto_correo,prospecto_telefono)
  values (v_agente_id,'cotizacion',p_ramo_interes,p_descripcion,trim(p_nombre),nullif(trim(coalesce(p_correo,'')),''),nullif(trim(coalesce(p_telefono,'')),''))
  returning id into v_id;

  return v_id;
end;
$$;
revoke all on function public.tarjeta_contactar(text,text,text,text,text,text) from public;
grant execute on function public.tarjeta_contactar(text,text,text,text,text,text) to anon, authenticated;

-- ============ FOTO DE LA TARJETA (Storage, bucket público 'tarjetas') ============
-- La lectura es pública (así lo es el bucket); escribir solo en la carpeta propia.
create policy "agente sube su foto de tarjeta"
on storage.objects for insert
with check (bucket_id = 'tarjetas' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "agente actualiza su foto de tarjeta"
on storage.objects for update
using (bucket_id = 'tarjetas' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "agente borra su foto de tarjeta"
on storage.objects for delete
using (bucket_id = 'tarjetas' and (storage.foldername(name))[1] = auth.uid()::text);

-- ============ SOLICITUDES DE SERVICIO (sitio web / correo propio que vende el fundador) ============
create table solicitudes_servicio (
  id uuid primary key default gen_random_uuid(),
  solicitante_id uuid not null,               -- auth.uid() del agente o de la promotoría
  solicitante_tipo text not null check (solicitante_tipo in ('agente','promotoria')),
  servicio text not null check (servicio in ('sitio_web','correo','ambos')),
  notas text,
  estatus text not null default 'nueva' check (estatus in ('nueva','atendida')),
  created_at timestamptz not null default now()
);
alter table solicitudes_servicio enable row level security;

create policy "veo mis solicitudes de servicio" on solicitudes_servicio
for select using (solicitante_id = auth.uid());

create or replace function public.solicitar_servicio(p_servicio text, p_notas text default null) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tipo text;
  v_id uuid;
begin
  if p_servicio not in ('sitio_web','correo','ambos') then
    raise exception 'Servicio inválido';
  end if;
  if exists (select 1 from agentes where id = auth.uid()) then
    v_tipo := 'agente';
  elsif exists (select 1 from promotorias where id = auth.uid()) then
    v_tipo := 'promotoria';
  else
    raise exception 'No autorizado';
  end if;

  insert into solicitudes_servicio(solicitante_id,solicitante_tipo,servicio,notas)
  values (auth.uid(), v_tipo, p_servicio, p_notas)
  returning id into v_id;

  return v_id;
end;
$$;
grant execute on function public.solicitar_servicio(text,text) to authenticated;

create or replace function public.admin_solicitudes_servicio() returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  return coalesce((
    select json_agg(t order by t.created_at desc) from (
      select s.*,
        coalesce(a.nombre, p.nombre) as solicitante_nombre,
        coalesce(a.correo, p.correo) as solicitante_correo,
        coalesce(a.telefono, null) as solicitante_telefono,
        coalesce(a.nombre_negocio, p.nombre_negocio) as solicitante_negocio
      from solicitudes_servicio s
      left join agentes a on a.id = s.solicitante_id and s.solicitante_tipo = 'agente'
      left join promotorias p on p.id = s.solicitante_id and s.solicitante_tipo = 'promotoria'
    ) t
  ), '[]'::json);
end;
$$;
grant execute on function public.admin_solicitudes_servicio() to authenticated;

create or replace function public.admin_marcar_servicio(p_id uuid, p_estatus text) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  if p_estatus not in ('nueva','atendida') then raise exception 'Estatus inválido'; end if;
  update solicitudes_servicio set estatus = p_estatus where id = p_id;
end;
$$;
grant execute on function public.admin_marcar_servicio(uuid,text) to authenticated;

-- Aviso al fundador cuando alguien pide sitio web o correo.
create or replace function public.notificar_solicitud_servicio() returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text;
  v_nombre text;
  v_correo text;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'resend_api_key';
  if v_key is null then return new; end if;

  if new.solicitante_tipo = 'agente' then
    select nombre, correo into v_nombre, v_correo from agentes where id = new.solicitante_id;
  else
    select nombre, correo into v_nombre, v_correo from promotorias where id = new.solicitante_id;
  end if;

  perform net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization','Bearer '||v_key,'Content-Type','application/json'),
    body := jsonb_build_object(
      'from','Upco InsurGest <notificaciones@upco.app>',
      'to', jsonb_build_array('springradio190@gmail.com'),
      'subject','Nueva solicitud de servicio (sitio web / correo)',
      'html', format('<p><strong>%s</strong> (%s, %s) pidió: <strong>%s</strong></p><p>%s</p>',
        coalesce(v_nombre,'—'), coalesce(v_correo,'—'), new.solicitante_tipo, new.servicio, coalesce(new.notas,''))
    )
  );
  return new;
end;
$$;

create trigger trg_notificar_servicio
after insert on solicitudes_servicio
for each row execute function notificar_solicitud_servicio();
