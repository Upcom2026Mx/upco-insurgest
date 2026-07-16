-- Upco InsurGest — Suscripciones de pago (Stripe): columnas, prueba de 30 días, extensión manual
-- Pegar completo en Supabase > SQL Editor > New query > Run

-- ============ COLUMNAS DE SUSCRIPCIÓN EN agentes ============
alter table agentes add column stripe_customer_id text;
alter table agentes add column stripe_subscription_id text;
alter table agentes add column estatus_suscripcion text; -- null | trialing | active | past_due | canceled
alter table agentes add column plan_periodo text; -- mensual | trimestral | semestral | anual
alter table agentes add column suscripcion_vigente_hasta timestamptz;
alter table agentes add column acceso_extendido_hasta timestamptz; -- override manual del fundador
alter table agentes add column aprobado_en timestamptz;

-- a los ya aprobados les damos una prueba de 30 días a partir de hoy (no se bloquean retroactivamente)
update agentes set aprobado_en = now() where estatus_aprobacion = 'aprobado' and aprobado_en is null;

-- ============ MISMAS COLUMNAS EN promotorias ============
alter table promotorias add column stripe_customer_id text;
alter table promotorias add column stripe_subscription_id text;
alter table promotorias add column estatus_suscripcion text;
alter table promotorias add column plan_periodo text;
alter table promotorias add column suscripcion_vigente_hasta timestamptz;
alter table promotorias add column acceso_extendido_hasta timestamptz;
alter table promotorias add column aprobado_en timestamptz;

update promotorias set aprobado_en = now() where estatus_aprobacion = 'aprobado' and aprobado_en is null;

-- ============ APROBAR YA DEJA REGISTRADO aprobado_en (para aprobaciones futuras) ============
create or replace function public.admin_aprobar_agente(p_agente_id uuid) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then
    raise exception 'No autorizado';
  end if;
  update agentes set estatus_aprobacion = 'aprobado', aprobado_en = coalesce(aprobado_en, now()) where id = p_agente_id;
end;
$$;

create or replace function public.promotoria_aprobar_agente(p_agente_id uuid) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_promotoria() then
    raise exception 'No autorizado';
  end if;
  update agentes set estatus_aprobacion = 'aprobado', aprobado_en = coalesce(aprobado_en, now()) where id = p_agente_id and promotoria_id = auth.uid();
end;
$$;

create or replace function public.admin_aprobar_promotoria(p_promotoria_id uuid) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then
    raise exception 'No autorizado';
  end if;
  update promotorias set estatus_aprobacion = 'aprobado', aprobado_en = coalesce(aprobado_en, now()) where id = p_promotoria_id;
end;
$$;

-- ============ CATÁLOGO DE PRECIOS DE STRIPE (llena price_id cuando crees los productos) ============
-- No es legible por agentes/promotorías — solo la Edge Function (con service role) la consulta.
create table stripe_precios (
  tipo text not null check (tipo in ('agente','promotoria_base')),
  periodo text not null check (periodo in ('mensual','trimestral','semestral','anual')),
  price_id text,
  primary key (tipo, periodo)
);
alter table stripe_precios enable row level security;

insert into stripe_precios (tipo, periodo) values
('agente','mensual'),('agente','trimestral'),('agente','semestral'),('agente','anual'),
('promotoria_base','mensual'),('promotoria_base','trimestral'),('promotoria_base','semestral'),('promotoria_base','anual');

-- ============ EXTENSIÓN MANUAL DE ACCESO (el fundador comp-ea sin necesitar Stripe) ============
create or replace function public.admin_extender_acceso_agente(p_agente_id uuid, p_dias int) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  update agentes set acceso_extendido_hasta = greatest(coalesce(acceso_extendido_hasta, now()), now()) + (p_dias || ' days')::interval
  where id = p_agente_id;
end;
$$;
grant execute on function public.admin_extender_acceso_agente(uuid,int) to authenticated;

create or replace function public.admin_extender_acceso_promotoria(p_promotoria_id uuid, p_dias int) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  update promotorias set acceso_extendido_hasta = greatest(coalesce(acceso_extendido_hasta, now()), now()) + (p_dias || ' days')::interval
  where id = p_promotoria_id;
end;
$$;
grant execute on function public.admin_extender_acceso_promotoria(uuid,int) to authenticated;

-- ============ admin_agentes() / admin_promotorias() AHORA INCLUYEN EL ESTATUS DE SUSCRIPCIÓN ============
create or replace function public.admin_agentes() returns json
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
        a.id, a.nombre, a.correo, a.telefono, a.nombre_negocio, a.estatus_aprobacion,
        a.rfc, a.tiene_cedula, a.tipos_cedula, a.numero_cedula,
        a.acepto_terminos, a.acepto_terminos_version, a.acepto_terminos_fecha,
        a.estatus_suscripcion, a.plan_periodo, a.acceso_extendido_hasta, a.aprobado_en,
        a.created_at as creado,
        (select count(*) from clientes c where c.agente_id = a.id) as clientes,
        (select count(*) from polizas p join clientes c on c.id = p.cliente_id where c.agente_id = a.id) as polizas
      from agentes a
    ) t
  ), '[]'::json);
end;
$$;

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
        p.estatus_suscripcion, p.plan_periodo, p.acceso_extendido_hasta, p.aprobado_en,
        p.created_at as creado,
        (select count(*) from agentes a where a.promotoria_id = p.id) as agentes
      from promotorias p
    ) t
  ), '[]'::json);
end;
$$;
