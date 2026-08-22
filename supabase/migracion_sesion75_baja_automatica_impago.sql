-- Upco InsurGest — Sesión 75: baja automática del agente tras 6 meses sin acceso vigente
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- Decisión del usuario: no tiene por qué guardar indefinidamente la información de alguien que
-- dejó de pagar — conservarla de más es lo que crea responsabilidad, no lo contrario. A los 6
-- meses la cuenta se elimina por completo, igual que en la baja voluntaria de la Sesión 71.
--
-- CONDICIÓN INNEGOCIABLE, acordada antes de construir: nunca se borra sin haber avisado. Tres
-- correos con enlace directo a exportar (mes 3, mes 5, y 15 días antes del corte). Es la
-- operación más destructiva del sistema y adentro hay datos de CLIENTES, no solo del agente.
--
-- El reloj lo lleva `agentes.sin_acceso_desde`, que el cron diario mantiene:
--   - si el agente recupera acceso, se pone en null y se reinician los avisos
--   - si lo pierde y estaba en null, se pone en now()
-- Se usa una columna y no una fecha calculada porque el acceso gratis de red depende del estado
-- VIGENTE de la promotoría: un agente en los primeros 5 lugares no paga nada y tiene acceso
-- legítimo — si su promotoría deja de pagar, él pierde acceso ese día, no antes. Eso no se puede
-- reconstruir hacia atrás desde las fechas del propio agente.
--
-- Efecto de la primera corrida: a todo agente hoy sin acceso se le pone el reloj en HOY. Nadie
-- se borra por haber dejado de pagar hace un año — todos arrancan de cero y reciben sus tres
-- avisos. Es a propósito.
--
-- Alcance: solo agentes. Promotorías y agencias máster no entran (igual que en la Sesión 71).

alter table agentes add column if not exists sin_acceso_desde timestamptz;
alter table agentes add column if not exists avisos_baja_enviados smallint not null default 0;
alter table bajas_agentes add column if not exists motivo text not null default 'voluntaria';

-- ----------------------------------------------------------------------------
-- Las 4 reglas de acceso vigente, en un solo lugar. Es el espejo en SQL de
-- accesoVigente() de shared.js más el acceso gratis de red de agente_estado_red().
-- ----------------------------------------------------------------------------
create or replace function public.agente_tiene_acceso(p_agente_id uuid)
returns boolean
language sql
stable security definer
set search_path = public
as $$
  select coalesce((
    select
      a.estatus_suscripcion in ('active','trialing')
      or (a.acceso_extendido_hasta is not null and a.acceso_extendido_hasta >= now())
      or (a.aprobado_en is not null and now() <= a.aprobado_en + interval '30 days')
      or coalesce((
        select v.posicion <= 5 and (
          p.estatus_suscripcion in ('active','trialing')
          or (p.acceso_extendido_hasta is not null and p.acceso_extendido_hasta >= now())
          or (p.aprobado_en is not null and now() <= p.aprobado_en + interval '30 days')
        )
        from promotorias p
        join public.vista_posicion_red v on v.id = a.id
        where p.id = a.promotoria_id
      ), false)
    from agentes a where a.id = p_agente_id
  ), false);
$$;

