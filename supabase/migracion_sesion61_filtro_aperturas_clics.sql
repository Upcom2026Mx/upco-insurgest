-- Upco InsurGest — Sesión 61: agrega vistas filtrables "abrieron" y "clicaron"
-- Correr con: pg-insurgest -f supabase/migracion_sesion61_filtro_aperturas_clics.sql
--
-- Origen: el usuario notó que las tarjetas "Abrieron" y "Vieron el sitio demo" del panel no
-- llevan a ninguna lista al hacer clic — eran solo informativas desde el diseño original
-- (aperturas/clics son eventos, no un estatus ni una combinación de estatus+etapa como las
-- demás vistas). Se agrega el filtro real: quién tiene al menos un evento 'abierto'/'clic'.
--
-- No cambia la firma (sigue con 6 parámetros), así que no hace falta dropear la función.

create or replace function public.admin_prospectos(
  p_estatus  text default null,
  p_ruta     text default null,
  p_busqueda text default null,
  p_limite   int  default 200,
  p_vista    text default null,
  p_segmento text default 'agencias_seguros'
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
      where p.segmento = p_segmento
        and (p_estatus is null or p.estatus = p_estatus)
        and (p_ruta is null or p.ruta = p_ruta)
        and (v_q is null or p.agencia ilike '%'||v_q||'%' or p.correo ilike '%'||v_q||'%'
             or coalesce(p.estado,'') ilike '%'||v_q||'%')
        and (
          p_vista is null
          or (p_vista = 'sin_contactar' and p.estatus = 'activo' and p.etapa = 0)
          or (p_vista = 'en_secuencia'  and p.estatus = 'activo' and p.etapa between 1 and 2)
          or (p_vista = 'contactados'   and p.etapa > 0)
          or (p_vista = 'problema'      and p.estatus in ('rebotado','queja'))
          or (p_vista = 'sin_sitio_web' and p.tiene_sitio_web = false)
          or (p_vista = 'abrieron'      and exists(select 1 from prospecto_eventos e where e.prospecto_id=p.id and e.tipo='abierto'))
          or (p_vista = 'clicaron'      and exists(select 1 from prospecto_eventos e where e.prospecto_id=p.id and e.tipo='clic'))
        )
      order by p.importado_en
      limit greatest(1, least(coalesce(p_limite,200), 1000))
    ) t
  ), '[]'::json);
end;
$$;
