-- Upco InsurGest — Vincula cada solicitud de cambio a la póliza específica
-- Pegar completo en Supabase > SQL Editor > New query > Run

alter table solicitudes add column poliza_id uuid references polizas(id) on delete set null;

-- Cambia la firma (nuevo parámetro) — hay que tirar la versión vieja primero o PostgREST
-- se queda sirviendo la anterior desde su caché de esquema.
drop function if exists public.portal_crear_solicitud(uuid,text,text,text,text,text);

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
  v_id uuid;
begin
  select id into v_cliente_id from clientes where token_publico = p_token;
  if v_cliente_id is null then
    raise exception 'Liga inválida';
  end if;
  if p_tipo not in ('endoso','cotizacion') then
    raise exception 'Tipo de solicitud inválido';
  end if;
  if p_poliza_id is not null and not exists(select 1 from polizas where id = p_poliza_id and cliente_id = v_cliente_id) then
    raise exception 'Póliza inválida';
  end if;

  insert into solicitudes(cliente_id,tipo,tipo_cambio,ramo_interes,descripcion,foto_path,poliza_id)
  values (v_cliente_id,p_tipo,p_tipo_cambio,p_ramo_interes,p_descripcion,p_foto_path,p_poliza_id)
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.portal_crear_solicitud(uuid,text,text,text,text,text,uuid) from public;
grant execute on function public.portal_crear_solicitud(uuid,text,text,text,text,text,uuid) to anon, authenticated;
