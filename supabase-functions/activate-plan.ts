// activate-plan: admin approves/rejects a plan subscription.
// Plan fields are set HERE server-side — users can never set their own plan.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const PLAN_NOTES: Record<string, number> = { pro: 300, business: 1000000 };

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
    const { id, decision } = await req.json();
    if (!id || (decision !== "approved" && decision !== "rejected")) {
      return json({ error: "Bad request" }, 400);
    }
    const { data: sub, error: se } = await svc.from("subscriptions").select("*").eq("id", id).single();
    if (se || !sub) return json({ error: "Subscription not found" }, 404);
    if (sub.status !== "pending") return json({ error: "Already decided" }, 400);

    await svc.from("subscriptions").update({ status: decision }).eq("id", id);
    if (decision === "approved") {
      const notes = PLAN_NOTES[sub.plan] ?? 25;
      await svc.from("users").update({
        plan: sub.plan,
        note_limit: notes,
        plan_expires: Date.now() + 30 * 864e5,
      }).eq("uid", sub.seller_id);
      return json({ ok: true, plan: sub.plan, note_limit: notes });
    }
    return json({ ok: true });
  } catch (e) {
    return json({ error: (e as Error).message || "Failed" }, 500);
  }
});
