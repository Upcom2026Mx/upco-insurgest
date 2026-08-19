-- Upco InsurGest — Sesión 71: exportar y eliminar cuenta de agente (derecho ARCO / LFPDPPP)
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- Hoy, en cuanto se le vence el acceso a un agente, la pantalla se reemplaza por completo con
-- "elige un plan" — sin forma de sacar su información, y si nunca vuelve a pagar sus datos se
-- quedan bloqueados para siempre (ningún cron los borra). Este flujo le da al agente una salida
-- real: exportar toda su información, y solo entonces poder eliminar su cuenta.
--
-- Decisión explícita del usuario: al eliminar su cuenta se borra TODO su libro de negocio junto
-- con él (clientes, pólizas, vehículos, siniestros, solicitudes) — la información está bajo su
-- resguardo como agente, no solo la suya propia. Se aprovechan las cascadas ON DELETE CASCADE ya
-- existentes de punta a punta (auth.users → agentes → clientes → vehiculos/polizas/solicitudes/
-- siniestros/portal_dispositivos/push_subscripciones) — un solo delete de auth.users limpia todo.

alter table agentes add column if not exists datos_exportados_en timestamptz;

create table bajas_agentes (
  id uuid primary key default gen_random_uuid(),
  agente_id uuid not null,
  correo text not null,
  nombre text,
  nombre_negocio text,
  clientes_eliminados int not null default 0,
  polizas_eliminadas int not null default 0,
  vehiculos_eliminados int not null default 0,
  siniestros_eliminados int not null default 0,
  solicitudes_eliminadas int not null default 0,
  exportado_en timestamptz,
  dado_de_baja_en timestamptz not null default now()
);

alter table bajas_agentes enable row level security;
create policy "admin ve las bajas de agentes" on bajas_agentes
  for select using (public.es_admin());

-- ----------------------------------------------------------------------------
-- Marca que el agente ya generó su exportación — requisito real para poder
-- eliminar su cuenta, no solo un candado de UI.
-- ----------------------------------------------------------------------------
create or replace function public.agente_confirmar_exportacion()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update agentes set datos_exportados_en = now() where id = auth.uid();
  if not found then
    raise exception 'No autorizado';
  end if;
end;
$$;

-- ----------------------------------------------------------------------------
-- Elimina la cuenta del agente y, en cascada, todo su libro de negocio.
-- Storage (PDFs de pólizas, fotos de solicitudes, foto de tarjeta) se limpia
-- desde el frontend ANTES de llamar esta función — Storage no participa de
-- cascadas SQL.
-- ----------------------------------------------------------------------------
create or replace function public.agente_eliminar_cuenta()
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid := auth.uid();
  v_agente record;
  v_clientes int;
  v_polizas int;
  v_vehiculos int;
  v_siniestros int;
  v_solicitudes int;
  v_key text;
begin
  select * into v_agente from agentes where id = v_id;
  if v_agente is null then
    raise exception 'No autorizado';
  end if;
  if v_agente.datos_exportados_en is null then
    raise exception 'Debes exportar tu información antes de eliminar tu cuenta.';
  end if;

  select count(*) into v_clientes from clientes where agente_id = v_id;
  select count(*) into v_polizas from polizas where cliente_id in (select id from clientes where agente_id = v_id);
  select count(*) into v_vehiculos from vehiculos where cliente_id in (select id from clientes where agente_id = v_id);
  select count(*) into v_siniestros from siniestros where cliente_id in (select id from clientes where agente_id = v_id);
  select count(*) into v_solicitudes from solicitudes where agente_id = v_id;

  insert into bajas_agentes(
    agente_id, correo, nombre, nombre_negocio,
    clientes_eliminados, polizas_eliminadas, vehiculos_eliminados, siniestros_eliminados, solicitudes_eliminadas,
    exportado_en
  ) values (
    v_id, v_agente.correo, v_agente.nombre, v_agente.nombre_negocio,
    v_clientes, v_polizas, v_vehiculos, v_siniestros, v_solicitudes,
    v_agente.datos_exportados_en
  );

  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'resend_api_key';
  if v_key is not null then
    perform net.http_post(
      url := 'https://api.resend.com/emails',
      headers := jsonb_build_object('Authorization','Bearer '||v_key,'Content-Type','application/json'),
      body := jsonb_build_object(
        'from','Upco InsurGest <notificaciones@upco.app>',
        'to', jsonb_build_array(v_agente.correo),
        'subject','Confirmación de baja de tu cuenta — Upco InsurGest',
        'html', format(
          '<p>Hola%s,</p>
          <p>Confirmamos que tu cuenta de Upco InsurGest y toda la información bajo tu resguardo fueron eliminadas de forma permanente el %s.</p>
          <p style="background:#F4F6FA;border:1px solid #DDE4EE;border-radius:8px;padding:12px 16px"><strong>Se eliminaron:</strong> %s clientes, %s pólizas, %s vehículos, %s siniestros y %s solicitudes.</p>
          <p>Esta acción es permanente y no se puede deshacer. Este correo es tu constancia de baja.</p>
          <p style="font-size:12.5px;color:#8593AA">Upco — empresa mexicana de tecnología.</p>',
          case when v_agente.nombre is not null then ' '||v_agente.nombre else '' end,
          to_char(now(),'DD/MM/YYYY HH24:MI'),
          v_clientes, v_polizas, v_vehiculos, v_siniestros, v_solicitudes
        )
      )
    );
    perform net.http_post(
      url := 'https://api.resend.com/emails',
      headers := jsonb_build_object('Authorization','Bearer '||v_key,'Content-Type','application/json'),
      body := jsonb_build_object(
        'from','Upco InsurGest <notificaciones@upco.app>',
        'to', jsonb_build_array('hola@upco.app'),
        'subject', format('Baja de agente — %s', coalesce(v_agente.nombre_negocio, v_agente.correo)),
        'html', format(
          '<p><strong>%s</strong> (%s) eliminó su cuenta.</p><p>Se eliminaron %s clientes, %s pólizas, %s vehículos, %s siniestros y %s solicitudes. Registro completo en /admin.</p>',
          coalesce(v_agente.nombre_negocio, v_agente.nombre, v_agente.correo), v_agente.correo,
          v_clientes, v_polizas, v_vehiculos, v_siniestros, v_solicitudes
        )
      )
    );
  end if;

  delete from auth.users where id = v_id;

  return json_build_object(
    'ok', true,
    'clientes', v_clientes, 'polizas', v_polizas, 'vehiculos', v_vehiculos,
    'siniestros', v_siniestros, 'solicitudes', v_solicitudes
  );
end;
$$;
