-- Upco InsurGest — Sesión 76: Proyecto 100 (lista de prospectos del agente novel)
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- Qué es: el "Proyecto 100" es el ritual de arranque de todo agente de seguros nuevo — hace una
-- lista de 100, 200 o 300 conocidos de su mercado natural y los llama uno por uno buscando sus
-- primeras pólizas. Hoy eso se hace en un cuaderno o en Excel.
--
-- Por qué vive en InsurGest, decidido con el usuario: un agente recién reclutado abre la
-- herramienta y no tiene NADA — ni pólizas, ni clientes, ni renovaciones. Es la peor primera
-- experiencia posible, y es justo el perfil que un gerente acaba de reclutar. El Proyecto 100 le
-- da una razón para usarla desde el día uno, y de paso le da al gerente un motivo concreto para
-- ponerle el software en las manos de entrada — que es lo que hace que funcione en la práctica
-- el 17% del Agente Libre.
--
-- Ojo con el nombre: la tabla `prospectos` (8,700+ filas) que ya existe es OTRA cosa — es la
-- campaña de prospección del propio fundador hacia agencias. Esta es del agente hacia sus
-- conocidos, por eso `prospectos_agente`.
--
-- La prueba de 30 días NO se toca (decisión explícita del usuario): el Proyecto 100 se trabaja en
-- ~3 meses, así que el corte cae con la lista ya cargada y la herramienta ya metida en su rutina.
-- Es el mejor momento del año para pedirle que pague, y su información no se pierde — sigue ahí
-- 6 meses con avisos y descarga, por lo que se construyó en la Sesión 75.

alter table agentes add column if not exists meta_proyecto smallint not null default 100;

create table if not exists prospectos_agente (
  id uuid primary key default gen_random_uuid(),
  agente_id uuid not null references agentes(id) on delete cascade,
  nombre text not null,
  telefono text,
  correo text,
  origen text,
  etapa text not null default 'por_llamar'
    check (etapa in ('por_llamar','contactado','cotizando','cerrado','descartado')),
  proximo_seguimiento date,
  notas text,
  cliente_id uuid references clientes(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists idx_prospectos_agente_agente on prospectos_agente(agente_id, etapa);
create index if not exists idx_prospectos_agente_seguimiento on prospectos_agente(agente_id, proximo_seguimiento)
  where proximo_seguimiento is not null;

create table if not exists prospecto_agente_bitacora (
  id uuid primary key default gen_random_uuid(),
  prospecto_id uuid not null references prospectos_agente(id) on delete cascade,
  nota text not null,
  created_at timestamptz not null default now()
);

create index if not exists idx_bitacora_prospecto on prospecto_agente_bitacora(prospecto_id, created_at desc);

-- Las 4 políticas desde el inicio, como quedó de norma del proyecto tras el olvido de DELETE
-- en `agentes` en la Sesión 1.
alter table prospectos_agente enable row level security;
drop policy if exists "agente ve sus prospectos" on prospectos_agente;
drop policy if exists "agente crea sus prospectos" on prospectos_agente;
drop policy if exists "agente edita sus prospectos" on prospectos_agente;
drop policy if exists "agente borra sus prospectos" on prospectos_agente;
create policy "agente ve sus prospectos"    on prospectos_agente for select using (agente_id = auth.uid());
create policy "agente crea sus prospectos"  on prospectos_agente for insert with check (agente_id = auth.uid());
create policy "agente edita sus prospectos" on prospectos_agente for update using (agente_id = auth.uid()) with check (agente_id = auth.uid());
create policy "agente borra sus prospectos" on prospectos_agente for delete using (agente_id = auth.uid());

-- La bitácora se aísla vía EXISTS contra el prospecto, igual que vehiculos/polizas contra
-- clientes — no se denormaliza agente_id, siguiendo el modelo de FKs del proyecto.
alter table prospecto_agente_bitacora enable row level security;
drop policy if exists "agente ve su bitacora" on prospecto_agente_bitacora;
drop policy if exists "agente crea su bitacora" on prospecto_agente_bitacora;
drop policy if exists "agente edita su bitacora" on prospecto_agente_bitacora;
drop policy if exists "agente borra su bitacora" on prospecto_agente_bitacora;
create policy "agente ve su bitacora" on prospecto_agente_bitacora for select
  using (exists (select 1 from prospectos_agente p where p.id = prospecto_id and p.agente_id = auth.uid()));
create policy "agente crea su bitacora" on prospecto_agente_bitacora for insert
  with check (exists (select 1 from prospectos_agente p where p.id = prospecto_id and p.agente_id = auth.uid()));
create policy "agente edita su bitacora" on prospecto_agente_bitacora for update
  using (exists (select 1 from prospectos_agente p where p.id = prospecto_id and p.agente_id = auth.uid()));
create policy "agente borra su bitacora" on prospecto_agente_bitacora for delete
  using (exists (select 1 from prospectos_agente p where p.id = prospecto_id and p.agente_id = auth.uid()));

-- ----------------------------------------------------------------------------
-- El momento que cierra el círculo: un prospecto que compró se vuelve cliente sin
-- volver a capturar nada. Ahí el agente aprende el flujo completo de la herramienta
-- sin que nadie se lo explique, y la póliza nace dentro del sistema.
-- ----------------------------------------------------------------------------
create or replace function public.prospecto_convertir_en_cliente(p_prospecto_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_p record;
  v_cliente_id uuid;
begin
  select * into v_p from prospectos_agente where id = p_prospecto_id and agente_id = auth.uid();
  if v_p is null then
    raise exception 'No autorizado';
  end if;
  if v_p.cliente_id is not null then
    return json_build_object('ok', true, 'cliente_id', v_p.cliente_id, 'ya_existia', true);
  end if;

  insert into clientes(agente_id, nombre, tipo_persona, telefono, correo, notas)
  values (
    auth.uid(), v_p.nombre, 'fisica', v_p.telefono, v_p.correo,
    case when v_p.origen is not null then 'Del Proyecto 100 — '||v_p.origen else 'Del Proyecto 100' end
  )
  returning id into v_cliente_id;

  update prospectos_agente
    set cliente_id = v_cliente_id, etapa = 'cerrado', proximo_seguimiento = null
    where id = p_prospecto_id;

  insert into prospecto_agente_bitacora(prospecto_id, nota)
    values (p_prospecto_id, 'Se convirtió en cliente.');

  return json_build_object('ok', true, 'cliente_id', v_cliente_id, 'ya_existia', false);
end;
$$;

-- ----------------------------------------------------------------------------
-- Resumen para el contador de avance. Es el corazón del ejercicio: el agente novel
-- trabaja contra un número (100/200/300) y necesita verlo moverse.
-- ----------------------------------------------------------------------------
create or replace function public.proyecto_cien_resumen()
returns json
language sql
stable security definer
set search_path = public
as $$
  select json_build_object(
    'meta', (select meta_proyecto from agentes where id = auth.uid()),
    'total',       count(*),
    'por_llamar',  count(*) filter (where etapa = 'por_llamar'),
    'contactado',  count(*) filter (where etapa = 'contactado'),
    'cotizando',   count(*) filter (where etapa = 'cotizando'),
    'cerrado',     count(*) filter (where etapa = 'cerrado'),
    'descartado',  count(*) filter (where etapa = 'descartado'),
    'vencidos',    count(*) filter (where proximo_seguimiento is not null
                                      and proximo_seguimiento <= current_date
                                      and etapa not in ('cerrado','descartado'))
  )
  from prospectos_agente where agente_id = auth.uid();
$$;
