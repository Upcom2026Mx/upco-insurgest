-- Upco InsurGest — Sesión 5: liga mágica del cliente
-- Pegar completo en Supabase > SQL Editor > New query > Run

-- 1) Token público único por cliente (la "liga mágica" es /p/{este token})
alter table clientes add column token_publico uuid not null default gen_random_uuid() unique;

-- 2) Separar la ruta cruda del archivo (pdf_path, para poder borrarlo/reemplazarlo)
--    del link de descarga final (pdf_url, que a partir de ahora es un signed URL de larga duración)
alter table polizas add column pdf_path text;

-- 3) Función pública (sin login) que entrega SOLO los datos del cliente dueño del token exacto.
--    SECURITY DEFINER = se ejecuta con permisos elevados, ignorando RLS, pero el filtro por
--    token_publico adentro de la función es lo único que decide qué se devuelve — nadie puede
--    listar clientes ni adivinar datos de otro cliente sin conocer su token exacto.
create or replace function public.portal_cliente(p_token uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  resultado json;
begin
  select json_build_object(
    'cliente', json_build_object(
      'nombre', c.nombre,
      'tipo_persona', c.tipo_persona
    ),
    'agente', json_build_object(
      'nombre', a.nombre,
      'nombre_negocio', a.nombre_negocio,
      'correo', a.correo,
      'telefono', a.telefono
    ),
    'polizas', coalesce((
      select json_agg(json_build_object(
        'id', p.id,
        'ramo', p.ramo,
        'aseguradora', p.aseguradora,
        'numero_poliza', p.numero_poliza,
        'fecha_inicio', p.fecha_inicio,
        'fecha_fin', p.fecha_fin,
        'estatus', p.estatus,
        'prima', p.prima,
        'forma_pago', p.forma_pago,
        'pdf_url', p.pdf_url,
        'vehiculo_id', p.vehiculo_id
      ) order by p.fecha_fin desc nulls last)
      from polizas p where p.cliente_id = c.id
    ), '[]'::json),
    'vehiculos', coalesce((
      select json_agg(json_build_object(
        'id', v.id,
        'placas', v.placas,
        'marca', v.marca,
        'modelo', v.modelo,
        'anio', v.anio,
        'tipo_vehiculo', v.tipo_vehiculo,
        'fecha_verificacion', v.fecha_verificacion
      ))
      from vehiculos v where v.cliente_id = c.id
    ), '[]'::json)
  ) into resultado
  from clientes c
  join agentes a on a.id = c.agente_id
  where c.token_publico = p_token;

  return resultado; -- null si el token no corresponde a ningún cliente
end;
$$;

revoke all on function public.portal_cliente(uuid) from public;
grant execute on function public.portal_cliente(uuid) to anon, authenticated;
