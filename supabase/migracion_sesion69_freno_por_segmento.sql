-- Upco InsurGest — Sesión 69: el freno automático de rebote pasa a ser por segmento
--
-- Motivo: agencias_seguros y academias comparten hoy el mismo umbral (8% con
-- mínimo de 8 envíos), viviendo en prospeccion_dominio_ajustes como una sola
-- fila para los 3 segmentos. Pero llevan 3 días seguidos disparándose con el
-- mismo patrón (1 rebote de 8), y el histórico de cada uno cuenta una historia
-- distinta: agencias_seguros acumula 5.3% (sano — tuvo un día completo de 20
-- envíos sin un solo rebote) mientras academias acumula 17.9% (más del doble
-- del límite, con dos disparos reales en dos días seguidos). Subir el umbral
-- parejo para los tres arriesgaría dejar de notar un problema real en
-- academias/escuelas; el fundador decidió subirlo solo donde ya hay evidencia
-- de que es ruido: agencias_seguros.
--
-- tope_diario SÍ sigue siendo del dominio completo (es la reputación
-- compartida de theupgradecompany.mx) — eso no cambia, se queda en
-- prospeccion_dominio_ajustes.

alter table prospeccion_ajustes
  add column if not exists bounce_maximo_pct numeric not null default 8,
  add column if not exists bounce_minimo_envios int not null default 8;

-- El umbral real: agencias_seguros ya demostró ser sano, necesita más evidencia
-- antes de dispararse. Academias y escuelas se quedan en el mínimo original —
-- su histórico no lo respalda todavía.
update prospeccion_ajustes set bounce_minimo_envios = 20 where segmento = 'agencias_seguros';

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

    select count(*) into v_enviados_hoy_segmento
      from prospecto_eventos e join prospectos pr on pr.id = e.prospecto_id
      where e.tipo = 'enviado' and e.ocurrio_en >= v_inicio_dia and pr.segmento = a.segmento;
    select count(*) into v_rebotes_hoy_segmento
      from prospecto_eventos e join prospectos pr on pr.id = e.prospecto_id
      where e.tipo = 'rebotado' and e.ocurrio_en >= v_inicio_dia and pr.segmento = a.segmento;

    -- Umbral propio de CADA segmento (antes era el mismo para los 3, ver Sesión 69).
    if v_enviados_hoy_segmento >= a.bounce_minimo_envios
       and v_rebotes_hoy_segmento::numeric / v_enviados_hoy_segmento::numeric * 100 >= a.bounce_maximo_pct
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

-- prospeccion_dominio_ajustes se queda SOLO con tope_diario (lo único que
-- de verdad es del dominio completo). Las columnas de bounce ya no las lee
-- nadie -- se quitan para que no parezca que ajustarlas ahí sigue haciendo algo.
alter table prospeccion_dominio_ajustes drop column if exists bounce_maximo_pct;
alter table prospeccion_dominio_ajustes drop column if exists bounce_minimo_envios;

drop function if exists public.admin_tope_dominio();
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
    'enviados_hoy_dominio', v_hoy,
    'segmentos', (select coalesce(json_agg(x order by x.segmento),'[]'::json) from (
      select segmento, activa, envios_por_dia, bounce_maximo_pct, bounce_minimo_envios
      from prospeccion_ajustes) x)
  );
end;
$$;
revoke all on function public.admin_tope_dominio() from public, anon, authenticated;
grant execute on function public.admin_tope_dominio() to authenticated;

drop function if exists public.admin_guardar_tope_dominio(int,numeric,int);
create or replace function public.admin_guardar_tope_dominio(p_tope_diario int)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  update prospeccion_dominio_ajustes set tope_diario = p_tope_diario, actualizado_en = now() where id;
end;
$$;
revoke all on function public.admin_guardar_tope_dominio(int) from public, anon, authenticated;
grant execute on function public.admin_guardar_tope_dominio(int) to authenticated;

-- Reactivar: los disparos de hoy y ayer, en los dos casos, fueron 1 rebote
-- suelto -- no una racha real.
update prospeccion_ajustes set activa = true where segmento in ('agencias_seguros','academias');

-- Comprobación
do $$
declare v_umbral_agencias int;
begin
  select bounce_minimo_envios into v_umbral_agencias from prospeccion_ajustes where segmento='agencias_seguros';
  if v_umbral_agencias <> 20 then raise exception 'agencias_seguros quedó en % en vez de 20', v_umbral_agencias; end if;
  raise notice 'OK: agencias_seguros con umbral 20, academias/escuelas sin cambio en su umbral (8).';
end;
$$;
