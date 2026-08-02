-- Upco InsurGest — Sesion 45: siniestros y reclamaciones (fase 3 del roadmap acordado:
-- import -> cartera propia de promotoria -> siniestros)
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- Pedido explicito del usuario: habilitar la carga de documentos para levantar siniestros de
-- GMM, reclamaciones de reembolso, programacion de cirugias, etc. El cliente puede iniciar el
-- caso desde su liga magica y subir varios documentos; el agente o promotoria (quien sea el
-- dueño real del cliente, ver Sesion 43-44) lo gestiona y le cambia el estatus.
--
-- No se duplica agente_id/promotoria_id en estas tablas nuevas — se deriva siempre de
-- clientes.agente_id/promotoria_id via join, exactamente como ya hacen vehiculos y polizas.
-- Esto evita otra copia del mismo dato que se pueda desincronizar.

create table siniestros (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid not null references clientes(id) on delete cascade,
  poliza_id uuid references polizas(id) on delete set null,
  tipo text not null check (tipo in ('gmm','reembolso','cirugia','otro')),
  tipo_otro text,
  descripcion text,
  monto_reclamado numeric(12,2),
  fecha_evento date,
  estatus text not null default 'abierto' check (estatus in ('abierto','en_revision','resuelto','rechazado')),
  creado_por text not null default 'agente' check (creado_por in ('cliente','agente')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint tipo_otro_solo_si_otro check (tipo <> 'otro' or tipo_otro is not null)
);
create index idx_siniestros_cliente on siniestros(cliente_id);

alter table siniestros enable row level security;
create policy "dueño ve siniestros de sus clientes" on siniestros for select using (
  exists(select 1 from clientes c where c.id = siniestros.cliente_id and (c.agente_id = auth.uid() or c.promotoria_id = auth.uid())));
create policy "dueño crea siniestros de sus clientes" on siniestros for insert with check (
  exists(select 1 from clientes c where c.id = siniestros.cliente_id and (c.agente_id = auth.uid() or c.promotoria_id = auth.uid())));
create policy "dueño edita siniestros de sus clientes" on siniestros for update using (
  exists(select 1 from clientes c where c.id = siniestros.cliente_id and (c.agente_id = auth.uid() or c.promotoria_id = auth.uid())));
create policy "dueño elimina siniestros de sus clientes" on siniestros for delete using (
  exists(select 1 from clientes c where c.id = siniestros.cliente_id and (c.agente_id = auth.uid() or c.promotoria_id = auth.uid())));
create policy "exige 2fa cuando esta activado" on siniestros
  as restrictive for all to authenticated using (mfa_ok()) with check (mfa_ok());

-- Documentos: uno-a-muchos, a diferencia de solicitudes.foto_path que solo admite un archivo —
-- un siniestro real trae facturas, recetas, estudios, identificación, etc.
create table siniestro_documentos (
  id uuid primary key default gen_random_uuid(),
  siniestro_id uuid not null references siniestros(id) on delete cascade,
  path text not null,
  nombre_archivo text,
  subido_por text not null check (subido_por in ('cliente','agente')),
  created_at timestamptz not null default now()
);
create index idx_siniestro_documentos_siniestro on siniestro_documentos(siniestro_id);

alter table siniestro_documentos enable row level security;
create policy "dueño ve documentos de sus siniestros" on siniestro_documentos for select using (
  exists(select 1 from siniestros s join clientes c on c.id = s.cliente_id
    where s.id = siniestro_documentos.siniestro_id and (c.agente_id = auth.uid() or c.promotoria_id = auth.uid())));
create policy "dueño agrega documentos a sus siniestros" on siniestro_documentos for insert with check (
  exists(select 1 from siniestros s join clientes c on c.id = s.cliente_id
    where s.id = siniestro_documentos.siniestro_id and (c.agente_id = auth.uid() or c.promotoria_id = auth.uid())));
create policy "dueño elimina documentos de sus siniestros" on siniestro_documentos for delete using (
  exists(select 1 from siniestros s join clientes c on c.id = s.cliente_id
    where s.id = siniestro_documentos.siniestro_id and (c.agente_id = auth.uid() or c.promotoria_id = auth.uid())));
create policy "exige 2fa cuando esta activado" on siniestro_documentos
  as restrictive for all to authenticated using (mfa_ok()) with check (mfa_ok());

-- ============ STORAGE: bucket privado 'siniestros' ============
insert into storage.buckets (id, name, public) values ('siniestros', 'siniestros', false)
on conflict (id) do nothing;

-- Igual que 'solicitudes': la subida está abierta (el cliente anónimo no tiene otra forma de
-- probar quién es más que conocer la ruta exacta, que empieza con su token de liga mágica), pero
-- ver/borrar el archivo ya sí se restringe al dueño real del cliente dueño del siniestro.
create policy "cualquiera puede subir documentos de siniestros" on storage.objects
  for insert with check (bucket_id = 'siniestros');
create policy "dueño ve documentos de siniestros de sus clientes" on storage.objects
  for select using (bucket_id = 'siniestros' and exists(
    select 1 from siniestro_documentos d join siniestros s on s.id = d.siniestro_id join clientes c on c.id = s.cliente_id
    where d.path = objects.name and (c.agente_id = auth.uid() or c.promotoria_id = auth.uid())));
create policy "dueño borra documentos de siniestros de sus clientes" on storage.objects
  for delete using (bucket_id = 'siniestros' and exists(
    select 1 from siniestro_documentos d join siniestros s on s.id = d.siniestro_id join clientes c on c.id = s.cliente_id
    where d.path = objects.name and (c.agente_id = auth.uid() or c.promotoria_id = auth.uid())));

-- ============ Hueco encontrado de paso: 'solicitudes' seguía sin cubrir clientes de promotoría ============
-- Las políticas de storage.objects para el bucket 'solicitudes' (fotos de endoso) solo revisaban
-- s.agente_id = auth.uid() — un cliente propio de una promotoría (Sesión 43) podía subir la foto,
-- pero la promotoría nunca podría verla ni borrarla. Se corrige aquí de paso.
drop policy if exists "agente ve fotos de sus solicitudes" on storage.objects;
drop policy if exists "agente borra fotos de sus solicitudes" on storage.objects;
create policy "dueño ve fotos de sus solicitudes" on storage.objects
  for select using (bucket_id = 'solicitudes' and exists(
    select 1 from solicitudes s where s.foto_path = objects.name and (s.agente_id = auth.uid() or s.promotoria_id = auth.uid())));
create policy "dueño borra fotos de sus solicitudes" on storage.objects
  for delete using (bucket_id = 'solicitudes' and exists(
    select 1 from solicitudes s where s.foto_path = objects.name and (s.agente_id = auth.uid() or s.promotoria_id = auth.uid())));

-- ============ portal_crear_siniestro: el cliente levanta un caso desde su liga mágica ============
create or replace function public.portal_crear_siniestro(
  p_token uuid, p_tipo text, p_tipo_otro text default null, p_descripcion text default null,
  p_monto_reclamado numeric default null, p_fecha_evento date default null, p_poliza_id uuid default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cliente_id uuid;
  v_id uuid;
begin
  select id into v_cliente_id from clientes where token_publico = p_token;
  if v_cliente_id is null then
    raise exception 'Liga inválida';
  end if;
  if p_tipo not in ('gmm','reembolso','cirugia','otro') then
    raise exception 'Tipo de siniestro inválido';
  end if;
  if p_tipo = 'otro' and coalesce(trim(p_tipo_otro),'') = '' then
    raise exception 'Descríbenos de qué tipo es tu caso';
  end if;
  if p_poliza_id is not null and not exists(select 1 from polizas where id = p_poliza_id and cliente_id = v_cliente_id) then
    raise exception 'Póliza inválida';
  end if;

  insert into siniestros(cliente_id, poliza_id, tipo, tipo_otro, descripcion, monto_reclamado, fecha_evento, creado_por)
  values (v_cliente_id, p_poliza_id, p_tipo, p_tipo_otro, p_descripcion, p_monto_reclamado, p_fecha_evento, 'cliente')
  returning id into v_id;

  return v_id;
end;
$$;
grant execute on function public.portal_crear_siniestro(uuid,text,text,text,numeric,date,uuid) to anon, authenticated;

-- ============ portal_agregar_documento_siniestro: el cliente registra cada archivo ya subido ============
create or replace function public.portal_agregar_documento_siniestro(
  p_token uuid, p_siniestro_id uuid, p_path text, p_nombre_archivo text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cliente_id uuid;
begin
  select id into v_cliente_id from clientes where token_publico = p_token;
  if v_cliente_id is null then
    raise exception 'Liga inválida';
  end if;
  if not exists(select 1 from siniestros where id = p_siniestro_id and cliente_id = v_cliente_id) then
    raise exception 'Ese siniestro no te pertenece';
  end if;

  insert into siniestro_documentos(siniestro_id, path, nombre_archivo, subido_por)
  values (p_siniestro_id, p_path, p_nombre_archivo, 'cliente');
end;
$$;
grant execute on function public.portal_agregar_documento_siniestro(uuid,uuid,text,text) to anon, authenticated;

-- ============ portal_cliente: ahora también devuelve los siniestros del cliente ============
create or replace function public.portal_cliente(p_token uuid, p_nip text default null, p_dispositivo text default null) returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_ok boolean := false;
  resultado json;
begin
  select id, nip_hash, nip_intentos, nip_bloqueado_hasta into c
  from clientes where token_publico = p_token;

  if c.id is null then
    return null;
  end if;

  if c.nip_hash is null then
    v_ok := true;
  else
    if c.nip_bloqueado_hasta is not null and now() < c.nip_bloqueado_hasta then
      raise exception 'Demasiados intentos. Espera unos minutos e inténtalo de nuevo.';
    end if;

    if p_dispositivo is not null then
      update portal_dispositivos set ultimo_uso = now()
      where cliente_id = c.id
        and token_hash = encode(digest(p_dispositivo,'sha256'),'hex')
        and expira > now();
      if found then v_ok := true; end if;
    end if;

    if not v_ok and p_nip is not null and c.nip_hash = crypt(p_nip, c.nip_hash) then
      v_ok := true;
    end if;

    if v_ok then
      update clientes set nip_intentos = 0, nip_bloqueado_hasta = null where id = c.id;
    else
      if p_nip is not null or p_dispositivo is not null then
        update clientes set
          nip_intentos = nip_intentos + 1,
          nip_bloqueado_hasta = case when nip_intentos + 1 >= 5 then now() + interval '15 minutes' else null end
        where id = c.id;
        raise exception 'NIP incorrecto';
      end if;
      raise exception 'Necesitas tu NIP';
    end if;
  end if;

  select json_build_object(
    'cliente', json_build_object(
      'nombre', c2.nombre,
      'tipo_persona', c2.tipo_persona,
      'tiene_nip', c2.nip_hash is not null
    ),
    'agente', json_build_object(
      'nombre', a.nombre,
      'nombre_negocio', a.nombre_negocio,
      'correo', a.correo,
      'telefono', a.telefono,
      'alias_retiro', case when a.tipo = 'agente' and a.tarjeta_activa then a.alias_publico else null end
    ),
    'polizas', coalesce((
      select json_agg(json_build_object(
        'id', p.id,
        'ramo', p.ramo,
        'aseguradora', p.aseguradora,
        'numero_poliza', p.numero_poliza,
        'fecha_inicio', p.fecha_inicio,
        'fecha_fin', p.fecha_fin,
        'estatus', p.estatus,
        'prima', p.prima,
        'forma_pago', p.forma_pago,
        'pdf_url', p.pdf_url,
        'vehiculo_id', p.vehiculo_id
      ) order by p.fecha_fin desc nulls last)
      from polizas p where p.cliente_id = c2.id
    ), '[]'::json),
    'vehiculos', coalesce((
      select json_agg(json_build_object(
        'id', v.id,
        'placas', v.placas,
        'estado', v.estado,
        'marca', v.marca,
        'modelo', v.modelo,
        'anio', v.anio,
        'tipo_vehiculo', v.tipo_vehiculo,
        'fecha_verificacion', v.fecha_verificacion,
        'kilometraje_actual', v.kilometraje_actual,
        'fecha_registro_km', v.fecha_registro_km,
        'intervalo_mantenimiento_km', v.intervalo_mantenimiento_km,
        'fecha_ultimo_servicio', v.fecha_ultimo_servicio,
        'km_ultimo_servicio', v.km_ultimo_servicio,
        'notificaciones_activas', v.notificaciones_activas,
        'requiere_verificacion', coalesce(ev.requiere_verificacion, false),
        'tiene_poliza', exists(select 1 from polizas p2 where p2.vehiculo_id = v.id)
      ))
      from vehiculos v
      left join estados_verificacion ev on ev.estado = v.estado
      where v.cliente_id = c2.id
    ), '[]'::json),
    'siniestros', coalesce((
      select json_agg(json_build_object(
        'id', si.id,
        'tipo', si.tipo,
        'tipo_otro', si.tipo_otro,
        'descripcion', si.descripcion,
        'monto_reclamado', si.monto_reclamado,
        'fecha_evento', si.fecha_evento,
        'estatus', si.estatus,
        'created_at', si.created_at,
        'documentos', (select count(*) from siniestro_documentos sd where sd.siniestro_id = si.id)
      ) order by si.created_at desc)
      from siniestros si where si.cliente_id = c2.id
    ), '[]'::json)
  ) into resultado
  from clientes c2
  join duenos_clientes a on a.id = coalesce(c2.agente_id, c2.promotoria_id)
    and a.tipo = case when c2.agente_id is not null then 'agente' else 'promotoria' end
  where c2.id = c.id;

  return resultado;
end;
$$;

-- ============ Aviso al dueño cuando el cliente levanta un siniestro ============
create or replace function public.notificar_nuevo_siniestro() returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text;
  v_dueno_correo text;
  v_dueno_nombre text;
  v_cliente_nombre text;
  v_cliente_id uuid;
  v_agente_id uuid;
  v_promotoria_id uuid;
  v_etiqueta text;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'resend_api_key';
  if v_key is null then return new; end if;

  select nombre, agente_id, promotoria_id into v_cliente_nombre, v_agente_id, v_promotoria_id
  from clientes where id = new.cliente_id;

  select d.correo, coalesce(d.nombre, d.nombre_negocio) into v_dueno_correo, v_dueno_nombre
  from duenos_clientes d
  where d.id = coalesce(v_agente_id, v_promotoria_id)
    and d.tipo = case when v_agente_id is not null then 'agente' else 'promotoria' end;

  if v_dueno_correo is null then return new; end if;

  v_etiqueta := case new.tipo
    when 'gmm' then 'Siniestro de Gastos Médicos Mayores'
    when 'reembolso' then 'Reclamación de reembolso'
    when 'cirugia' then 'Programación de cirugía'
    else coalesce(new.tipo_otro, 'Siniestro') end;

  perform net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization','Bearer '||v_key,'Content-Type','application/json'),
    body := jsonb_build_object(
      'from','Upco InsurGest <notificaciones@upco.app>',
      'to', jsonb_build_array(v_dueno_correo),
      'subject', 'Nuevo caso: '||v_etiqueta,
      'html', format('<p>Hola %s,</p><p><strong>%s</strong> levantó un caso nuevo: <strong>%s</strong>.</p><p>%s</p><p>Entra a tu panel de InsurGest para ver los documentos que haya subido.</p>',
        coalesce(v_dueno_nombre,'agente'), coalesce(v_cliente_nombre,'Tu cliente'), v_etiqueta, coalesce(new.descripcion,''))
    )
  );
  return new;
end;
$$;

drop trigger if exists trg_notificar_siniestro on siniestros;
create trigger trg_notificar_siniestro after insert on siniestros
  for each row when (new.creado_por = 'cliente')
  execute function public.notificar_nuevo_siniestro();
