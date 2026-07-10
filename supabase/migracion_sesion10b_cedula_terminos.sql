-- Upco InsurGest — Cédula profesional, RFC y aceptación de términos en el registro de agentes
-- Pegar completo en Supabase > SQL Editor > New query > Run

alter table agentes add column if not exists rfc text;
alter table agentes add column if not exists tiene_cedula boolean not null default false;
alter table agentes add column if not exists tipos_cedula text[];
alter table agentes add column if not exists numero_cedula text;
alter table agentes add column if not exists acepto_terminos boolean not null default false;
alter table agentes add column if not exists acepto_terminos_version text;
alter table agentes add column if not exists acepto_terminos_fecha timestamptz;

-- Se actualiza el listado que ve el fundador en /admin para incluir estos datos
create or replace function public.admin_agentes() returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then
    raise exception 'No autorizado';
  end if;
  return coalesce((
    select json_agg(t order by t.creado desc) from (
      select
        a.id, a.nombre, a.correo, a.telefono, a.nombre_negocio, a.estatus_aprobacion,
        a.rfc, a.tiene_cedula, a.tipos_cedula, a.numero_cedula,
        a.acepto_terminos, a.acepto_terminos_version, a.acepto_terminos_fecha,
        a.created_at as creado,
        (select count(*) from clientes c where c.agente_id = a.id) as clientes,
        (select count(*) from polizas p join clientes c on c.id = p.cliente_id where c.agente_id = a.id) as polizas
      from agentes a
    ) t
  ), '[]'::json);
end;
$$;
