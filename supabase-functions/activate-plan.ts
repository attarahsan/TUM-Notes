// activate-plan — admin approves/rejects a plan subscription.
// Plan fields are set HERE server-side — users can never set their own plan.
// Auth: admin user JWT, or WA_ADMIN_SECRET (WhatsApp admin script).
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPA_URL = "https://xsvkyiigcjibgkcytssr.supabase.co";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const WA_SECRET = Deno.env.get("WA_ADMIN_SECRET") || "";
const LIMITS: Record<string, number> = { pro: 300, business: -1 };

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

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const supa = createClient(SUPA_URL, SERVICE_KEY);
    let body: Record<string, unknown> = {};
    try { body = await req.json(); } catch { return J({ error: "bad json" }, 400); }
    if (!(await isAdmin(req, body, supa))) return J({ error: "forbidden" }, 403);

    const { sub_id, action } = body as { sub_id: string | number; action: string };
    // NOTE: subscriptions PK column is `id` (integer)
    const { data: sub } = await supa.from("subscriptions").select("*").eq("id", sub_id).single();
    if (!sub) return J({ error: "not found" }, 404);
    if (sub.status !== "pending") return J({ error: "already " + sub.status }, 400);

    if (action === "reject") {
      await supa.from("subscriptions").update({ status: "rejected" }).eq("id", sub_id);
      return J({ ok: true, status: "rejected" });
    }

    const lim = LIMITS[sub.plan] ?? 25;
    const exp = Date.now() + 30 * 86400000;
    const { error: sErr } = await supa.from("subscriptions").update({ status: "approved" }).eq("id", sub_id);
    if (sErr) return J({ error: sErr.message }, 500);
    const { error: uErr } = await supa.from("users")
      .update({ plan: sub.plan, note_limit: lim, plan_expires: exp }).eq("uid", sub.seller_id);
    if (uErr) return J({ error: uErr.message }, 500);
    return J({ ok: true, status: "approved", plan: sub.plan });
  } catch (e) {
    return J({ error: String((e as Error)?.message || e) }, 500);
  }
});
