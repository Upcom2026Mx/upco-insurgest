-- Upco InsurGest — Portal de promotoría + medidor de almacenamiento por agente
-- Pegar completo en Supabase > SQL Editor > New query > Run

-- ============ PROMOTORÍAS ============
create table promotorias (
  id uuid primary key references auth.users(id) on delete cascade,
  correo text not null,
  nombre text,
  nombre_negocio text,
  rfc text,
  codigo_invitacion text not null unique default upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6)),
  estatus_aprobacion text not null default 'pendiente' check (estatus_aprobacion in ('pendiente','aprobado','rechazado')),
  acepto_terminos boolean not null default false,
  acepto_terminos_version text,
  acepto_terminos_fecha timestamptz,
  created_at timestamptz not null default now()
);

alter table promotorias enable row level security;

create policy "promotoria ve su propia fila" on promotorias
  for select using (auth.uid() = id);
create policy "promotoria crea su propia fila" on promotorias
  for insert with check (auth.uid() = id);
create policy "promotoria edita su propia fila" on promotorias
  for update using (auth.uid() = id);

-- ============ VÍNCULO AGENTE → PROMOTORÍA ============
alter table agentes add column promotoria_id uuid references promotorias(id) on delete set null;

-- ============ CANDADO DE PROMOTORÍA ============
create or replace function public.es_promotoria() returns boolean
language sql stable
security definer
set search_path = public
as $$
  select exists(select 1 from promotorias where id = auth.uid() and estatus_aprobacion = 'aprobado');
$$;
grant execute on function public.es_promotoria() to authenticated;

-- ============ RESOLVER CÓDIGO DE INVITACIÓN (usado por un agente al registrarse) ============
create or replace function public.resolver_codigo_promotoria(p_codigo text) returns uuid
language sql stable
security definer
set search_path = public
as $$
  select id from promotorias where codigo_invitacion = upper(trim(p_codigo)) and estatus_aprobacion = 'aprobado';
$$;
grant execute on function public.resolver_codigo_promotoria(text) to authenticated;

-- ============ RESUMEN DE LA PROMOTORÍA ============
create or replace function public.promotoria_resumen() returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_promotoria() then
    raise exception 'No autorizado';
  end if;
  return json_build_object(
    'agentes_totales', (select count(*) from agentes where promotoria_id = auth.uid()),
    'agentes_pendientes', (select count(*) from agentes where promotoria_id = auth.uid() and estatus_aprobacion = 'pendiente'),
    'agentes_aprobados', (select count(*) from agentes where promotoria_id = auth.uid() and estatus_aprobacion = 'aprobado'),
    'clientes_totales', (select count(*) from clientes c join agentes a on a.id = c.agente_id where a.promotoria_id = auth.uid()),
    'polizas_totales', (select count(*) from polizas p join clientes c on c.id = p.cliente_id join agentes a on a.id = c.agente_id where a.promotoria_id = auth.uid())
  );
end;
$$;
grant execute on function public.promotoria_resumen() to authenticated;

-- ============ AGENTES DE LA PROMOTORÍA ============
create or replace function public.promotoria_agentes() returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_promotoria() then
    raise exception 'No autorizado';
  end if;
  return coalesce((
    select json_agg(t order by t.creado desc) from (
      select
        a.id, a.nombre, a.correo, a.telefono, a.nombre_negocio, a.estatus_aprobacion,
        a.created_at as creado,
        (select count(*) from clientes c where c.agente_id = a.id) as clientes,
        (select count(*) from polizas p join clientes c on c.id = p.cliente_id where c.agente_id = a.id) as polizas
      from agentes a
      where a.promotoria_id = auth.uid()
    ) t
  ), '[]'::json);
end;
$$;
grant execute on function public.promotoria_agentes() to authenticated;

-- ============ APROBAR / RECHAZAR AGENTE DE LA PROPIA RED ============
create or replace function public.promotoria_aprobar_agente(p_agente_id uuid) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_promotoria() then
    raise exception 'No autorizado';
  end if;
  update agentes set estatus_aprobacion = 'aprobado' where id = p_agente_id and promotoria_id = auth.uid();
end;
$$;
grant execute on function public.promotoria_aprobar_agente(uuid) to authenticated;

create or replace function public.promotoria_rechazar_agente(p_agente_id uuid) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_promotoria() then
    raise exception 'No autorizado';
  end if;
  update agentes set estatus_aprobacion = 'rechazado' where id = p_agente_id and promotoria_id = auth.uid();
end;
$$;
grant execute on function public.promotoria_rechazar_agente(uuid) to authenticated;

-- ============ ADMIN: VISIBILIDAD Y APROBACIÓN DE PROMOTORÍAS ============
create or replace function public.admin_promotorias() returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then
    raise exception 'No autorizado';
  end if;
  return coalesce((
    select json_agg(t order by t.creado desc) from (
      select
        p.id, p.nombre, p.correo, p.nombre_negocio, p.rfc, p.codigo_invitacion, p.estatus_aprobacion,
        p.created_at as creado,
        (select count(*) from agentes a where a.promotoria_id = p.id) as agentes
      from promotorias p
    ) t
  ), '[]'::json);
end;
$$;
grant execute on function public.admin_promotorias() to authenticated;

create or replace function public.admin_aprobar_promotoria(p_promotoria_id uuid) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then
    raise exception 'No autorizado';
  end if;
  update promotorias set estatus_aprobacion = 'aprobado' where id = p_promotoria_id;
end;
$$;
grant execute on function public.admin_aprobar_promotoria(uuid) to authenticated;

create or replace function public.admin_rechazar_promotoria(p_promotoria_id uuid) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then
    raise exception 'No autorizado';
  end if;
  update promotorias set estatus_aprobacion = 'rechazado' where id = p_promotoria_id;
end;
$$;
grant execute on function public.admin_rechazar_promotoria(uuid) to authenticated;

-- Se agregan conteos de promotorías al resumen global del fundador
create or replace function public.admin_resumen() returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then
    raise exception 'No autorizado';
  end if;
  return json_build_object(
    'agentes_totales', (select count(*) from agentes),
    'agentes_pendientes', (select count(*) from agentes where estatus_aprobacion = 'pendiente'),
    'agentes_aprobados', (select count(*) from agentes where estatus_aprobacion = 'aprobado'),
    'promotorias_totales', (select count(*) from promotorias),
    'promotorias_pendientes', (select count(*) from promotorias where estatus_aprobacion = 'pendiente'),
    'clientes_totales', (select count(*) from clientes),
    'polizas_totales', (select count(*) from polizas),
    'prima_total_vigente', (
      select coalesce(sum(prima),0) from polizas
      where estatus not in ('renovada','cancelada')
        and (fecha_fin is null or fecha_fin >= current_date)
    )
  );
end;
$$;

-- ============ MEDIDOR DE ALMACENAMIENTO (PDFs de pólizas) ============
create or replace function public.mi_uso_almacenamiento() returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum((metadata->>'size')::bigint), 0)
  from storage.objects
  where bucket_id = 'polizas'
    and (storage.foldername(name))[1] = auth.uid()::text;
$$;
grant execute on function public.mi_uso_almacenamiento() to authenticated;
