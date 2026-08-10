-- ============================================================================
--  Sesión 48 — Filtros de prospectos por vista
--
--  Problema: admin_prospectos solo sabe filtrar por estatus, pero varias
--  tarjetas del panel no corresponden a un estatus:
--
--    "Sin contactar"     = estatus 'activo' y etapa 0
--    "A media secuencia" = estatus 'activo' y etapa 1 o 2
--    "Correos enviados"  = cualquiera que ya recibió algo (etapa > 0)
--
--  Se agrega el parámetro p_vista para poder hacer clic en cada tarjeta y
--  ver exactamente esas agencias. p_estatus sigue funcionando igual que antes.
--
--  Ejecutar completo en el editor SQL de Supabase.
-- ============================================================================

-- La firma cambia (un parámetro nuevo). Hay que eliminar la anterior primero:
-- si no, PostgreSQL deja las dos versiones y las llamadas quedan ambiguas.
drop function if exists public.admin_prospectos(text, text, text, int);

create or replace function public.admin_prospectos(
  p_estatus  text default null,
  p_ruta     text default null,
  p_busqueda text default null,
  p_limite   int  default 200,
  p_vista    text default null
) returns json
language plpgsql
security definer
set search_path = public
as $$
declare v_q text;
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  v_q := nullif(trim(coalesce(p_busqueda,'')),'');

  return coalesce((
    select json_agg(t order by t.importado_en) from (
      select p.*,
        (select count(*) from prospecto_eventos e where e.prospecto_id=p.id and e.tipo='abierto') as aperturas,
        (select count(*) from prospecto_eventos e where e.prospecto_id=p.id and e.tipo='clic')    as clics
      from prospectos p
      where (p_estatus is null or p.estatus = p_estatus)
        and (p_ruta is null or p.ruta = p_ruta)
        and (v_q is null or p.agencia ilike '%'||v_q||'%' or p.correo ilike '%'||v_q||'%'
             or coalesce(p.estado,'') ilike '%'||v_q||'%')
        -- Vistas que no son un estatus, sino una combinación de estatus y etapa
        and (
          p_vista is null
          or (p_vista = 'sin_contactar' and p.estatus = 'activo' and p.etapa = 0)
          or (p_vista = 'en_secuencia'  and p.estatus = 'activo' and p.etapa between 1 and 2)
          or (p_vista = 'contactados'   and p.etapa > 0)
          or (p_vista = 'problema'      and p.estatus in ('rebotado','queja'))
        )
      order by p.importado_en
      limit greatest(1, least(coalesce(p_limite,200), 1000))
    ) t
  ), '[]'::json);
end;
$$;

revoke all on function public.admin_prospectos(text,text,text,int,text) from public, anon, authenticated;
grant execute on function public.admin_prospectos(text,text,text,int,text) to authenticated;
