// track-view — increments notes.views by 1. Public (view counts are not sensitive).
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPA_URL = "https://xsvkyiigcjibgkcytssr.supabase.co";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const J = (o: unknown, s = 200) =>
  new Response(JSON.stringify(o), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const body = await req.json();
    const note_id = Number(body.note_id);
    if (!note_id) return J({ error: "note_id required" }, 400);
    const supa = createClient(SUPA_URL, SERVICE_KEY);
    const { data: n } = await supa.from("notes").select("views").eq("note_id", note_id).limit(1);
    if (n && n.length) {
      await supa.from("notes").update({ views: (Number(n[0].views) || 0) + 1 }).eq("note_id", note_id);
    }
    return J({ ok: true });
  } catch (e) {
    return J({ error: String((e as Error)?.message || e) }, 500);
  }
});
