-- Upco InsurGest — esquema inicial multi-tenant (Sesión 1)
-- Pegar completo en Supabase > SQL Editor > New query > Run

create extension if not exists pgcrypto;

-- ============ AGENTES ============
-- id = mismo id que auth.users (se llena cuando el agente inicia sesión, Sesión 2)
create table agentes (
  id uuid primary key references auth.users(id) on delete cascade,
  nombre text,
  correo text,
  telefono text,
  nombre_negocio text,
  created_at timestamptz not null default now()
);

-- ============ CLIENTES ============
create table clientes (
  id uuid primary key default gen_random_uuid(),
  agente_id uuid not null references agentes(id) on delete cascade,
  tipo_persona text not null check (tipo_persona in ('fisica','moral')),
  nombre text not null, -- nombre completo (física) o razón social (moral)
  rfc text,
  curp text,
  correo text,
  telefono text,
  notas text,
  created_at timestamptz not null default now(),
  constraint curp_solo_persona_fisica check (tipo_persona = 'fisica' or curp is null)
);
create index idx_clientes_agente on clientes(agente_id);

-- ============ VEHÍCULOS (hasta 5 por cliente) ============
create table vehiculos (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid not null references clientes(id) on delete cascade,
  placas text,
  estado text, -- estado de la república donde están registradas las placas
  marca text,
  modelo text,
  anio int,
  tipo_vehiculo text not null check (tipo_vehiculo in ('familiar','comercial','carga')),
  tipo_carga text check (tipo_carga in ('A','B','C')),
  fecha_verificacion date,
  created_at timestamptz not null default now(),
  constraint tipo_carga_solo_vehiculo_carga check (tipo_vehiculo = 'carga' or tipo_carga is null)
);
create index idx_vehiculos_cliente on vehiculos(cliente_id);

-- máximo 5 vehículos por cliente
create or replace function limite_vehiculos_por_cliente() returns trigger as $$
begin
  if (select count(*) from vehiculos where cliente_id = new.cliente_id) >= 5 then
    raise exception 'Un cliente no puede tener más de 5 vehículos registrados.';
  end if;
  return new;
end;
$$ language plpgsql;

create trigger trg_limite_vehiculos
before insert on vehiculos
for each row execute function limite_vehiculos_por_cliente();

-- ============ PÓLIZAS ============
create table polizas (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid not null references clientes(id) on delete cascade,
  vehiculo_id uuid references vehiculos(id) on delete set null, -- solo aplica si ramo = 'Auto'
  aseguradora text,
  numero_poliza text,
  ramo text not null default 'Auto', -- Auto, Vida, PPR, Gastos Médicos, Hogar, Otro (lista abierta)
  fecha_inicio date,
  fecha_fin date,
  prima numeric(12,2),
  forma_pago text check (forma_pago in ('anual','semestral','trimestral','mensual')),
  estatus text not null default 'vigente' check (estatus in ('vigente','vencida','renovada','cancelada')),
  pdf_url text, -- se llena en la Sesión 3
  notas text,
  created_at timestamptz not null default now(),
  constraint vehiculo_solo_ramo_auto check (ramo = 'Auto' or vehiculo_id is null)
);
create index idx_polizas_cliente on polizas(cliente_id);

-- ============ ROW LEVEL SECURITY (aislamiento por agente) ============
alter table agentes enable row level security;
alter table clientes enable row level security;
alter table vehiculos enable row level security;
alter table polizas enable row level security;

create policy "agente ve su propio perfil" on agentes for select using (id = auth.uid());
create policy "agente crea su propio perfil" on agentes for insert with check (id = auth.uid());
create policy "agente edita su propio perfil" on agentes for update using (id = auth.uid());

create policy "agente ve sus clientes" on clientes for select using (agente_id = auth.uid());
create policy "agente crea sus clientes" on clientes for insert with check (agente_id = auth.uid());
create policy "agente edita sus clientes" on clientes for update using (agente_id = auth.uid());
create policy "agente elimina sus clientes" on clientes for delete using (agente_id = auth.uid());

create policy "agente ve vehiculos de sus clientes" on vehiculos for select using (
  exists (select 1 from clientes c where c.id = vehiculos.cliente_id and c.agente_id = auth.uid())
);
create policy "agente crea vehiculos de sus clientes" on vehiculos for insert with check (
  exists (select 1 from clientes c where c.id = vehiculos.cliente_id and c.agente_id = auth.uid())
);
create policy "agente edita vehiculos de sus clientes" on vehiculos for update using (
  exists (select 1 from clientes c where c.id = vehiculos.cliente_id and c.agente_id = auth.uid())
);
create policy "agente elimina vehiculos de sus clientes" on vehiculos for delete using (
  exists (select 1 from clientes c where c.id = vehiculos.cliente_id and c.agente_id = auth.uid())
);

create policy "agente ve polizas de sus clientes" on polizas for select using (
  exists (select 1 from clientes c where c.id = polizas.cliente_id and c.agente_id = auth.uid())
);
create policy "agente crea polizas de sus clientes" on polizas for insert with check (
  exists (select 1 from clientes c where c.id = polizas.cliente_id and c.agente_id = auth.uid())
);
create policy "agente edita polizas de sus clientes" on polizas for update using (
  exists (select 1 from clientes c where c.id = polizas.cliente_id and c.agente_id = auth.uid())
);
create policy "agente elimina polizas de sus clientes" on polizas for delete using (
  exists (select 1 from clientes c where c.id = polizas.cliente_id and c.agente_id = auth.uid())
);
