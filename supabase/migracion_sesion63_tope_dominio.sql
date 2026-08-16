-- ============================================================================
--  Sesión 63 — Tope compartido del dominio + freno automático de rebotes
--
--  Motivo: el 12 de agosto, escuelas y academias mandaron 20/día cada una,
--  más 10 de agencias_seguros — 50/día combinados desde theupgradecompany.mx,
--  un dominio sin historial de envío. El resultado: 22 rebotes en un solo día,
--  todos de servidores VIVOS (Gmail, Hotmail) rechazando activamente, no de
--  direcciones muertas. Cada segmento vigilaba su propio cupo, pero ninguno
--  sabía cuánto estaban mandando los otros dos desde el MISMO remitente.
--
--  Esta migración agrega dos protecciones que antes no existían:
--   1. Un tope diario COMPARTIDO entre los tres segmentos (no uno por cada uno).
--   2. Un freno automático: si un segmento pasa su tasa de rebote del día por
--      arriba del límite, se pausa solo — no hay que esperar a que alguien
--      note el problema horas después, como pasó hoy.
--
--  Ejecutar completo en el editor SQL de Supabase.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Ajustes del dominio (una sola fila, aplica a los tres segmentos juntos)
-- ----------------------------------------------------------------------------
create table if not exists prospeccion_dominio_ajustes (
  id boolean primary key default true check (id),
  tope_diario int not null default 15,
  -- % de rebote (sobre lo enviado HOY, por segmento) que dispara la pausa automática.
  bounce_maximo_pct numeric not null default 8,
  -- No evaluar el % hasta tener al menos esta cantidad de envíos hoy en ese segmento:
  -- 1 rebote de 2 enviados es 50% y no significa nada todavía.
  bounce_minimo_envios int not null default 8,
  actualizado_en timestamptz not null default now()
);
insert into prospeccion_dominio_ajustes(id) values (true) on conflict (id) do nothing;

alter table prospeccion_dominio_ajustes enable row level security;
drop policy if exists "admin ve tope del dominio" on prospeccion_dominio_ajustes;
create policy "admin ve tope del dominio" on prospeccion_dominio_ajustes
  for select using (public.es_admin());

-- ----------------------------------------------------------------------------
-- 2. enviar_lote_prospectos() — ahora respeta el tope compartido y se
--    auto-pausa por segmento si el rebote del día se dispara.
-- ----------------------------------------------------------------------------
create or replace function public.enviar_lote_prospectos()
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  dom record;
  a record;
  p record;
  t record;
  v_key text;
  v_inicio_dia timestamptz;
  v_enviados_hoy_dominio int;
  v_cupo_restante_dominio int;
  v_enviados_hoy_segmento int;
  v_rebotes_hoy_segmento int;
  v_cupo_hoy int;
  v_cupo_corrida int;
  v_enviados int;
  v_asunto text;
  v_html text;
  v_nombre_seguro text;
  v_detalle jsonb := '[]'::jsonb;
  v_total int := 0;
  v_auto_pausados jsonb := '[]'::jsonb;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'resend_api_key_campana';
  if v_key is null then
    return json_build_object('enviados', 0, 'motivo', 'falta resend_api_key_campana en Vault');
  end if;

  v_inicio_dia := (date_trunc('day', now() at time zone 'America/Mexico_City')) at time zone 'America/Mexico_City';

  select * into dom from prospeccion_dominio_ajustes where id;

  -- Tope del DOMINIO completo, sumando lo que ya mandó cualquier segmento hoy.
  select count(*) into v_enviados_hoy_dominio
    from prospecto_eventos where tipo = 'enviado' and ocurrio_en >= v_inicio_dia;
  v_cupo_restante_dominio := dom.tope_diario - v_enviados_hoy_dominio;

  if v_cupo_restante_dominio <= 0 then
    return json_build_object('enviados', 0, 'motivo', 'tope diario del dominio alcanzado',
      'tope_dominio', dom.tope_diario, 'enviados_hoy_dominio', v_enviados_hoy_dominio);
  end if;

  for a in select * from prospeccion_ajustes where activa order by segmento loop
    exit when v_cupo_restante_dominio <= 0;
    v_enviados := 0;

    -- Freno automático: ¿este segmento ya está rebotando fuerte HOY? Si sí, se pausa
    -- solo y no se le manda nada más en esta corrida ni en las siguientes de hoy.
    select count(*) into v_enviados_hoy_segmento
      from prospecto_eventos e join prospectos pr on pr.id = e.prospecto_id
      where e.tipo = 'enviado' and e.ocurrio_en >= v_inicio_dia and pr.segmento = a.segmento;
    select count(*) into v_rebotes_hoy_segmento
      from prospecto_eventos e join prospectos pr on pr.id = e.prospecto_id
      where e.tipo = 'rebotado' and e.ocurrio_en >= v_inicio_dia and pr.segmento = a.segmento;

    if v_enviados_hoy_segmento >= dom.bounce_minimo_envios
       and v_rebotes_hoy_segmento::numeric / v_enviados_hoy_segmento::numeric * 100 >= dom.bounce_maximo_pct
    then
      update prospeccion_ajustes set activa = false where segmento = a.segmento;
      v_auto_pausados := v_auto_pausados || jsonb_build_object(
        'segmento', a.segmento, 'enviados_hoy', v_enviados_hoy_segmento, 'rebotes_hoy', v_rebotes_hoy_segmento);
      v_detalle := v_detalle || jsonb_build_object('segmento', a.segmento, 'enviados', 0, 'motivo', 'auto-pausado por rebote alto');
      continue;
    end if;

    v_cupo_hoy := least(a.envios_por_dia - v_enviados_hoy_segmento, v_cupo_restante_dominio);

    if v_cupo_hoy > 0 then
      v_cupo_corrida := least(v_cupo_hoy, ceil(a.envios_por_dia::numeric / a.corridas_por_dia)::int);

      for p in
        select * from prospectos
        where segmento = a.segmento
          and estatus = 'activo'
          and (
            etapa = 0
            or (etapa = 1 and ultimo_envio_en <= now() - make_interval(days => a.dias_a_seguimiento))
            or (etapa = 2 and ultimo_envio_en <= now() - make_interval(days => a.dias_a_cierre))
          )
        order by etapa desc, ultimo_envio_en asc nulls last, importado_en asc
        limit v_cupo_corrida
      loop
        select * into t from prospecto_plantillas where segmento = a.segmento and ruta = p.ruta and etapa = p.etapa + 1;
        continue when t is null;

        v_nombre_seguro := replace(replace(replace(p.agencia,'&','&amp;'),'<','&lt;'),'>','&gt;');
        v_asunto := replace(replace(t.asunto, '{AGENCIA}', p.agencia), '{NOMBRE}', p.agencia);
        v_html := replace(replace(t.cuerpo_html, '{AGENCIA}', v_nombre_seguro), '{NOMBRE}', v_nombre_seguro)
                  || '<hr style="border:0;border-top:1px solid #DDE4EE;margin:24px 0">'
                  || '<p style="color:#8593AA;font-size:12px;line-height:1.5">' || a.pie_legal || '</p>';

        perform net.http_post(
          url := 'https://api.resend.com/emails',
          headers := jsonb_build_object('Authorization','Bearer '||v_key,'Content-Type','application/json'),
          body := jsonb_build_object(
            'from', a.remitente,
            'to', jsonb_build_array(p.correo),
            'reply_to', a.responder_a,
            'subject', v_asunto,
            'html', v_html,
            'tags', jsonb_build_array(
              jsonb_build_object('name','prospecto_id','value', p.id::text),
              jsonb_build_object('name','etapa','value', (p.etapa + 1)::text)
            ),
            'headers', jsonb_build_object(
              'List-Unsubscribe', '<mailto:' || a.responder_a || '?subject=BAJA>'
            )
          )
        );

        update prospectos
          set etapa = p.etapa + 1,
              ultimo_envio_en = now(),
              estatus = case when p.etapa + 1 >= 3 then 'completado' else estatus end
          where id = p.id;

        insert into prospecto_eventos(prospecto_id, etapa, tipo)
          values (p.id, p.etapa + 1, 'enviado');

        v_enviados := v_enviados + 1;
        v_cupo_restante_dominio := v_cupo_restante_dominio - 1;
        exit when v_cupo_restante_dominio <= 0;
      end loop;
    end if;

    v_detalle := v_detalle || jsonb_build_object('segmento', a.segmento, 'enviados', v_enviados);
    v_total := v_total + v_enviados;
  end loop;

  return json_build_object(
    'enviados', v_total, 'detalle', v_detalle,
    'tope_dominio', dom.tope_diario, 'cupo_restante_dominio', v_cupo_restante_dominio,
    'auto_pausados', v_auto_pausados
  );
