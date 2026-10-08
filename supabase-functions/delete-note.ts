// delete-note — admin permanently deletes a note (any status).
// Blocked if the note already has approved sales (reject instead).
// Auth: admin user JWT, or WA_ADMIN_SECRET (WhatsApp admin script).
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPA_URL = "https://xsvkyiigcjibgkcytssr.supabase.co";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const WA_SECRET = Deno.env.get("WA_ADMIN_SECRET") || "";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const J = (o: unknown, s = 200) =>
  new Response(JSON.stringify(o), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

async function isAdmin(req: Request, body: Record<string, unknown>, supa: ReturnType<typeof createClient>) {
  if (WA_SECRET && body.admin_secret === WA_SECRET) return true;
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!jwt) return false;
  const { data: { user } } = await supa.auth.getUser(jwt);
  if (!user) return false;
  const { data: row } = await supa.from("users").select("is_admin").eq("uid", user.id).single();
  return !!row?.is_admin;
}

function toPath(u: string | null): string | null {
  try {
    const m = String(u || "").split("/storage/v1/object/public/notes/");
    return m.length > 1 ? decodeURIComponent(m[1].split("?")[0]) : null;
  } catch { return null; }
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const supa = createClient(SUPA_URL, SERVICE_KEY);
    let body: Record<string, unknown> = {};
    try { body = await req.json(); } catch { return J({ error: "bad json" }, 400); }
    if (!(await isAdmin(req, body, supa))) return J({ error: "forbidden" }, 403);

    const { note_id } = body as { note_id: string | number };
    const { data: n } = await supa.from("notes").select("note_id,file_url,image_urls").eq("note_id", note_id).single();
    if (!n) return J({ error: "note not found" }, 404);

    // Block delete if already sold
    const { data: sold } = await supa.from("orders").select("order_id")
      .eq("note_id", note_id).eq("status", "approved").limit(1);
    if (sold && sold.length) return J({ error: "already sold — reject instead of delete" }, 400);

    // Best-effort storage cleanup
    const paths: string[] = [];
    const p1 = toPath(n.file_url); if (p1) paths.push(p1);
    try {
      const arr = JSON.parse((n as { image_urls?: string }).image_urls || "[]");
      (Array.isArray(arr) ? arr : [(n as { image_urls?: string }).image_urls]).forEach((u: string) => {
        const q = toPath(u); if (q) paths.push(q);
      });
    } catch { const q2 = toPath((n as { image_urls?: string }).image_urls || null); if (q2) paths.push(q2); }
    if (paths.length) { try { await supa.storage.from("notes").remove(paths); } catch { /* best effort */ } }

    // Remove non-approved related orders, then the note
    await supa.from("orders").delete().eq("note_id", note_id).neq("status", "approved");
    const { error: dErr } = await supa.from("notes").delete().eq("note_id", note_id);
    if (dErr) return J({ error: dErr.message }, 500);
    return J({ ok: true, note_id });
  } catch (e) {
    return J({ error: String((e as Error)?.message || e) }, 500);
  }
});