revoke all on function public.agente_tiene_acceso(uuid) from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- Elimina la cuenta de un agente inactivo. La llama la Edge Function
-- `eliminar-agente-inactivo` DESPUÉS de haber limpiado su Storage — igual que en
-- la Sesión 71 el frontend limpiaba Storage antes de llamar a la versión
-- voluntaria. Storage no participa de las cascadas SQL.
--
-- Revalida los 180 días por su cuenta: aunque la llamen con un id equivocado, se
-- niega a borrar a alguien que no cumple la condición.
-- ----------------------------------------------------------------------------
create or replace function public.admin_eliminar_agente_inactivo(p_agente_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_a record;
  v_clientes int; v_polizas int; v_vehiculos int; v_siniestros int; v_solicitudes int;
  v_key text;
begin
  select * into v_a from agentes where id = p_agente_id;
  if v_a is null then
    return json_build_object('ok', false, 'motivo', 'no existe');
  end if;
  if v_a.sin_acceso_desde is null or now() < v_a.sin_acceso_desde + interval '180 days' then
    return json_build_object('ok', false, 'motivo', 'todavia no cumple 180 dias sin acceso');
  end if;
  if public.agente_tiene_acceso(p_agente_id) then
    return json_build_object('ok', false, 'motivo', 'tiene acceso vigente');
  end if;

  select count(*) into v_clientes from clientes where agente_id = p_agente_id;
  select count(*) into v_polizas from polizas where cliente_id in (select id from clientes where agente_id = p_agente_id);
  select count(*) into v_vehiculos from vehiculos where cliente_id in (select id from clientes where agente_id = p_agente_id);
  select count(*) into v_siniestros from siniestros where cliente_id in (select id from clientes where agente_id = p_agente_id);
  select count(*) into v_solicitudes from solicitudes where agente_id = p_agente_id;

  insert into bajas_agentes(
    agente_id, correo, nombre, nombre_negocio,
    clientes_eliminados, polizas_eliminadas, vehiculos_eliminados, siniestros_eliminados, solicitudes_eliminadas,
    exportado_en, motivo
  ) values (
    p_agente_id, v_a.correo, v_a.nombre, v_a.nombre_negocio,
    v_clientes, v_polizas, v_vehiculos, v_siniestros, v_solicitudes,
    v_a.datos_exportados_en, 'automatica_impago'
  );

  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'resend_api_key';
  if v_key is not null then
    perform net.http_post(
      url := 'https://api.resend.com/emails',
      headers := jsonb_build_object('Authorization','Bearer '||v_key,'Content-Type','application/json'),
      body := jsonb_build_object(
        'from','Upco InsurGest <notificaciones@upco.app>',
        'to', jsonb_build_array(v_a.correo),
        'subject','Tu cuenta de Upco InsurGest fue eliminada',
        'html', format(
          '<p>Hola%s,</p>
          <p>Tu cuenta estuvo 6 meses sin una suscripción vigente. Como te avisamos en tres ocasiones, hoy %s fue eliminada de forma permanente junto con toda la información que tenías bajo tu resguardo.</p>
          <p style="background:#F4F6FA;border:1px solid #DDE4EE;border-radius:8px;padding:12px 16px"><strong>Se eliminaron:</strong> %s clientes, %s pólizas, %s vehículos, %s siniestros y %s solicitudes.</p>
          <p>No conservamos copia. Esta acción es permanente y este correo es tu constancia de baja.</p>
          <p>Si quieres volver a trabajar con nosotros, puedes crear una cuenta nueva cuando gustes en <a href="https://insurgest.upco.app">insurgest.upco.app</a>.</p>
          <p style="font-size:12.5px;color:#8593AA">Upco — empresa mexicana de tecnología.</p>',
          case when v_a.nombre is not null then ' '||v_a.nombre else '' end,
          to_char(now(),'DD/MM/YYYY'),
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
        'subject', format('Baja automática por impago — %s', coalesce(v_a.nombre_negocio, v_a.correo)),
        'html', format(
          '<p><strong>%s</strong> (%s) fue eliminado automáticamente tras 6 meses sin acceso vigente.</p><p>Se eliminaron %s clientes, %s pólizas, %s vehículos, %s siniestros y %s solicitudes. Registro completo en /admin.</p>',
          coalesce(v_a.nombre_negocio, v_a.nombre, v_a.correo), v_a.correo,
          v_clientes, v_polizas, v_vehiculos, v_siniestros, v_solicitudes
        )
      )
    );
  end if;

  delete from auth.users where id = p_agente_id;

  return json_build_object('ok', true, 'clientes', v_clientes, 'polizas', v_polizas,
    'vehiculos', v_vehiculos, 'siniestros', v_siniestros, 'solicitudes', v_solicitudes);
end;
$$;

revoke all on function public.admin_eliminar_agente_inactivo(uuid) from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- Cron diario: mantiene el reloj, manda los 3 avisos y dispara la eliminación.
--
-- La eliminación NO se hace aquí: se llama a la Edge Function, que primero limpia
-- Storage (Storage no se puede borrar bien desde SQL — borrar la fila de
-- storage.objects deja el archivo huérfano en el bucket) y solo después llama a
-- admin_eliminar_agente_inactivo(). Si la Edge Function falla, el agente
-- simplemente no se borra hoy y se vuelve a intentar mañana.
-- ----------------------------------------------------------------------------
create or replace function public.revisar_bajas_por_impago()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  v_key text;
  v_secret text;
  v_asunto text;
  v_intro text;
  v_cierre text;
  v_etapa smallint;
begin
  -- 1. Reloj: quien recuperó acceso vuelve a cero; quien lo perdió arranca hoy.
  update agentes set sin_acceso_desde = null, avisos_baja_enviados = 0
    where sin_acceso_desde is not null and public.agente_tiene_acceso(id);

  update agentes set sin_acceso_desde = now(), avisos_baja_enviados = 0
    where sin_acceso_desde is null and not public.agente_tiene_acceso(id);

  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'resend_api_key';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'push_internal_secret';

  -- 2. Avisos. Cada etapa se manda una sola vez (avisos_baja_enviados lleva la cuenta).
  for r in
    select a.id, a.correo, a.nombre, a.avisos_baja_enviados, a.sin_acceso_desde,
      case
        when now() >= a.sin_acceso_desde + interval '165 days' then 3
        when now() >= a.sin_acceso_desde + interval '150 days' then 2
        when now() >= a.sin_acceso_desde + interval '90 days'  then 1
        else 0
      end as etapa
    from agentes a
    where a.sin_acceso_desde is not null
      and now() < a.sin_acceso_desde + interval '180 days'
  loop
    v_etapa := r.etapa;
    continue when v_etapa = 0 or v_etapa <= r.avisos_baja_enviados or v_key is null;

    if v_etapa = 1 then
      v_asunto := 'Tu información sigue guardada — pero no para siempre';
      v_intro  := 'Han pasado 3 meses desde que tu acceso a Upco InsurGest dejó de estar vigente. Tu información sigue completa y a salvo.';
      v_cierre := 'Si ya no piensas volver, puedes descargar todo tu libro de negocio cuando quieras. A los 6 meses sin suscripción vigente la cuenta se elimina de forma permanente.';
    elsif v_etapa = 2 then
      v_asunto := 'Quedan 30 días para descargar tu información';
      v_intro  := 'Han pasado 5 meses desde que tu acceso dejó de estar vigente. En 30 días tu cuenta y toda la información bajo tu resguardo se eliminarán de forma permanente.';
      v_cierre := 'Todavía estás a tiempo de descargar todo — clientes, pólizas, vehículos, siniestros y solicitudes — en archivos que puedes abrir en Excel.';
    else
      v_asunto := 'Últimos 15 días antes de eliminar tu cuenta';
      v_intro  := 'Este es el último aviso. En 15 días tu cuenta de Upco InsurGest y toda la información bajo tu resguardo se eliminarán de forma permanente, sin copia de respaldo.';
      v_cierre := 'Si hay algo que quieras conservar, descárgalo ahora. Si prefieres seguir con nosotros, basta con reactivar tu suscripción y el proceso se detiene solo.';
    end if;

    perform net.http_post(
      url := 'https://api.resend.com/emails',
      headers := jsonb_build_object('Authorization','Bearer '||v_key,'Content-Type','application/json'),
      body := jsonb_build_object(
        'from','Upco InsurGest <notificaciones@upco.app>',
        'to', jsonb_build_array(r.correo),
        'subject', v_asunto,
        'html', format(
          '<p>Hola%s,</p>
          <p>%s</p>
          <p>%s</p>
          <p style="margin:22px 0"><a href="https://insurgest.upco.app/app/" style="background:#10284A;color:#fff;text-decoration:none;font-weight:700;padding:12px 22px;border-radius:8px;display:inline-block">Entrar y descargar mi información</a></p>
          <p style="font-size:13px;color:#5B6B82">Entra con tu correo y contraseña de siempre. La opción de descargar está en la pantalla de suscripción, y no necesitas pagar nada para usarla.</p>
          <p style="font-size:12.5px;color:#8593AA">Upco — empresa mexicana de tecnología.</p>',
          case when r.nombre is not null then ' '||r.nombre else '' end,
          v_intro, v_cierre
        )
      )
    );

    update agentes set avisos_baja_enviados = v_etapa where id = r.id;
  end loop;

  -- 3. Los que ya cumplieron 6 meses: se le pasa el encargo a la Edge Function.
  for r in
    select a.id from agentes a
    where a.sin_acceso_desde is not null
      and now() >= a.sin_acceso_desde + interval '180 days'
      and not public.agente_tiene_acceso(a.id)
  loop
    perform net.http_post(
      url := 'https://pxcvckqahkjlizgotvqw.supabase.co/functions/v1/eliminar-agente-inactivo',
      headers := jsonb_build_object(
        'Content-Type','application/json',
        'Authorization','Bearer sb_publishable_F2WhknXrY8MLjI5ftd0H6w_-XXjej6I',
        'x-internal-secret', v_secret
      ),
      body := jsonb_build_object('agente_id', r.id)
    );
  end loop;
end;
$$;

revoke all on function public.revisar_bajas_por_impago() from public, anon, authenticated;

-- 7am hora CDMX, una hora antes del cron de vencimientos para no encimar envíos de Resend.
select cron.unschedule('insurgest-bajas-por-impago')
  where exists (select 1 from cron.job where jobname = 'insurgest-bajas-por-impago');
select cron.schedule('insurgest-bajas-por-impago', '0 13 * * *', 'select public.revisar_bajas_por_impago();');
