// sweep-plans — tamam users ke expired plans deactivate karta hye (hourly cron se chalta hye).
// Har subscription apni activation date se 30 din chalti hye; 30 din ke baad foran
// deactivate. Agar user ka doosra plan abhi active hye to woh apni date tak chalta rahega.
// Auth: admin user JWT, or WA_ADMIN_SECRET (server-side cron).
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPA_URL = "https://xsvkyiigcjibgkcytssr.supabase.co";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const WA_SECRET = Deno.env.get("WA_ADMIN_SECRET") || "";
const LIMITS: Record<string, number> = { pro: 300, business: 1000000 };
const PLAN_RANK: Record<string, number> = { pro: 1, business: 2 };

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const J = (o: unknown, s = 200) =>
  new Response(JSON.stringify(o), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

async function isAdmin(req: Request, body: Record<string, unknown>, supa: ReturnType<typeof createClient>) {
if (WA_SECRET && body.admin_secret === WA_SECRET) {
    return true;
  }
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!jwt) return false;
  const { data: { user } } = await supa.auth.getUser(jwt);
  if (!user) return false;
  const { data: row } = await supa.from("users").select("is_admin").eq("uid", user.id).single();
  return !!row?.is_admin;
}

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
    let body: Record<string, unknown> = {};
    try { body = await req.json(); } catch { /* allow empty body for JWT admins */ }
    if (!(await isAdmin(req, body, supa))) return J({ error: "forbidden" }, 403);

    const { data: users } = await supa.from("users")
      .select("uid,plan,note_limit,plan_expires").neq("plan", "free");
    let changed = 0;
    for (const u of (users as any[]) || []) {
      const eff = await effectivePlan(supa, u.uid);
      if (eff.plan !== u.plan || Number(eff.expires_at) !== Number(u.plan_expires || 0)) {
        await supa.from("users")
          .update({ plan: eff.plan, note_limit: eff.note_limit, plan_expires: eff.expires_at })
          .eq("uid", u.uid);
        changed++;
      }
    }
    return J({ ok: true, checked: (users as any[] || []).length, changed });
  } catch (e) {
    return J({ error: String((e as Error)?.message || e) }, 500);
  }
});
