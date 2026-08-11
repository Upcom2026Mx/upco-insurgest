-- Upco InsurGest — Sesión 54: excluir dominios institucionales (.edu.mx / .gob.mx) de escuelas
-- y academias.
-- Correr con: pg-insurgest -f supabase/migracion_sesion54_excluir_dominios_institucionales.sql
--
-- Origen: el usuario revisó la lista real y notó universidades (públicas y privadas) y
-- escuelas de gobierno mezcladas con el objetivo real (escuelas/academias independientes sin
-- sitio web). Dos motivos, no uno solo:
--   1. .edu.mx es un dominio restringido en México — solo lo tienen instituciones ya
--      formalizadas (universidades, institutos), que por definición ya tienen presencia web
--      y equipo de TI/mercadotecnia propio. No es el prospecto que buscamos.
--   2. .gob.mx son escuelas públicas con direcciones genéricas emitidas por la SEP/estado
--      (ej. E09DPR2087X@AEFCM.GOB.MX) — nadie en particular las revisa, y la decisión de
--      compra de un sitio web no la toma la escuela sino gobierno vía procuración pública.
-- Alcance real al momento de correr esto: 5,196 .gob.mx + 2,398 .edu.mx = 7,594 registros,
-- la mayoría (7,583) sin contactar todavía.

-- ============================================================================
-- 1. Limpieza de lo ya importado
-- ============================================================================
delete from prospectos
where segmento in ('escuelas','academias')
  and (dominio like '%.edu.mx' or dominio like '%.gob.mx');
-- prospecto_eventos se limpia solo (on delete cascade), así que los 8 que ya iban a media
-- secuencia y los 3 que habían rebotado se van también, sin dejar huérfanos.

-- ============================================================================
-- 2. admin_importar_prospectos: rechaza .edu.mx/.gob.mx desde la importación, para que no
--    puedan volver a colarse ni con un CSV nuevo ni con uno cargado a mano.
-- ============================================================================
drop function if exists public.admin_importar_prospectos(jsonb,text);

create or replace function public.admin_importar_prospectos(p_filas jsonb, p_segmento text default 'agencias_seguros')
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_insertados int := 0;
  v_omitidos int := 0;
  v_invalidos int := 0;
  v_institucionales int := 0;
  r jsonb;
  v_correo text;
  v_dominio text;
  v_ruta text;
  v_nivel text;
  v_categoria text;
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  if p_segmento not in ('agencias_seguros','escuelas','academias') then raise exception 'Segmento no válido'; end if;

  for r in select * from jsonb_array_elements(p_filas)
  loop
    v_correo := lower(trim(coalesce(r->>'correo','')));

    if v_correo !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
       or coalesce(trim(r->>'agencia'),'') = '' then
      v_invalidos := v_invalidos + 1;
      continue;
    end if;

    v_dominio := split_part(v_correo,'@',2);

    -- .edu.mx (universidades/institutos ya establecidos) y .gob.mx (escuelas/dependencias de
    -- gobierno: no deciden su propia compra ni monitorean esa cuenta) no son prospecto para
    -- escuelas ni academias. Sí se dejan pasar para agencias_seguros por si algún día aplica.
    if p_segmento in ('escuelas','academias')
       and (v_dominio like '%.edu.mx' or v_dominio like '%.gob.mx') then
      v_institucionales := v_institucionales + 1;
      continue;
    end if;

    v_nivel := null;
    v_categoria := null;

    if p_segmento = 'escuelas' then
      v_ruta := 'web';
      v_nivel := nullif(trim(coalesce(r->>'nivel_educativo','')),'');
      if v_nivel is not null and v_nivel not in ('preescolar','primaria','secundaria','media_superior','superior','otro') then
        v_nivel := 'otro';
      end if;
    elsif p_segmento = 'academias' then
      v_ruta := 'web';
      v_categoria := nullif(trim(coalesce(r->>'categoria','')),'');
    else
      v_ruta := nullif(trim(coalesce(r->>'ruta','')),'');
      if v_ruta is null or v_ruta not in ('web','insurgest') then
        v_ruta := case
          when v_dominio in (
            'gmail.com','hotmail.com','outlook.com','yahoo.com','yahoo.com.mx','live.com',
            'live.com.mx','prodigy.net.mx','msn.com','icloud.com','me.com','aol.com',
            'hotmail.es','outlook.es','hotmail.com.mx','yahoo.es'
          ) then 'web'
          else 'insurgest'
        end;
      end if;
    end if;

    insert into prospectos(
      agencia, correo, dominio, ruta, estado, cp, ciudad,
      segmento, nivel_educativo, tiene_sitio_web, sitio_web_actual, fuente, categoria
    )
    values (
      trim(r->>'agencia'),
      v_correo,
      v_dominio,
      v_ruta,
      nullif(trim(coalesce(r->>'estado','')),''),
      nullif(trim(coalesce(r->>'cp','')),''),
      nullif(trim(coalesce(r->>'ciudad','')),''),
      p_segmento,
      v_nivel,
      case when r ? 'tiene_sitio_web' then (r->>'tiene_sitio_web')::boolean else null end,
      nullif(trim(coalesce(r->>'sitio_web_actual','')),''),
      case when p_segmento in ('escuelas','academias') then 'denue' else 'cnsf' end,
      v_categoria
    )
    on conflict (correo) do nothing;

    if found then v_insertados := v_insertados + 1; else v_omitidos := v_omitidos + 1; end if;
  end loop;

  return json_build_object(
    'insertados', v_insertados, 'omitidos', v_omitidos, 'invalidos', v_invalidos,
    'institucionales', v_institucionales
  );
end;
$$;
revoke all on function public.admin_importar_prospectos(jsonb,text) from public, anon, authenticated;
grant execute on function public.admin_importar_prospectos(jsonb,text) to authenticated;

-- ============================================================================
-- 3. Comprobación
-- ============================================================================
do $$
declare v_restantes int;
begin
  select count(*) into v_restantes from prospectos
  where segmento in ('escuelas','academias') and (dominio like '%.edu.mx' or dominio like '%.gob.mx');
  if v_restantes > 0 then raise exception 'Quedaron % dominios institucionales sin limpiar', v_restantes; end if;
  raise notice 'Correcto: sin dominios .edu.mx/.gob.mx en escuelas/academias.';
end;
$$;
