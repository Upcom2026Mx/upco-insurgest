-- Upco InsurGest — Sesión 6: solicitudes desde el portal del cliente (endoso / cotización)
-- Pegar completo en Supabase > SQL Editor > New query > Run

-- ============ TABLA ============
create table solicitudes (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid not null references clientes(id) on delete cascade,
  tipo text not null check (tipo in ('endoso','cotizacion')),
  estatus text not null default 'nueva' check (estatus in ('nueva','atendida')),
  tipo_cambio text,      -- solo aplica a endoso (ej. "Cambio de domicilio")
  ramo_interes text,     -- solo aplica a cotizacion (ej. "Auto", "Vida"...)
  descripcion text,
  foto_path text,        -- ruta cruda en Storage (bucket 'solicitudes'), opcional
  created_at timestamptz not null default now()
);
create index idx_solicitudes_cliente on solicitudes(cliente_id);

alter table solicitudes enable row level security;

create policy "agente ve solicitudes de sus clientes" on solicitudes for select using (
  exists (select 1 from clientes c where c.id = solicitudes.cliente_id and c.agente_id = auth.uid())
);
create policy "agente marca solicitudes de sus clientes" on solicitudes for update using (
  exists (select 1 from clientes c where c.id = solicitudes.cliente_id and c.agente_id = auth.uid())
);

-- ============ CREACIÓN DESDE EL PORTAL (sin login) ============
-- Mismo patrón que portal_cliente: SECURITY DEFINER, filtra por token exacto,
-- así el cliente nunca necesita permiso directo de INSERT sobre la tabla.
create or replace function public.portal_crear_solicitud(
  p_token uuid,
  p_tipo text,
  p_tipo_cambio text default null,
  p_ramo_interes text default null,
  p_descripcion text default null,
  p_foto_path text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cliente_id uuid;
  v_id uuid;
begin
  select id into v_cliente_id from clientes where token_publico = p_token;
  if v_cliente_id is null then
    raise exception 'Liga inválida';
  end if;
  if p_tipo not in ('endoso','cotizacion') then
    raise exception 'Tipo de solicitud inválido';
  end if;

  -- si hay foto, se sube a Storage ANTES de llamar esta función (la ruta ya incluye el token
  -- como carpeta, así que no hace falta un segundo paso para "asignarla" después de crear la fila)
  insert into solicitudes(cliente_id,tipo,tipo_cambio,ramo_interes,descripcion,foto_path)
  values (v_cliente_id,p_tipo,p_tipo_cambio,p_ramo_interes,p_descripcion,p_foto_path)
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.portal_crear_solicitud(uuid,text,text,text,text,text) from public;
grant execute on function public.portal_crear_solicitud(uuid,text,text,text,text,text) to anon, authenticated;

-- ============ FOTO OPCIONAL DEL ENDOSO (Storage) ============
-- Bucket "solicitudes" debe crearse manualmente en el Dashboard (Storage > New bucket,
-- privado, sin marcar "Public bucket") antes de correr lo de abajo.
-- Cualquiera puede SUBIR (nunca listar/leer) — el archivo por sí solo no sirve de nada sin
-- saber su ruta exacta (uuid del cliente + uuid de la solicitud), y solo el agente dueño
-- de ese cliente puede generar un signed URL para verlo.
create policy "cualquiera puede subir fotos de solicitudes"
on storage.objects for insert
with check (bucket_id = 'solicitudes');

create policy "agente ve fotos de solicitudes de sus clientes"
on storage.objects for select
using (
  bucket_id = 'solicitudes' and
  exists (
    select 1 from solicitudes s join clientes c on c.id = s.cliente_id
    where s.foto_path = storage.objects.name and c.agente_id = auth.uid()
  )
);

-- necesaria para poder limpiar la foto cuando se borra la solicitud o el cliente completo
create policy "agente borra fotos de solicitudes de sus clientes"
on storage.objects for delete
using (
  bucket_id = 'solicitudes' and
  exists (
    select 1 from solicitudes s join clientes c on c.id = s.cliente_id
    where s.foto_path = storage.objects.name and c.agente_id = auth.uid()
  )
);
