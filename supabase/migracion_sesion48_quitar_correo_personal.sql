-- Upco InsurGest — Sesión 48: sacar el correo personal del fundador de todos los envíos
-- Correr con:  ~/bin/pg-insurgest -f supabase/migracion_sesion48_quitar_correo_personal.sql
--
-- Motivo: el correo personal del fundador estaba escrito en duro dentro de varias funciones. En
-- admin_enviar_invitacion iba como 'reply_to', o sea que CUALQUIER desconocido que recibiera
-- una invitación y le diera Responder veía ese correo — y el fundador pidió anonimato
-- explícitamente por su trabajo. En las otras cuatro iba como destinatario de avisos internos:
-- no lo ve nadie de fuera, pero igual se despersonaliza para que el negocio no dependa de una
-- cuenta personal.
--
-- ESTE ARCHIVO NO LLEVA EL CORREO ESCRITO, a propósito: este repo es público, y publicar aquí
-- justo el dato que estamos sacando de los envíos sería contradictorio. Al correrlo hay que
-- poner el correo real en v_viejo. Ya se ejecutó una vez el 2026-08-09; queda como registro.
--
-- NO SE TOCA es_admin(): ahí el correo no es un destinatario sino la LLAVE DE ACCESO al panel
-- del fundador, comparada contra el correo de la sesión de Supabase Auth. Cambiarlo lo dejaría
-- fuera de /admin al instante. Si algún día se quiere mover, primero hay que crear la cuenta
-- de Auth nueva y verificarla; es un cambio aparte, no cosmético.

do $$
declare
  -- Poner aquí el correo personal a sacar antes de correr el archivo.
  v_viejo text := 'CORREO_PERSONAL_DEL_FUNDADOR';
  v_nuevo text := 'hola@upco.app';
  r record;
  v_def text;
  v_nueva text;
  v_cambiadas int := 0;
begin
  if v_viejo = 'CORREO_PERSONAL_DEL_FUNDADOR' then
    raise exception 'Falta poner el correo real en v_viejo antes de correr este archivo.';
  end if;

  for r in
    select p.oid, p.proname
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prokind = 'f'
      and p.prolang <> 12                      -- excluye funciones internas en C
      and p.proname <> 'es_admin'              -- ver nota de arriba: es la llave, no un envío
      and pg_get_functiondef(p.oid) like '%' || v_viejo || '%'
  loop
    v_def := pg_get_functiondef(r.oid);
    v_nueva := replace(v_def, v_viejo, v_nuevo);

    -- Reemplazar sobre la definición real (en vez de reescribir cada función a mano) evita
    -- alterar su lógica por una transcripción descuidada. CREATE OR REPLACE conserva los
    -- permisos existentes porque no recrea el objeto.
    execute v_nueva;
    v_cambiadas := v_cambiadas + 1;
    raise notice 'Actualizada: %', r.proname;
  end loop;

  raise notice 'Total de funciones actualizadas: %', v_cambiadas;
end;
$$;

-- Comprobación: debe quedar SOLO es_admin mencionando el correo personal.
do $$
declare
  v_viejo text := 'CORREO_PERSONAL_DEL_FUNDADOR';   -- el mismo valor del bloque de arriba
  v_restantes text;
begin
  select string_agg(p.proname, ', ' order by p.proname) into v_restantes
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prokind = 'f' and p.prolang <> 12
    and pg_get_functiondef(p.oid) like '%' || v_viejo || '%';

  if v_restantes is distinct from 'es_admin' then
    raise exception 'Revisar a mano — funciones que aún mencionan el correo personal: %',
      coalesce(v_restantes, '(ninguna, se esperaba es_admin)');
  end if;
  raise notice 'Correcto: solo es_admin conserva el correo, como llave de acceso.';
end;
$$;
