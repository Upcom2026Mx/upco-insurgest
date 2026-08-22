// Upco InsurGest — Edge Function: elimina la cuenta de un agente inactivo (6 meses sin acceso).
//
// La llama SOLO el cron diario `revisar_bajas_por_impago()` vía pg_net. Su trabajo es la parte
// que SQL no puede hacer bien: borrar los archivos de Storage. Borrar la fila de storage.objects
// desde SQL deja el archivo huérfano dentro del bucket — solo la API de Storage lo elimina de
// verdad. Por eso el orden es: primero limpiar Storage (aquí), y hasta entonces llamar a
// admin_eliminar_agente_inactivo(), que hace el conteo, el registro de baja, los correos y el
// delete de auth.users que cascadea el resto.
//
// Cómo desplegar (Supabase Dashboard, sin CLI):
//   1. Edge Functions > Create a new function > nombre exacto: eliminar-agente-inactivo
//   2. Pega este archivo completo, Deploy
//   3. No hay secretos nuevos: reusa PUSH_INTERNAL_SECRET, que ya existe desde la Sesión 11.

import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const INTERNAL_SECRET = Deno.env.get("PUSH_INTERNAL_SECRET") ?? "";

Deno.serve(async (req) => {
  try {
    // Nadie más que el cron debe poder invocar esto. El gateway de Supabase ya exige un JWT
    // válido (la anon key), pero eso lo tiene cualquiera que lea el código del front — el
    // candado real es este secreto, que solo vive en Vault y en los Secrets de la función.
    if (!INTERNAL_SECRET || req.headers.get("x-internal-secret") !== INTERNAL_SECRET) {
      return new Response(JSON.stringify({ error: "No autorizado" }), { status: 401 });
    }

    const { agente_id } = await req.json();
    if (!agente_id) {
      return new Response(JSON.stringify({ error: "Falta agente_id" }), { status: 400 });
    }

    const sb = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    const { data: agente } = await sb.from("agentes")
      .select("tarjeta_foto_path, sin_acceso_desde").eq("id", agente_id).maybeSingle();
    if (!agente) {
      return new Response(JSON.stringify({ ok: false, motivo: "no existe" }), { status: 404 });
    }

    // ---- Revalidar ANTES de tocar Storage ----
    // Los archivos se borran antes que la base, así que si la baja no procede hay que
    // enterarse AQUÍ: si se limpiara Storage y después admin_eliminar_agente_inactivo()
    // se negara (porque el agente reactivó su suscripción entre el barrido del cron y esta
    // llamada), el agente se quedaría con su cuenta viva pero sin sus PDFs.
    const corte = agente.sin_acceso_desde
      ? new Date(new Date(agente.sin_acceso_desde).getTime() + 180 * 86400000)
      : null;
    if (!corte || new Date() < corte) {
      return new Response(JSON.stringify({ ok: false, motivo: "todavia no cumple 180 dias sin acceso" }), { status: 409 });
    }
    const { data: tieneAcceso } = await sb.rpc("agente_tiene_acceso", { p_agente_id: agente_id });
    if (tieneAcceso !== false) {
      return new Response(JSON.stringify({ ok: false, motivo: "tiene acceso vigente" }), { status: 409 });
    }

    // ---- Recolectar todo lo que este agente tiene en Storage ----

    const { data: clientes } = await sb.from("clientes").select("id").eq("agente_id", agente_id);
    const clienteIds = (clientes ?? []).map((c) => c.id);

    const rutas: Record<string, string[]> = { polizas: [], solicitudes: [], siniestros: [], tarjetas: [] };

    if (agente.tarjeta_foto_path) rutas.tarjetas.push(agente.tarjeta_foto_path);

    const { data: solicitudes } = await sb.from("solicitudes").select("foto_path").eq("agente_id", agente_id);
    for (const s of solicitudes ?? []) if (s.foto_path) rutas.solicitudes.push(s.foto_path);

    if (clienteIds.length) {
      const { data: polizas } = await sb.from("polizas").select("pdf_path").in("cliente_id", clienteIds);
      for (const p of polizas ?? []) if (p.pdf_path) rutas.polizas.push(p.pdf_path);

      // Documentos de siniestros: es el hueco que quedó abierto en la Sesión 71 — el borrado
      // voluntario desde el frontend nunca los limpió. Aquí sí se cierran.
      const { data: siniestros } = await sb.from("siniestros").select("id").in("cliente_id", clienteIds);
      const siniestroIds = (siniestros ?? []).map((s) => s.id);
      if (siniestroIds.length) {
        const { data: docs } = await sb.from("siniestro_documentos").select("path").in("siniestro_id", siniestroIds);
        for (const d of docs ?? []) if (d.path) rutas.siniestros.push(d.path);
      }
    }

    // ---- Borrar de Storage ANTES de tocar la base ----
    // Si algo aquí falla, se aborta sin borrar nada: el agente se queda un día más y el cron
    // lo vuelve a intentar mañana. Preferible eso a dejar archivos suyos vivos sin dueño.
    const borrados: Record<string, number> = {};
    for (const [bucket, lista] of Object.entries(rutas)) {
      if (!lista.length) { borrados[bucket] = 0; continue; }
      const { error } = await sb.storage.from(bucket).remove(lista);
      if (error) {
        return new Response(
          JSON.stringify({ ok: false, motivo: `no se pudo limpiar el bucket ${bucket}: ${error.message}` }),
          { status: 500 },
        );
      }
      borrados[bucket] = lista.length;
    }

    // ---- Y ahora sí, la baja. La función revalida los 180 días por su cuenta. ----
    const { data: resultado, error: errRpc } = await sb.rpc("admin_eliminar_agente_inactivo", { p_agente_id: agente_id });
    if (errRpc) {
      return new Response(JSON.stringify({ ok: false, motivo: errRpc.message }), { status: 500 });
    }

    return new Response(JSON.stringify({ ...resultado, archivos_borrados: borrados }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    return new Response(JSON.stringify({ error: (err as Error).message }), { status: 500 });
  }
});
