-- Upco InsurGest — Sesión 72: código de activación de Agente Libre (no de referido)
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- Corrección de diseño sobre la Sesión 69: los 4 códigos semilla ("Agente Libre 01-04") no son
-- para que otros los usen como referido — son códigos de ACTIVACIÓN: cuando la persona real se
-- registra en /promotor/?registro=1 con SU PROPIO correo y entra el código, ella misma se
-- convierte en Agente Libre (no en una promotoría referida por uno). La fila semilla (hoy ligada
-- al correo del fundador) se transfiere por completo: se crea la fila nueva con el id/correo real
-- del registrante, mismo código, y se borra la cuenta semilla del fundador.
--
-- Una vez reclamado (reclamado_en not null), ESE MISMO código sí puede usarse como código de
-- referido normal para que otros agentes/promotorías/agencias máster queden ligados a esa persona
-- — por eso resolver_codigo_agente_libre() se ajusta para exigir reclamado_en not null: mientras
-- el código siga sin reclamar, solo sirve para el reclamo, no para referir a nadie.

alter table agentes_libres add column if not exists reclamado_en timestamptz;

create or replace function public.resolver_codigo_agente_libre(p_codigo text)
returns uuid
language sql
stable security definer
set search_path = public
as $$
  select id from agentes_libres
    where codigo_invitacion = upper(trim(p_codigo))
      and estatus_aprobacion = 'aprobado'
      and reclamado_en is not null;
$$;

create or replace function public.reclamar_agente_libre(
  p_codigo text,
  p_nombre text default null,
  p_nombre_negocio text default null,
  p_rfc text default null,
  p_acepto_terminos boolean default false,
  p_acepto_terminos_version text default null,
  p_acepto_terminos_fecha timestamptz default null
) returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_semilla record;
  v_nuevo_id uuid := auth.uid();
  v_correo text;
begin
  if v_nuevo_id is null then
    raise exception 'No autorizado';
  end if;

  select * into v_semilla from agentes_libres
    where codigo_invitacion = upper(trim(p_codigo)) and reclamado_en is null
    for update;

  if v_semilla is null then
    return json_build_object('reclamado', false);
  end if;

  if exists(select 1 from agentes_libres where id = v_nuevo_id) then
    raise exception 'Ya tienes una cuenta de Agente Libre.';
  end if;

  select email into v_correo from auth.users where id = v_nuevo_id;

  -- Hay que borrar la semilla ANTES de insertar la fila nueva: las dos comparten el mismo
  -- codigo_invitacion (unique), así que insertar primero choca consigo mismo. La cascada ya
  -- existente (auth.users -> agentes_libres) limpia la fila semilla sola.
  delete from auth.users where id = v_semilla.id;

  insert into agentes_libres(
    id, correo, nombre, nombre_negocio, rfc, codigo_invitacion,
    estatus_aprobacion, acepto_terminos, acepto_terminos_version, acepto_terminos_fecha, reclamado_en
  ) values (
    v_nuevo_id, v_correo, p_nombre, p_nombre_negocio, p_rfc, v_semilla.codigo_invitacion,
    'aprobado', coalesce(p_acepto_terminos,false), p_acepto_terminos_version, p_acepto_terminos_fecha, now()
  );

  return json_build_object('reclamado', true, 'codigo', v_semilla.codigo_invitacion);
end;
$$;
