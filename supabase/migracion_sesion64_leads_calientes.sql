-- Upco InsurGest — Sesión 64: leads calientes de la campaña de prospección
-- Correr con:  ~/bin/pg-insurgest -f supabase/migracion_sesion64_leads_calientes.sql
--
-- Motivo: el fundador quiere un lugar donde tomar el correo de los prospectos que
-- muestran interés real y escribirles un mensaje personal — no la secuencia
-- automática. "Interés real" se define igual que se venía haciendo a mano por SQL
-- en esta conversación: al menos un clic de verdad (no solo apertura, que Apple
-- infla de forma poco confiable — ver conversación del 9 de agosto), con quien
-- además haya entrado a /terminos/ primero en el orden, porque nadie abre un
-- contrato por curiosidad.
--
-- Cubre los TRES segmentos (agencias_seguros, escuelas, academias) aunque hoy
-- solo agencias_seguros se administre desde este panel — un lead caliente de
-- Upco WEB (ej. Goethe-Institut) es igual de accionable que uno de InsurGest.

create or replace function public.admin_leads_calientes(p_limite int default 20)
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
        -- Ya en 'respondio' significa que el fundador ya lo está atendiendo; 'baja'/
        -- 'rebotado'/'queja' ya no son contactables. Este apartado es para el hueco de
        -- en medio: interés real, todavía sin un mensaje personal.
        and p.estatus in ('activo','completado')
      group by p.id, p.agencia, p.correo, p.segmento, p.ruta, p.estatus, p.etapa
      having count(*) filter (where e.tipo = 'clic') >= 1
    ) t
    limit greatest(1, least(coalesce(p_limite,20), 100))
  ), '[]'::json);
end;
$$;
revoke all on function public.admin_leads_calientes(int) from public, anon, authenticated;
grant execute on function public.admin_leads_calientes(int) to authenticated;
