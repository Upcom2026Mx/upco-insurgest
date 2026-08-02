-- Upco InsurGest — Sesion 42: importar cartera de clientes desde CSV (fase 1 del roadmap
-- de import — solo agentes por ahora; cartera propia de promotoria queda para la fase 2,
-- porque hoy clientes.agente_id es NOT NULL y toda la RLS/notificaciones asumen un agente
-- como dueno. Cuando se construya la fase 2 se generaliza esta misma funcion.
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- La validacion (nombre obligatorio, duplicados por RFC o correo) vive aqui, no en el
-- frontend, para que sea la unica fuente de verdad sin importar desde donde se llame.

create or replace function public.agente_importar_clientes(p_filas jsonb) returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_agente_id uuid := auth.uid();
  v_fila jsonb;
  v_insertados int := 0;
  v_omitidos jsonb := '[]'::jsonb;
  v_indice int := 0;
  v_tipo_persona text;
  v_nombre text;
  v_rfc text;
  v_curp text;
  v_correo text;
  v_telefono text;
  v_notas text;
  v_duplicado boolean;
begin
  if not exists (select 1 from agentes where id = v_agente_id) then
    raise exception 'No autorizado';
  end if;
  if jsonb_array_length(p_filas) > 1000 then
    raise exception 'Máximo 1000 clientes por importación — divide tu archivo en partes más chicas.';
  end if;

  for v_fila in select * from jsonb_array_elements(p_filas)
  loop
    v_indice := v_indice + 1;
    v_tipo_persona := lower(trim(coalesce(v_fila->>'tipo_persona','fisica')));
    v_nombre := nullif(trim(coalesce(v_fila->>'nombre','')),'');
    v_rfc := nullif(upper(trim(coalesce(v_fila->>'rfc',''))),'');
    v_curp := nullif(upper(trim(coalesce(v_fila->>'curp',''))),'');
    v_correo := nullif(lower(trim(coalesce(v_fila->>'correo',''))),'');
    v_telefono := nullif(trim(coalesce(v_fila->>'telefono','')),'');
    v_notas := nullif(trim(coalesce(v_fila->>'notas','')),'');

    if v_nombre is null then
      v_omitidos := v_omitidos || jsonb_build_object('fila', v_indice, 'nombre', coalesce(v_fila->>'nombre',''), 'motivo', 'Falta el nombre');
      continue;
    end if;
    if v_tipo_persona not in ('fisica','moral') then
      v_tipo_persona := 'fisica';
    end if;
    if v_tipo_persona = 'moral' then
      v_curp := null;
    end if;

    -- Duplicado obvio dentro de la cartera de este mismo agente: mismo RFC o mismo correo.
    v_duplicado := false;
    if v_rfc is not null then
      select exists(select 1 from clientes where agente_id = v_agente_id and rfc = v_rfc) into v_duplicado;
    end if;
    if not v_duplicado and v_correo is not null then
      select exists(select 1 from clientes where agente_id = v_agente_id and correo = v_correo) into v_duplicado;
    end if;
    if v_duplicado then
      v_omitidos := v_omitidos || jsonb_build_object('fila', v_indice, 'nombre', v_nombre, 'motivo', 'Ya tienes un cliente con ese RFC o correo');
      continue;
    end if;

    insert into clientes(agente_id, tipo_persona, nombre, rfc, curp, correo, telefono, notas)
    values (v_agente_id, v_tipo_persona, v_nombre, v_rfc, v_curp, v_correo, v_telefono, v_notas);
    v_insertados := v_insertados + 1;
  end loop;

  return json_build_object('insertados', v_insertados, 'omitidos', v_omitidos);
end;
$$;
grant execute on function public.agente_importar_clientes(jsonb) to authenticated;