end;
$$;

revoke all on function public.enviar_lote_prospectos() from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 3. RPCs para el panel: leer y guardar el tope compartido
-- ----------------------------------------------------------------------------
create or replace function public.admin_tope_dominio()
returns json
language plpgsql
security definer
set search_path = public
as $$
declare v_inicio_dia timestamptz; v_hoy int; dom record;
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  v_inicio_dia := (date_trunc('day', now() at time zone 'America/Mexico_City')) at time zone 'America/Mexico_City';
  select count(*) into v_hoy from prospecto_eventos where tipo='enviado' and ocurrio_en >= v_inicio_dia;
  select * into dom from prospeccion_dominio_ajustes where id;
  return json_build_object(
    'tope_diario', dom.tope_diario,
    'bounce_maximo_pct', dom.bounce_maximo_pct,
    'bounce_minimo_envios', dom.bounce_minimo_envios,
    'enviados_hoy_dominio', v_hoy,
    'segmentos', (select coalesce(json_agg(x order by x.segmento),'[]'::json) from (
      select segmento, activa, envios_por_dia from prospeccion_ajustes) x)
  );
end;
$$;
revoke all on function public.admin_tope_dominio() from public, anon, authenticated;
grant execute on function public.admin_tope_dominio() to authenticated;

create or replace function public.admin_guardar_tope_dominio(
  p_tope_diario int, p_bounce_maximo_pct numeric default null, p_bounce_minimo_envios int default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  update prospeccion_dominio_ajustes set
    tope_diario = p_tope_diario,
    bounce_maximo_pct = coalesce(p_bounce_maximo_pct, bounce_maximo_pct),
    bounce_minimo_envios = coalesce(p_bounce_minimo_envios, bounce_minimo_envios),
    actualizado_en = now()
  where id;
end;
$$;
revoke all on function public.admin_guardar_tope_dominio(int,numeric,int) from public, anon, authenticated;
grant execute on function public.admin_guardar_tope_dominio(int,numeric,int) to authenticated;

-- Reactivar un segmento puntual (para no exponer un update de tabla directo al panel).
create or replace function public.admin_reactivar_segmento(p_segmento text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  update prospeccion_ajustes set activa = true where segmento = p_segmento;
end;
$$;
revoke all on function public.admin_reactivar_segmento(text) from public, anon, authenticated;
grant execute on function public.admin_reactivar_segmento(text) to authenticated;

-- Arranca en 15/día combinado: re-calentamiento conservador tras el rechazo
-- masivo del 12 de agosto. Calendario de subida: ver la Sesión 63 en el
-- historial de chat con Claude.
update prospeccion_dominio_ajustes set tope_diario = 15 where id;
