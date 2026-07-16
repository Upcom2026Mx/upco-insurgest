// Upco InsurGest — Edge Function: crea una sesión de Stripe Checkout para suscribirse.
// Llamada desde /app o /promotor con la sesión del propio agente/promotoría (sb.functions.invoke).
//
// Cómo desplegar (Supabase Dashboard, sin CLI):
//   1. Edge Functions > Create a new function > nombre exacto: create-checkout-session
//   2. Pega este archivo completo, Deploy
//   3. Edge Functions > Secrets: agrega STRIPE_SECRET_KEY (tu llave secreta de Stripe, empieza con sk_)

import Stripe from "npm:stripe@17";
import { createClient } from "npm:@supabase/supabase-js@2";

const STRIPE_SECRET_KEY = Deno.env.get("STRIPE_SECRET_KEY") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const stripe = new Stripe(STRIPE_SECRET_KEY);

Deno.serve(async (req) => {
  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const supabaseAuth = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userError } = await supabaseAuth.auth.getUser();
    if (userError || !userData?.user) {
      return new Response(JSON.stringify({ error: "No autenticado" }), { status: 401 });
    }
    const userId = userData.user.id;
    const userEmail = userData.user.email ?? undefined;

    const { tipo, periodo } = await req.json();
    if (!["agente", "promotoria_base"].includes(tipo) || !["mensual", "trimestral", "semestral", "anual"].includes(periodo)) {
      return new Response(JSON.stringify({ error: "tipo o periodo inválido" }), { status: 400 });
    }

    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    const tabla = tipo === "agente" ? "agentes" : "promotorias";

    const { data: cuenta, error: cuentaError } = await supabase.from(tabla).select("*").eq("id", userId).maybeSingle();
    if (cuentaError || !cuenta) {
      return new Response(JSON.stringify({ error: "Cuenta no encontrada" }), { status: 404 });
    }

    const { data: precio } = await supabase
      .from("stripe_precios")
      .select("price_id")
      .eq("tipo", tipo)
      .eq("periodo", periodo)
      .maybeSingle();
    if (!precio?.price_id) {
      return new Response(JSON.stringify({ error: "Ese plan todavía no tiene precio configurado en Stripe" }), { status: 400 });
    }

    let customerId = cuenta.stripe_customer_id as string | null;
    if (!customerId) {
      const customer = await stripe.customers.create({ email: userEmail, metadata: { tipo, id: userId } });
      customerId = customer.id;
      await supabase.from(tabla).update({ stripe_customer_id: customerId }).eq("id", userId);
    }

    const portal = tipo === "agente" ? "app" : "promotor";
    const session = await stripe.checkout.sessions.create({
      customer: customerId,
      mode: "subscription",
      line_items: [{ price: precio.price_id, quantity: 1 }],
      success_url: `https://insurgest.upco.app/${portal}/?suscripcion=exito`,
      cancel_url: `https://insurgest.upco.app/${portal}/?suscripcion=cancelada`,
      metadata: { tipo, id: userId },
      subscription_data: { metadata: { tipo, id: userId } },
    });

    return new Response(JSON.stringify({ url: session.url }), { headers: { "Content-Type": "application/json" } });
  } catch (err) {
    return new Response(JSON.stringify({ error: (err as Error).message }), { status: 500 });
  }
});
