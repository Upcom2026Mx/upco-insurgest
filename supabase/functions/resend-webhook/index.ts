// Upco InsurGest — Edge Function: recibe eventos de Resend (aperturas, clics, rebotes, quejas)
// de la campaña de prospección y los registra contra el prospecto correspondiente.
//
// Resend llama a esta función directo, sin JWT de Supabase — igual que stripe-webhook, así que
// necesita "Verify JWT" APAGADO. La seguridad real es la verificación de firma: Resend firma
// sus webhooks con el estándar Svix (headers svix-id / svix-timestamp / svix-signature).
//
// Cómo desplegar:
//   supabase functions deploy resend-webhook --project-ref pxcvckqahkjlizgotvqw --no-verify-jwt
//
//   O por el Dashboard: Edge Functions > Create a new function > nombre exacto resend-webhook,
//   pegar este archivo, Deploy, y luego Settings > apagar "Verify JWT".
//
// Secret que necesita (Edge Functions > Secrets, a nivel proyecto):
//   RESEND_WEBHOOK_SECRET  — el que da Resend al crear el webhook (empieza con whsec_)
//
// En Resend: Webhooks > Add Webhook, URL = la de esta función, y marcar los eventos
// email.delivered, email.opened, email.clicked, email.bounced y email.complained.

import { Webhook } from "npm:svix@1";
import { createClient } from "npm:@supabase/supabase-js@2";

const RESEND_WEBHOOK_SECRET = Deno.env.get("RESEND_WEBHOOK_SECRET") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

// Los nombres que usa Resend -> los que usa la tabla prospecto_eventos.
// Deliberadamente NO se escucha email.sent: el envío ya se registra en enviar_lote_prospectos()
// en el momento de mandarlo, y contarlo dos veces rompería el cupo diario.
const TIPOS: Record<string, string> = {
  "email.delivered": "entregado",
  "email.opened": "abierto",
  "email.clicked": "clic",
  "email.bounced": "rebotado",
  "email.complained": "queja",
};

// Los tags viajan de ida en el POST /emails y vuelven en el webhook. Resend los ha
// representado de las dos formas según el evento y la versión de la API — como arreglo de
// {name, value} y como objeto plano — así que se aceptan ambas en lugar de asumir una.
function leerTags(tags: unknown): Record<string, string> {
  const salida: Record<string, string> = {};
  if (!tags) return salida;

  if (Array.isArray(tags)) {
    for (const t of tags) {
      const nombre = (t as { name?: string })?.name;
      const valor = (t as { value?: string })?.value;
      if (typeof nombre === "string" && typeof valor === "string") salida[nombre] = valor;
    }
    return salida;
  }

  if (typeof tags === "object") {
    for (const [k, v] of Object.entries(tags as Record<string, unknown>)) {
      if (typeof v === "string") salida[k] = v;
    }
  }
  return salida;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  if (!RESEND_WEBHOOK_SECRET) {
    console.error("Falta RESEND_WEBHOOK_SECRET en los secrets del proyecto");
    return new Response("Server misconfigured", { status: 500 });
  }

  // La firma se calcula sobre el cuerpo crudo: hay que leerlo como texto ANTES de parsearlo.
  const crudo = await req.text();

  let evento: { type?: string; data?: Record<string, unknown> };
  try {
    const wh = new Webhook(RESEND_WEBHOOK_SECRET);
    evento = wh.verify(crudo, {
      "svix-id": req.headers.get("svix-id") ?? "",
      "svix-timestamp": req.headers.get("svix-timestamp") ?? "",
      "svix-signature": req.headers.get("svix-signature") ?? "",
    }) as typeof evento;
  } catch (e) {
    console.error("Firma inválida:", e instanceof Error ? e.message : String(e));
    return new Response("Invalid signature", { status: 400 });
  }

  const tipo = TIPOS[evento.type ?? ""];
  if (!tipo) {
    // Evento que no nos interesa (email.sent, por ejemplo). 200 para que Resend no reintente.
    return new Response(JSON.stringify({ ignorado: evento.type }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  const data = evento.data ?? {};
  const tags = leerTags(data.tags);
  const prospectoId = tags.prospecto_id;

  // Sin tag de prospecto no es un correo de la campaña — puede ser cualquier otro correo de la
  // cuenta de Resend. Se ignora en silencio en vez de ensuciar la tabla.
  if (!prospectoId || !UUID_RE.test(prospectoId)) {
    return new Response(JSON.stringify({ ignorado: "sin prospecto_id" }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  const etapaCruda = Number.parseInt(tags.etapa ?? "", 10);
  const etapa = Number.isInteger(etapaCruda) && etapaCruda >= 1 && etapaCruda <= 3 ? etapaCruda : null;

  const liga = tipo === "clic"
    ? ((data.click as { link?: string } | undefined)?.link ?? null)
    : null;

  const { error } = await supabase.rpc("registrar_evento_prospecto", {
    p_prospecto_id: prospectoId,
    p_etapa: etapa,
    p_tipo: tipo,
    p_liga: liga,
  });

  if (error) {
    // 500 hace que Resend reintente, que es lo correcto si la base falló momentáneamente.
    console.error("No se pudo registrar el evento:", error.message);
    return new Response("Database error", { status: 500 });
  }

  return new Response(JSON.stringify({ registrado: tipo }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});
