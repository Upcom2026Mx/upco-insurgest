-- Upco InsurGest — Códigos de respaldo: qué hacer cuando un agente pierde su teléfono
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- EL PROBLEMA:
-- Con el 2FA de la Sesión 21, un agente que pierda o cambie de teléfono se queda FUERA de su
-- propia cartera para siempre. Con 5 agentes piloto eso se arregla con una llamada; con 200 no.
--
-- POR QUÉ EL CÓDIGO DE RESPALDO *APAGA* EL 2FA EN VEZ DE "ENTRAR CON ÉL":
-- El aal2 (la marca de "pasó el segundo factor") solo lo emite Supabase al verificar un código
-- TOTP real — no se puede falsificar desde aquí, y qué bueno. Así que el respaldo hace lo único
-- honesto que puede hacer: apagar el segundo factor. El agente entra con su contraseña como antes
-- y vuelve a activarlo con su teléfono nuevo. Es el mismo modelo de Google y de los bancos.
--
-- ENTROPÍA, NO LÍMITE DE INTENTOS:
-- A diferencia del NIP (6 dígitos) y del código de activación (6 dígitos), aquí no hace falta
-- bloquear por intentos: cada código son 40 bits al azar. Aunque alguien probara mil por segundo,
-- le tomaría milenios. Por eso el NIP necesita candado y esto no — el tamaño del número decide.

create table mfa_codigos_respaldo (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  codigo_hash text not null,
  creado timestamptz not null default now(),
  usado_en timestamptz
);
create index idx_mfa_respaldo_user on mfa_codigos_respaldo(user_id);
alter table mfa_codigos_respaldo enable row level security;
-- Sin políticas: solo las funciones de abajo la tocan. Ni el propio dueño puede leer sus hashes.

-- ============ GENERAR ============
-- Devuelve los códigos EN CLARO una sola vez; en la base solo queda su hash. Si el agente los
-- pierde, no hay forma de recuperarlos: genera unos nuevos y los viejos se invalidan.
create or replace function public.generar_codigos_respaldo() returns text[]
language plpgsql
security definer
set search_path = public, extensions, auth
as $$
declare
  v_codigos text[] := '{}';
  v_codigo text;
  i int;
begin
  if auth.uid() is null then
    raise exception 'No autorizado';
  end if;
  -- Solo tiene sentido con 2FA ya activo, y solo desde una sesión que ya pasó el segundo factor:
  -- si no, alguien con la contraseña se fabricaría sus propios códigos de respaldo.
  if not exists (select 1 from auth.mfa_factors f where f.user_id = auth.uid() and f.status = 'verified') then
    raise exception 'Primero activa la verificación en dos pasos';
  end if;
  if coalesce(auth.jwt()->>'aal','aal1') <> 'aal2' then
    raise exception 'Necesitas entrar con tu código de verificación para generar códigos de respaldo';
  end if;

  delete from mfa_codigos_respaldo where user_id = auth.uid();

  for i in 1..8 loop
    -- 5 bytes = 40 bits. Se parte a la mitad para que sea legible al dictarlo o anotarlo.
    v_codigo := upper(encode(gen_random_bytes(5),'hex'));
    v_codigo := substr(v_codigo,1,5)||'-'||substr(v_codigo,6,5);
    insert into mfa_codigos_respaldo(user_id, codigo_hash)
    values (auth.uid(), encode(digest(v_codigo,'sha256'),'hex'));
    v_codigos := array_append(v_codigos, v_codigo);
  end loop;

  return v_codigos;
end;
$$;
grant execute on function public.generar_codigos_respaldo() to authenticated;

-- ============ CUÁNTOS LE QUEDAN ============
create or replace function public.codigos_respaldo_restantes() returns int
language sql
security definer
set search_path = public
as $$
  select count(*)::int from mfa_codigos_respaldo where user_id = auth.uid() and usado_en is null;
$$;
grant execute on function public.codigos_respaldo_restantes() to authenticated;

-- ============ USAR (perdí mi teléfono) ============
-- Se llama desde una sesión aal1 — es justamente el caso de quien no puede llegar a aal2.
create or replace function public.usar_codigo_respaldo(p_codigo text) returns json
language plpgsql
security definer
set search_path = public, extensions, auth
as $$
declare
  v_id uuid;
  v_hash text;
begin
  if auth.uid() is null then
    raise exception 'No autorizado';
  end if;

  v_hash := encode(digest(upper(trim(p_codigo)),'sha256'),'hex');

  select id into v_id from mfa_codigos_respaldo
  where user_id = auth.uid() and codigo_hash = v_hash and usado_en is null;

  if v_id is null then
    raise exception 'Ese código de respaldo no es válido o ya se usó';
  end if;

  update mfa_codigos_respaldo set usado_en = now() where id = v_id;

  -- Apagar el segundo factor: es lo único que devuelve el acceso, porque el aal2 no se puede
  -- fabricar desde aquí. Se van todos los factores y también los códigos que quedaban: el juego
  -- completo se rehace cuando vuelva a activarlo con su teléfono nuevo.
  delete from auth.mfa_factors where user_id = auth.uid();
  delete from mfa_codigos_respaldo where user_id = auth.uid();

  return json_build_object('ok', true);
end;
$$;
grant execute on function public.usar_codigo_respaldo(text) to authenticated;
