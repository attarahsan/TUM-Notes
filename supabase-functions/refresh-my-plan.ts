// refresh-my-plan — logged-in user apna effective plan dobara calculate karwata hye.
// Har subscription apni activation date se 30 din chalti hye; expired plans foran
// deactivate ho jate hain, lekin doosre active plans apni date tak chalte rehte hain.
// Auth: user JWT only.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPA_URL = "https://xsvkyiigcjibgkcytssr.supabase.co";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const LIMITS: Record<string, number> = { pro: 300, business: 1000000 };
const PLAN_RANK: Record<string, number> = { pro: 1, business: 2 };

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const J = (o: unknown, s = 200) =>
  new Response(JSON.stringify(o), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

async function effectivePlan(supa: ReturnType<typeof createClient>, seller_id: string) {
  const now = Date.now();
  const { data: subs } = await supa.from("subscriptions")
    .select("plan,expires_at").eq("seller_id", seller_id).eq("status", "approved").gt("expires_at", now);
  let best: string | null = null;
  for (const s of (subs as any[]) || []) {
    if ((PLAN_RANK[s.plan] || 0) > (PLAN_RANK[best || ""] || 0)) best = s.plan;
  }
  if (!best) return { plan: "free", note_limit: 25, expires_at: 0 };
  let exp = 0;
  for (const s of (subs as any[]) || []) {
    if (s.plan === best) exp = Math.max(exp, Number(s.expires_at) || 0);
  }
  return { plan: best, note_limit: LIMITS[best] ?? 25, expires_at: exp };
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const supa = createClient(SUPA_URL, SERVICE_KEY);
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    if (!jwt) return J({ error: "missing auth" }, 401);
    const { data: { user } } = await supa.auth.getUser(jwt);
    if (!user) return J({ error: "bad token" }, 401);

    const eff = await effectivePlan(supa, user.id);
    await supa.from("users")
      .update({ plan: eff.plan, note_limit: eff.note_limit, plan_expires: eff.expires_at })
      .eq("uid", user.id);
    return J({ ok: true, plan: eff.plan, note_limit: eff.note_limit, plan_expires: eff.expires_at });
  } catch (e) {
    return J({ error: String((e as Error)?.message || e) }, 500);
  }
});
