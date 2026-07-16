// Upco InsurGest — Edge Function: abre el Portal de Cliente de Stripe.
// Ahí el agente/promotoría cancela su suscripción, cambia su tarjeta y descarga sus facturas,
// sin que nosotros tengamos que construir ni mantener esas pantallas.
//
// Cómo desplegar (Supabase Dashboard, sin CLI):
//   1. Edge Functions > Create a new function > nombre exacto: create-portal-session
//   2. Pega este archivo completo, Deploy
//   3. Deja "Verify JWT" PRENDIDO (la llama el navegador con la sesión del propio agente)
//   4. No necesita secretos nuevos: reusa STRIPE_SECRET_KEY
//   5. En Stripe hay que activar el portal una vez: Configuración > Facturación >
//      Portal de clientes > guardar la configuración (si no, la API responde 400).

import Stripe from "npm:stripe@17";
import { createClient } from "npm:@supabase/supabase-js@2";

const STRIPE_SECRET_KEY = Deno.env.get("STRIPE_SECRET_KEY") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const stripe = new Stripe(STRIPE_SECRET_KEY);

// Mismo motivo que en create-checkout-session: la llama el navegador desde otro dominio.
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = { ...cors, "Content-Type": "application/json" };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: cors });
  }

  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const supabaseAuth = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userError } = await supabaseAuth.auth.getUser();
    if (userError || !userData?.user) {
      return new Response(JSON.stringify({ error: "No autenticado" }), { status: 401, headers: json });
    }
    const userId = userData.user.id;

    const { tipo } = await req.json();
    if (!["agente", "promotoria_base"].includes(tipo)) {
      return new Response(JSON.stringify({ error: "tipo inválido" }), { status: 400, headers: json });
    }

    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    const tabla = tipo === "agente" ? "agentes" : "promotorias";

    const { data: cuenta } = await supabase.from(tabla).select("stripe_customer_id").eq("id", userId).maybeSingle();
    if (!cuenta?.stripe_customer_id) {
      return new Response(JSON.stringify({ error: "Todavía no tienes un pago registrado" }), { status: 400, headers: json });
    }

    const portal = tipo === "agente" ? "app" : "promotor";
    const sesion = await stripe.billingPortal.sessions.create({
      customer: cuenta.stripe_customer_id,
      return_url: `https://insurgest.upco.app/${portal}/`,
    });

    return new Response(JSON.stringify({ url: sesion.url }), { headers: json });
  } catch (err) {
    return new Response(JSON.stringify({ error: (err as Error).message }), { status: 500, headers: json });
  }
});
