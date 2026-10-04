// decide-withdrawal: admin marks a withdrawal sent (approved) or rejects it (refunds).
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: { "Content-Type": "application/json" } });
}

async function requireAdmin(req: Request) {
  const jwt = (req.headers.get("Authorization") || "").replace("Bearer ", "");
  if (!jwt) throw new Error("Missing auth token");
  const ucli = createClient(URL, ANON, { global: { headers: { Authorization: `Bearer ${jwt}` } } });
  const { data: { user }, error } = await ucli.auth.getUser();
  if (error || !user) throw new Error("Unauthorized");
  const svc = createClient(URL, SERVICE);
  const { data: row } = await svc.from("users").select("is_admin").eq("uid", user.id).single();
  if (!row || !row.is_admin) throw new Error("Admin only");
  return { svc };
}

serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  try {
    const { svc } = await requireAdmin(req);
    const { request_id, decision } = await req.json();
    if (!request_id || (decision !== "approved" && decision !== "rejected")) {
      return json({ error: "Bad request" }, 400);
    }
    const { data: w, error: we } = await svc.from("withdrawals").select("*").eq("request_id", request_id).single();
    if (we || !w) return json({ error: "Withdrawal not found" }, 404);
    if (w.status !== "pending") return json({ error: "Already decided" }, 400);

    if (decision === "approved") {
      await svc.from("withdrawals").update({ status: "approved" }).eq("request_id", request_id);
      return json({ ok: true });
    }
    // rejected → refund to seller wallet
    await svc.from("withdrawals").update({ status: "rejected" }).eq("request_id", request_id);
    const { data: urow } = await svc.from("users").select("wallet").eq("uid", w.seller_id).single();
    if (urow) {
      await svc.from("users").update({ wallet: (Number(urow.wallet) || 0) + Number(w.amount) }).eq("uid", w.seller_id);
    }
    return json({ ok: true, refunded: true });
  } catch (e) {
    return json({ error: (e as Error).message || "Failed" }, 500);
  }
});
