// Upco InsurGest — Edge Function: recibe eventos de Stripe y actualiza el estatus de suscripción.
// Stripe llama a esta función directo (no manda un JWT de Supabase) — por eso esta función,
// a diferencia de las otras dos, necesita "Verify JWT" APAGADO en Settings.
// La seguridad real aquí es la verificación de firma de Stripe (STRIPE_WEBHOOK_SECRET).
//
// Cómo desplegar (Supabase Dashboard, sin CLI):
//   1. Edge Functions > Create a new function > nombre exacto: stripe-webhook
//   2. Pega este archivo completo, Deploy
//   3. Settings > apaga "Verify JWT with legacy secret"
//   4. Secrets: agrega STRIPE_SECRET_KEY y STRIPE_WEBHOOK_SECRET
//   5. En Stripe: Developers > Webhooks > Add endpoint, URL = la de esta función,
//      eventos: customer.subscription.created, customer.subscription.updated, customer.subscription.deleted

import Stripe from "npm:stripe@17";
import { createClient } from "npm:@supabase/supabase-js@2";

const STRIPE_SECRET_KEY = Deno.env.get("STRIPE_SECRET_KEY") ?? "";
const STRIPE_WEBHOOK_SECRET = Deno.env.get("STRIPE_WEBHOOK_SECRET") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const stripe = new Stripe(STRIPE_SECRET_KEY);
const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

function periodoDesdePrice(interval: string | undefined, intervalCount: number | undefined): string {
  if (interval === "month" && intervalCount === 3) return "trimestral";
  if (interval === "month" && intervalCount === 6) return "semestral";
  if (interval === "year") return "anual";
  return "mensual";
}

// current_period_end vivía en la suscripción, pero a partir de las versiones de API 2025+
// Stripe lo movió a cada ítem de la suscripción. Buscamos en ambos lugares y devolvemos
// null si no hay un valor usable — nunca una fecha inválida, que es lo que tronaba antes.
function finDePeriodo(sub: Stripe.Subscription): string | null {
  const item = sub.items?.data?.[0] as unknown as { current_period_end?: number } | undefined;
  const segundos = (sub as unknown as { current_period_end?: number }).current_period_end ?? item?.current_period_end;
  if (typeof segundos !== "number" || !Number.isFinite(segundos)) return null;
  const fecha = new Date(segundos * 1000);
  return Number.isNaN(fecha.getTime()) ? null : fecha.toISOString();
}

Deno.serve(async (req) => {
  const signature = req.headers.get("stripe-signature") ?? "";
  const rawBody = await req.text();

  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(rawBody, signature, STRIPE_WEBHOOK_SECRET);
  } catch (err) {
    return new Response(`Firma inválida: ${(err as Error).message}`, { status: 400 });
  }

  try {
    if (event.type === "customer.subscription.created" || event.type === "customer.subscription.updated") {
      const sub = event.data.object as Stripe.Subscription;
      const tipo = sub.metadata?.tipo;
      const id = sub.metadata?.id;
      if (tipo && id) {
        const tabla = tipo === "agente" ? "agentes" : "promotorias";
        const item = sub.items.data[0];
        const periodo = periodoDesdePrice(item?.price?.recurring?.interval, item?.price?.recurring?.interval_count);
        const cambios: Record<string, unknown> = {
          stripe_subscription_id: sub.id,
          estatus_suscripcion: sub.status,
          plan_periodo: periodo,
        };
        const vigenteHasta = finDePeriodo(sub);
        if (vigenteHasta) cambios.suscripcion_vigente_hasta = vigenteHasta;
        await supabase.from(tabla).update(cambios).eq("id", id);
      }
    } else if (event.type === "customer.subscription.deleted") {
      const sub = event.data.object as Stripe.Subscription;
      const tipo = sub.metadata?.tipo;
      const id = sub.metadata?.id;
      if (tipo && id) {
        const tabla = tipo === "agente" ? "agentes" : "promotorias";
        await supabase.from(tabla).update({ estatus_suscripcion: "canceled" }).eq("id", id);
      }
    }
  } catch (err) {
    return new Response(`Error procesando el evento: ${(err as Error).message}`, { status: 500 });
  }

  return new Response(JSON.stringify({ received: true }), { headers: { "Content-Type": "application/json" } });
});
