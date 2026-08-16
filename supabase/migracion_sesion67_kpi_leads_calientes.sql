-- Upco InsurGest — Sesión 67: contador de leads calientes en el resumen
--
-- admin_prospeccion_resumen() es la función COMPARTIDA que usan tanto el panel
-- de InsurGest (agencias_seguros) como el de Upco WEB (escuelas/academias) —
-- viven en el mismo proyecto de Supabase. Se le agrega 'leads_calientes' con
-- el mismo criterio que admin_leads_calientes() (Sesión 64/66): al menos un
-- clic real, estatus activo o completado. Así la tarjeta de KPI y la lista de
-- abajo siempre están de acuerdo, sin duplicar la definición de "caliente".

create or replace function public.admin_prospeccion_resumen(p_segmento text default 'agencias_seguros')
returns json
language plpgsql
security definer
set search_path = public
as $$
declare v_inicio_dia timestamptz;
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  v_inicio_dia := (date_trunc('day', now() at time zone 'America/Mexico_City')) at time zone 'America/Mexico_City';

  return json_build_object(
    'ajustes', (select row_to_json(t) from (select * from prospeccion_ajustes where segmento = p_segmento) t),
    'total', (select count(*) from prospectos where segmento = p_segmento),
    'sin_contactar', (select count(*) from prospectos where segmento = p_segmento and estatus='activo' and etapa=0),
    'en_secuencia', (select count(*) from prospectos where segmento = p_segmento and estatus='activo' and etapa between 1 and 2),
    'completados', (select count(*) from prospectos where segmento = p_segmento and estatus='completado'),
    'respondieron', (select count(*) from prospectos where segmento = p_segmento and estatus='respondio'),
    'bajas', (select count(*) from prospectos where segmento = p_segmento and estatus='baja'),
    'rebotados', (select count(*) from prospectos where segmento = p_segmento and estatus='rebotado'),
    'quejas', (select count(*) from prospectos where segmento = p_segmento and estatus='queja'),
    'sin_sitio_web', (select count(*) from prospectos where segmento = p_segmento and tiene_sitio_web = false),
    'por_ruta', (select coalesce(json_agg(x),'[]'::json) from (
        select ruta, count(*) as total from prospectos where segmento = p_segmento group by ruta order by ruta) x),
    'por_estado', (select coalesce(json_agg(x),'[]'::json) from (
        select coalesce(estado,'Sin estado') as estado, count(*) as total from prospectos
        where segmento = p_segmento group by estado order by total desc limit 15) x),
    'por_nivel', (select coalesce(json_agg(x),'[]'::json) from (
        select coalesce(nivel_educativo,'Sin clasificar') as nivel, count(*) as total from prospectos
        where segmento = p_segmento group by nivel_educativo order by total desc) x),
    'por_categoria', (select coalesce(json_agg(x),'[]'::json) from (
        select coalesce(categoria,'Sin clasificar') as categoria, count(*) as total from prospectos
        where segmento = p_segmento group by categoria order by total desc) x),
    'correos_enviados', (select count(*) from prospecto_eventos e join prospectos pr on pr.id=e.prospecto_id where e.tipo='enviado' and pr.segmento = p_segmento),
    'enviados_hoy', (select count(*) from prospecto_eventos e join prospectos pr on pr.id=e.prospecto_id where e.tipo='enviado' and e.ocurrio_en >= v_inicio_dia and pr.segmento = p_segmento),
    'abrieron', (select count(distinct e.prospecto_id) from prospecto_eventos e join prospectos pr on pr.id=e.prospecto_id where e.tipo='abierto' and pr.segmento = p_segmento),
    'clicaron', (select count(distinct e.prospecto_id) from prospecto_eventos e join prospectos pr on pr.id=e.prospecto_id where e.tipo='clic' and pr.segmento = p_segmento),
    'leads_calientes', (
      select count(*) from (
        select p.id
        from prospectos p join prospecto_eventos e on e.prospecto_id = p.id
        where p.segmento = p_segmento
          and e.tipo in ('clic','abierto')
          and p.estatus in ('activo','completado')
        group by p.id
        having count(*) filter (where e.tipo = 'clic') >= 1
      ) t
    )
  );
end;
$$;
