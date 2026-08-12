-- Upco InsurGest — Sesión 60: cierra el hueco del filtro de dominios institucionales
-- Correr con: pg-insurgest -f supabase/migracion_sesion60_dominios_institucionales_sin_punto.sql
--
-- Origen: el usuario reportó cero conversiones y, revisando los rebotes reales, aparecieron
-- dos escuelas de gobierno con el dominio mal capturado en el DENUE — "afcm.gobmx" y
-- "aefcm.gobmx" (sin el punto antes de "gobmx"). El filtro de la Sesión 54 buscaba
-- literalmente ".gob.mx" al final, así que estos typos de origen se colaron. Se encontraron
-- 13 casos más con el mismo patrón (gobmx/edumx sin punto).
--
-- Fix: en vez de buscar el sufijo exacto ".gob.mx"/".edu.mx", se le quitan los puntos al
-- dominio y se compara contra "gobmx"/"edumx" — así da igual si el dato de origen trae el
-- punto, lo omite, o lo duplica.

delete from prospectos
where segmento in ('escuelas','academias')
  and (replace(dominio,'.','') like '%gobmx' or replace(dominio,'.','') like '%edumx');

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
  v_dominio_normalizado text;
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
    -- Sin puntos, para no depender de que el dato de origen los traiga bien capturados
    -- (DENUE trae typos reales tipo "afcm.gobmx" en vez de "afcm.gob.mx").
    v_dominio_normalizado := replace(v_dominio,'.','');

    if p_segmento in ('escuelas','academias')
       and (v_dominio_normalizado like '%gobmx' or v_dominio_normalizado like '%edumx') then
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
      if v_nivel = 'superior' then
        v_institucionales := v_institucionales + 1;
        continue;
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

do $$
declare v_restantes int;
begin
  select count(*) into v_restantes from prospectos
  where segmento in ('escuelas','academias')
    and (replace(dominio,'.','') like '%gobmx' or replace(dominio,'.','') like '%edumx');
  if v_restantes > 0 then raise exception 'Quedaron % dominios institucionales (typo sin punto) sin limpiar', v_restantes; end if;
  raise notice 'Correcto: sin dominios gobmx/edumx (con o sin punto) en escuelas/academias.';
end;
$$;
