// Upco InsurGest — Edge Function: trae los indicadores del día desde la API del SIE de
// Banco de México y los guarda en la tabla indicadores_financieros.
// Se invoca desde actualizar_indicadores_banxico() vía pg_net, programada por pg_cron
// (ver migracion_sesion46_indicadores_banxico.sql).
//
// No está pensada para llamarse desde el navegador: valida un secreto interno y por eso
// tampoco necesita CORS (igual que send-push).
//
// Cómo desplegar:
//   supabase functions deploy actualizar-indicadores --project-ref pxcvckqahkjlizgotvqw
//
// Secretos que necesita (Edge Functions > Secrets, a nivel proyecto):
//   BANXICO_TOKEN        — token gratuito de https://www.banxico.org.mx/SieAPIRest/service/v1/token
//   PUSH_INTERNAL_SECRET — ya existe; se reutiliza porque es el mismo límite de confianza

import { createClient } from "npm:@supabase/supabase-js@2";

const BANXICO_TOKEN = Deno.env.get("BANXICO_TOKEN") ?? "";
const INTERNAL_SECRET = Deno.env.get("PUSH_INTERNAL_SECRET") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

// Identificadores de serie del SIE. Si alguno cambiara o resultara inválido, Banxico
// rechaza la consulta completa — por eso el mapeo de abajo es por idSerie y no por
// posición: así, si algún día se agrega o quita una serie, no se desalinean los valores.
const SERIES = {
  SF43718: "usd_fix", // Tipo de cambio pesos por dólar (FIX)
  SP68257: "udis",    // Valor de la UDI
  SF43783: "tiie28",  // TIIE a 28 días
} as const;

// Banxico entrega los números como texto y usa "N/E" cuando no hay dato publicado
// (días inhábiles, por ejemplo). Devolver null en esos casos deja la columna vacía en vez
// de escribir un 0 que se vería como un tipo de cambio de cero pesos en el panel.
function aNumero(valor: unknown): number | null {
  if (typeof valor !== "string") return null;
  const limpio = valor.replace(/,/g, "").trim();
  if (limpio === "" || limpio.toUpperCase() === "N/E") return null;
  const n = Number(limpio);
  return Number.isFinite(n) ? n : null;
}

// Banxico devuelve la fecha como dd/mm/aaaa; Postgres espera aaaa-mm-dd.
function aFechaISO(fecha: unknown): string | null {
  if (typeof fecha !== "string") return null;
  const m = fecha.trim().match(/^(\d{2})\/(\d{2})\/(\d{4})$/);
  return m ? `${m[3]}-${m[2]}-${m[1]}` : null;
}

Deno.serve(async (req) => {
  if (req.headers.get("x-internal-secret") !== INTERNAL_SECRET) {
    return new Response(JSON.stringify({ error: "No autorizado" }), { status: 401 });
  }
  if (!BANXICO_TOKEN) {
    return new Response(JSON.stringify({ error: "Falta el secreto BANXICO_TOKEN" }), { status: 500 });
  }

  // Se pide un RANGO de fechas en vez del endpoint /oportuno. Razón: /oportuno devuelve
  // solo el último dato publicado de cada serie, y Banxico publica la UDI con hasta dos
  // semanas de anticipación — así que para la UDI ese "último dato" siempre cae en el
  // futuro y nunca se obtendría el valor de hoy. Pidiendo los últimos 15 días se resuelve
  // eso y de paso se llena histórico, que es lo que alimenta las flechas de variación.
  const hoy = new Date();
  const desde = new Date(hoy.getTime() - 15 * 24 * 60 * 60 * 1000);
  const iso = (d: Date) => d.toISOString().slice(0, 10);

  const ids = Object.keys(SERIES).join(",");
  const url = `https://www.banxico.org.mx/SieAPIRest/service/v1/series/${ids}/datos/${iso(desde)}/${iso(hoy)}`;

  let json: { bmx?: { series?: Array<{ idSerie?: string; datos?: Array<{ fecha?: string; dato?: string }> }> } };
  try {
    // El token va por header en vez de query string para que no quede escrito en logs
    // de red ni en el historial de peticiones.
    const resp = await fetch(url, { headers: { "Bmx-Token": BANXICO_TOKEN } });
    if (!resp.ok) {
      return new Response(
        JSON.stringify({ error: `Banxico respondió ${resp.status}`, detalle: await resp.text() }),
        { status: 502, headers: { "Content-Type": "application/json" } },
      );
    }
    json = await resp.json();
  } catch (err) {
    return new Response(
      JSON.stringify({ error: "No se pudo consultar Banxico", detalle: String(err) }),
      { status: 502, headers: { "Content-Type": "application/json" } },
    );
  }

  const series = json?.bmx?.series ?? [];
  if (series.length === 0) {
    return new Response(JSON.stringify({ error: "Banxico no devolvió series" }), { status: 502 });
  }

  // Las series pueden traer fechas distintas entre sí (la UDI se publica todos los días,
  // el FIX solo en días hábiles). Se agrupa por fecha y se escribe una fila por cada una,
  // en vez de forzar todo a la fecha de hoy — así el histórico queda correcto.
  const porFecha: Record<string, Record<string, number | null>> = {};
  for (const s of series) {
    const campo = SERIES[s.idSerie as keyof typeof SERIES];
    if (!campo) continue;
    for (const punto of s.datos ?? []) {
      const fecha = aFechaISO(punto.fecha);
      const valor = aNumero(punto.dato);
      if (!fecha || valor === null) continue;
      porFecha[fecha] = porFecha[fecha] ?? {};
      porFecha[fecha][campo] = valor;
    }
  }

  const filas = Object.entries(porFecha).map(([fecha, campos]) => ({
    fecha,
    ...campos,
    actualizado_en: new Date().toISOString(),
  }));

  if (filas.length === 0) {
    return new Response(JSON.stringify({ guardados: 0, nota: "Sin datos nuevos publicados" }), {
      headers: { "Content-Type": "application/json" },
    });
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  const { error } = await supabase
    .from("indicadores_financieros")
    .upsert(filas, { onConflict: "fecha" });

  if (error) {
    return new Response(JSON.stringify({ error: error.message }), { status: 500 });
  }

  return new Response(JSON.stringify({ guardados: filas.length, filas }), {
    headers: { "Content-Type": "application/json" },
  });
});
