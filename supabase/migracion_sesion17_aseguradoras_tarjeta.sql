-- Upco InsurGest — La tarjeta del agente ahora muestra con qué aseguradoras trabaja
-- Pegar completo en Supabase > SQL Editor > New query > Run

alter table agentes add column tarjeta_aseguradoras text[];

-- agente_guardar_tarjeta cambia de firma (le entra un parámetro nuevo), así que hay que DROP
-- antes de recrear: si no, PostgREST se queda sirviendo la versión vieja desde su caché de
-- esquema y devuelve PGRST202. Ya nos pasó con portal_crear_solicitud en la Sesión 6.
drop function if exists public.agente_guardar_tarjeta(text,boolean,text,text,text[],text,text,text,text);

create or replace function public.agente_guardar_tarjeta(
  p_alias text,
  p_activa boolean,
  p_titulo text default null,
  p_bio text default null,
  p_ramos text[] default null,
  p_whatsapp text default null,
  p_correo_publico text default null,
  p_foto_path text default null,
  p_foto_url text default null,
  p_aseguradoras text[] default null
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
    tarjeta_aseguradoras = p_aseguradoras,
    tarjeta_foto_path = coalesce(p_foto_path, tarjeta_foto_path),
    tarjeta_foto_url = coalesce(p_foto_url, tarjeta_foto_url)
  where id = auth.uid();
end;
$$;
grant execute on function public.agente_guardar_tarjeta(text,boolean,text,text,text[],text,text,text,text,text[]) to authenticated;

-- tarjeta_publica no cambia de firma, solo agrega un campo a lo que devuelve.
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
    'aseguradoras', a.tarjeta_aseguradoras,
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

  return v;
end;
$$;
revoke all on function public.tarjeta_publica(text) from public;
grant execute on function public.tarjeta_publica(text) to anon, authenticated;
