-- Upco InsurGest — Sesión 68: excluir prospectos que ya tienen sitio web propio
--
-- BUG encontrado por el fundador en Leads calientes: Goethe-Institut, British
-- Council, Gastromotiva y Gymnastics Academy aparecían como los MEJORES leads
-- de la campaña de Upco WEB — pero el DENUE ya los marca con sitio web propio
-- (WWW.GOETHE.DE, WWW.BRITISHCOUNCIL.ORG.MX...). Se les estaba mandando la
-- oferta de "no tiene sitio web", que no les aplica. Su alto clic probablemente
-- es curiosidad profesional o revisión de spam, no interés real de compra —
-- explica por qué el segmento con mejor apertura/clic lleva cero conversiones.
--
-- Causa: admin_importar_prospectos() fija ruta='web' a fuerzas para escuelas y
-- academias, sin mirar tiene_sitio_web (que sí captura, solo no lo usa). Upco
-- no tiene hoy una oferta distinta para quien ya tiene sitio (no existe aún un
-- "Upco Edu" de gestión escolar) — así que la corrección es no importarlos,
-- igual que ya se hace con los de nivel "superior" o dominios .gob.mx.

-- 1) Sacar de la secuencia a los que ya están mal (1,449 en total; 1,269 siguen
--    activos y academias corre en vivo ahora mismo a 15/día).
update prospectos
  set estatus = 'baja',
      notas = 'Excluido: ya tiene sitio web propio según DENUE (' || coalesce(sitio_web_actual,'sin URL capturada') || ') — la oferta de Upco WEB no le aplica.'
  where segmento in ('escuelas','academias')
    and tiene_sitio_web = true
    and estatus = 'activo';

-- 2) Que no vuelva a pasar con la próxima importación.
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
  v_ya_tienen_sitio int := 0;
  r jsonb;
  v_correo text;
  v_dominio text;
  v_dominio_normalizado text;
  v_ruta text;
  v_nivel text;
  v_categoria text;
  v_tiene_sitio boolean;
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
    v_dominio_normalizado := replace(v_dominio,'.','');

    if p_segmento in ('escuelas','academias')
       and (v_dominio_normalizado like '%gobmx' or v_dominio_normalizado like '%edumx') then
      v_institucionales := v_institucionales + 1;
      continue;
    end if;

    v_tiene_sitio := case when r ? 'tiene_sitio_web' then (r->>'tiene_sitio_web')::boolean else null end;

    -- Upco WEB vende sitios a quien no tiene uno. Si el DENUE ya le conoce un
    -- sitio propio, la oferta no le aplica — no existe hoy una oferta distinta
    -- que ofrecerle (no hay todavía un producto tipo "Upco Edu").
    if p_segmento in ('escuelas','academias') and v_tiene_sitio = true then
      v_ya_tienen_sitio := v_ya_tienen_sitio + 1;
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
      v_tiene_sitio,
      nullif(trim(coalesce(r->>'sitio_web_actual','')),''),
      case when p_segmento in ('escuelas','academias') then 'denue' else 'cnsf' end,
      v_categoria
    )
    on conflict (correo) do nothing;

    if found then v_insertados := v_insertados + 1; else v_omitidos := v_omitidos + 1; end if;
  end loop;

  return json_build_object(
    'insertados', v_insertados, 'omitidos', v_omitidos, 'invalidos', v_invalidos,
    'institucionales', v_institucionales, 'ya_tienen_sitio', v_ya_tienen_sitio
  );
end;
$$;

-- Comprobación
do $$
declare v_quedan int;
begin
  select count(*) into v_quedan from prospectos
    where segmento in ('escuelas','academias') and tiene_sitio_web = true and estatus = 'activo';
  if v_quedan > 0 then
    raise exception 'Siguen % prospectos activos con sitio web propio', v_quedan;
  end if;
  raise notice 'OK: nadie con sitio web propio sigue activo en escuelas/academias.';
end;
$$;
