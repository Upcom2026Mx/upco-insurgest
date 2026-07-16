// Upco InsurGest — Edge Function: envía notificaciones push a un cliente.
// Se invoca desde revisar_vencimientos() vía pg_net (ver migracion_sesion12_push.sql).
// No pensada para llamarse directo desde el navegador — valida un secreto interno.
//
// Cómo desplegar (Supabase Dashboard, sin necesitar la CLI):
//   1. Edge Functions > Create a new function > nombre exacto: send-push
//   2. Pega este archivo completo en el editor
//   3. Edge Functions > send-push > Settings > Secrets: agrega
//        VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, PUSH_INTERNAL_SECRET
//      (los mismos valores que guardaste en Vault)
//   4. Deploy

import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

const VAPID_PUBLIC = Deno.env.get("VAPID_PUBLIC_KEY") ?? "";
const VAPID_PRIVATE = Deno.env.get("VAPID_PRIVATE_KEY") ?? "";
const INTERNAL_SECRET = Deno.env.get("PUSH_INTERNAL_SECRET") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

webpush.setVapidDetails("mailto:hola@upco.app", VAPID_PUBLIC, VAPID_PRIVATE);

Deno.serve(async (req) => {
  if (req.headers.get("x-internal-secret") !== INTERNAL_SECRET) {
    return new Response(JSON.stringify({ error: "No autorizado" }), { status: 401 });
  }

  const { cliente_id, agente_id, title, body, url } = await req.json();
  if ((!cliente_id && !agente_id) || !title) {
    return new Response(JSON.stringify({ error: "Falta cliente_id/agente_id o title" }), { status: 400 });
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  const query = supabase.from("push_subscripciones").select("*");
  const { data: subs, error } = cliente_id
    ? await query.eq("cliente_id", cliente_id)
    : await query.eq("agente_id", agente_id);

  if (error) {
    return new Response(JSON.stringify({ error: error.message }), { status: 500 });
  }
  if (!subs || subs.length === 0) {
    return new Response(JSON.stringify({ enviados: 0 }), { headers: { "Content-Type": "application/json" } });
  }

  const payload = JSON.stringify({ title, body: body ?? "", url: url ?? "https://insurgest.upco.app" });
  let enviados = 0;

  for (const sub of subs) {
    try {
      await webpush.sendNotification(
        { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } },
        payload
      );
      enviados++;
    } catch (err) {
      const statusCode = (err as { statusCode?: number }).statusCode;
      if (statusCode === 404 || statusCode === 410) {
        // suscripción vencida o inválida (el navegador la revocó) — se limpia
        await supabase.from("push_subscripciones").delete().eq("id", sub.id);
      }
    }
  }

  return new Response(JSON.stringify({ enviados }), { headers: { "Content-Type": "application/json" } });
});
