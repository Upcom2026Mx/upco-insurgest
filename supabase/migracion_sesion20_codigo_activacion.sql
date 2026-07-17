-- Upco InsurGest — Código de activación: tener la liga ya no basta ni para crear el NIP
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- EL HUECO QUE CIERRA:
-- Con el NIP de la Sesión 19, la liga dejó de abrir datos... pero el PRIMERO que la abriera
-- todavía podía poner el NIP y dejar fuera al cliente real. Ahora, para crear el NIP hay que
-- teclear un código de 6 dígitos que se manda al CORREO del cliente. Así, tener la liga ya no
-- alcanza: hay que controlar además su correo.
--
-- Si el cliente no tiene correo cargado, el código se lo dicta su agente por teléfono. No es un
-- hueco: el agente ya es dueño de la ficha (podría cambiar el correo y recibir el código él
-- mismo). El modelo de amenaza aquí son terceros que se topan con la liga, no el propio agente.

alter table clientes add column codigo_activacion text;
alter table clientes add column codigo_expira timestamptz;
alter table clientes add column codigo_intentos int not null default 0;

-- random() es predecible (se siembra por sesión); para algo que autoriza a crear un NIP hay que
-- usar el generador criptográfico. Los 4 bytes se arman a mano para que siempre sea positivo.
create or replace function public.generar_codigo_6() returns text
language sql
volatile
set search_path = public, extensions
as $$
  select lpad(
    (mod(
      get_byte(b,0)::bigint*16777216 + get_byte(b,1)::bigint*65536 + get_byte(b,2)::bigint*256 + get_byte(b,3)::bigint,
      1000000
    ))::text, 6, '0')
  from (select gen_random_bytes(4) as b) s;
$$;

-- ============ PEDIR EL CÓDIGO ============
create or replace function public.portal_solicitar_codigo(p_token uuid) returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_key text;
  v_codigo text;
  v_nombre text;
begin
  select id, nombre, correo, nip_hash, codigo_activacion, codigo_expira into c
  from clientes where token_publico = p_token;

  if c.id is null then
    raise exception 'Liga inválida';
  end if;
  if c.nip_hash is not null then
    raise exception 'Esta liga ya tiene un NIP';
  end if;

  -- Mientras siga vigente es el MISMO código: pedirlo de nuevo reenvía el correo, no cambia el
  -- número. Si no, un cliente que abre dos veces la liga se queda con dos códigos y el primero
  -- que anotó deja de servirle.
  if c.codigo_activacion is not null and c.codigo_expira > now() then
    v_codigo := c.codigo_activacion;
  else
    v_codigo := public.generar_codigo_6();
    update clientes set codigo_activacion = v_codigo, codigo_expira = now() + interval '24 hours', codigo_intentos = 0
    where id = c.id;
  end if;

  if c.correo is null then
    -- Sin correo: lo dicta el agente, que lo ve en la ficha del cliente.
    return json_build_object('via','agente');
  end if;

  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'resend_api_key';
  if v_key is null then
    return json_build_object('via','agente');
  end if;

  v_nombre := split_part(c.nombre,' ',1);
  perform net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization','Bearer '||v_key,'Content-Type','application/json'),
    body := jsonb_build_object(
      'from','Upco InsurGest <notificaciones@upco.app>',
      'to', jsonb_build_array(c.correo),
      'subject','Tu código para activar tu NIP',
      'html', format(
        '<p>Hola %s,</p><p>Para crear el NIP de tu liga usa este código:</p>'
        '<p style="font-size:30px;font-weight:bold;letter-spacing:6px">%s</p>'
        '<p>Vence en 24 horas. Si tú no lo pediste, ignora este correo y avísale a tu agente: '
        'quiere decir que alguien más tiene tu liga.</p>',
        v_nombre, v_codigo)
    )
  );

  -- Enmascarado: el que está en la pantalla debe reconocer su correo, no descubrirlo.
  return json_build_object(
    'via','correo',
    'correo', regexp_replace(c.correo, '^(.).*(@.*)$', '\1•••••\2')
  );
end;
$$;
revoke all on function public.portal_solicitar_codigo(uuid) from public;
grant execute on function public.portal_solicitar_codigo(uuid) to anon, authenticated;

-- ============ DEFINIR EL NIP (ahora exige el código) ============
drop function if exists public.portal_definir_nip(uuid,text);

create or replace function public.portal_definir_nip(p_token uuid, p_nip text, p_codigo text) returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select id, nip_hash, codigo_activacion, codigo_expira, codigo_intentos into c
  from clientes where token_publico = p_token;

  if c.id is null then
    raise exception 'Liga inválida';
  end if;
  if c.nip_hash is not null then
    raise exception 'Esta liga ya tiene un NIP. Si lo olvidaste, pídele a tu agente que lo restablezca.';
  end if;
  if p_nip !~ '^[0-9]{6}$' then
    raise exception 'El NIP debe ser de 6 dígitos';
  end if;
  if c.codigo_activacion is null or c.codigo_expira < now() then
    raise exception 'Tu código venció. Pide uno nuevo.';
  end if;

  -- Sin esto, quien tenga la liga puede probar los 1,000,000 de códigos hasta dar con el bueno:
  -- el código dejaría de proteger nada. A los 5 fallos se quema y hay que pedir uno nuevo (que
  -- llega al correo del cliente, no al de quien está intentando).
  if p_codigo is null or trim(p_codigo) <> c.codigo_activacion then
    update clientes set
      codigo_intentos = codigo_intentos + 1,
      codigo_activacion = case when codigo_intentos + 1 >= 5 then null else codigo_activacion end,
      codigo_expira    = case when codigo_intentos + 1 >= 5 then null else codigo_expira end
    where id = c.id;
    if c.codigo_intentos + 1 >= 5 then
      raise exception 'Demasiados intentos. Pide un código nuevo.';
    end if;
    raise exception 'El código no es correcto';
  end if;

  update clientes set
    nip_hash = crypt(p_nip, gen_salt('bf', 8)),
    nip_definido_en = now(),
    nip_intentos = 0,
    nip_bloqueado_hasta = null,
    codigo_activacion = null,   -- de un solo uso
    codigo_expira = null,
    codigo_intentos = 0
  where id = c.id;
end;
$$;
revoke all on function public.portal_definir_nip(uuid,text,text) from public;
grant execute on function public.portal_definir_nip(uuid,text,text) to anon, authenticated;

-- ============ EL AGENTE VE EL CÓDIGO (para dictarlo si su cliente no tiene correo) ============
create or replace function public.agente_codigo_activacion(p_cliente_id uuid) returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_codigo text;
begin
  select id, nip_hash, correo, codigo_activacion, codigo_expira into c
  from clientes where id = p_cliente_id and agente_id = auth.uid();
  if c.id is null then
    raise exception 'No autorizado';
  end if;
  if c.nip_hash is not null then
    raise exception 'Este cliente ya tiene NIP';
  end if;

  if c.codigo_activacion is null or c.codigo_expira < now() then
    v_codigo := public.generar_codigo_6();
    update clientes set codigo_activacion = v_codigo, codigo_expira = now() + interval '24 hours', codigo_intentos = 0
    where id = c.id;
  else
    v_codigo := c.codigo_activacion;
  end if;

  return json_build_object('codigo', v_codigo, 'expira', (select codigo_expira from clientes where id = c.id));
end;
$$;
grant execute on function public.agente_codigo_activacion(uuid) to authenticated;
