-- Upco InsurGest — Sesión 66: Leads calientes filtra por segmento
--
-- Error de la Sesión 64: admin_leads_calientes() devolvía los 3 segmentos
-- (agencias_seguros, escuelas, academias) mezclados. Rompe la separación que
-- ya existía desde la Sesión 51: InsurGest administra agencias_seguros desde
-- este panel; escuelas y academias se administran desde el admin de Upco WEB.
-- El fundador lo detectó de inmediato al ver leads de Upco WEB (Goethe-Institut,
-- British Council) mezclados en el portal de InsurGest.

-- Quitar la firma vieja PRIMERO: create or replace no reemplaza una función con
-- distinta lista de parámetros, y dejar las dos coexistir un momento ya causó
-- errores PGRST202 en sesiones anteriores (ver Sesión 6).
drop function if exists public.admin_leads_calientes(int);

create or replace function public.admin_leads_calientes(p_limite int default 20, p_segmento text default null)
returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;

  return coalesce((
    select json_agg(t order by t.vio_terminos desc, t.clics desc, t.aperturas desc, t.ultimo_evento desc)
    from (
      select
        p.id, p.agencia, p.correo, p.segmento, p.ruta, p.estatus, p.etapa,
        count(*) filter (where e.tipo = 'clic')                        as clics,
        count(*) filter (where e.tipo = 'abierto')                     as aperturas,
        bool_or(e.tipo = 'clic' and e.liga ilike '%terminos%')         as vio_terminos,
        max(e.ocurrio_en)                                              as ultimo_evento
      from prospectos p
      join prospecto_eventos e on e.prospecto_id = p.id
      where e.tipo in ('clic','abierto')
        and p.estatus in ('activo','completado')
        and (p_segmento is null or p.segmento = p_segmento)
      group by p.id, p.agencia, p.correo, p.segmento, p.ruta, p.estatus, p.etapa
      having count(*) filter (where e.tipo = 'clic') >= 1
    ) t
    limit greatest(1, least(coalesce(p_limite,20), 100))
  ), '[]'::json);
end;
$$;
revoke all on function public.admin_leads_calientes(int,text) from public, anon, authenticated;
grant execute on function public.admin_leads_calientes(int,text) to authenticated;
