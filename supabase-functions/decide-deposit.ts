// decide-deposit — admin approves (credits deposit_balance) or rejects a manual deposit.
// Auth: admin user JWT, or WA_ADMIN_SECRET (WhatsApp admin script).
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPA_URL = "https://xsvkyiigcjibgkcytssr.supabase.co";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const WA_SECRET=<redacted>

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
  return !!(row as { is_admin?: boolean })?.is_admin;
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const supa = createClient(SUPA_URL, SERVICE_KEY);
    let body: Record<string, unknown> = {};
    try { body = await req.json(); } catch { return J({ error: "bad json" }, 400); }
    if (!(await isAdmin(req, body, supa))) return J({ error: "forbidden" }, 403);

    const deposit_id = Number((body as { deposit_id?: number }).deposit_id);
    const action = String((body as { action?: string }).action || "").toLowerCase();
    if (!deposit_id || (action !== "approve" && action !== "reject"))
      return J({ error: "deposit_id + action (approve/reject) required" }, 400);

    const { data: d } = await supa.from("deposits").select("*").eq("deposit_id", deposit_id).single();
    const dep = d as { deposit_id: number; user_id: string; amount: number; status: string; method: string } | null;
    if (!dep) return J({ error: "not found" }, 404);
    if (dep.status !== "pending") return J({ error: "already " + dep.status }, 400);

    if (action === "approve") {
      // credit deposit balance (service_role bypasses protect_balances trigger)
      const { data: u } = await supa.from("users").select("deposit_balance").eq("uid", dep.user_id).single();
      const cur = Number((u as { deposit_balance?: number })?.deposit_balance) || 0;
      const { error: uErr } = await supa.from("users")
        .update({ deposit_balance: cur + Number(dep.amount) })
        .eq("uid", dep.user_id);
      if (uErr) return J({ error: uErr.message }, 500);
      await supa.from("deposits").update({ status: "completed", completed_at: Date.now() }).eq("deposit_id", deposit_id);
      return J({ ok: true, status: "completed", credited: Number(dep.amount) });
    } else {
      await supa.from("deposits").update({ status: "rejected" }).eq("deposit_id", deposit_id);
      return J({ ok: true, status: "rejected" });
    }
  } catch (e) {
    return J({ error: String((e as Error)?.message || e) }, 500);
  }
});
