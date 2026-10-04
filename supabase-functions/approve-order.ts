// approve-order — admin approves/rejects a note purchase.
// Money split (70% seller / 30% admin) happens HERE server-side.
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

async function adminUid(req: Request, body: Record<string, unknown>, supa: ReturnType<typeof createClient>) {
  if (WA_SECRET && body.admin_secret === WA_SECRET) {
    const { data } = await supa.from("users").select("uid").eq("is_admin", true).limit(1).single();
    return (data?.uid as string) ?? null;
  }
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!jwt) return null;
  const { data: { user } } = await supa.auth.getUser(jwt);
  if (!user) return null;
  const { data: row } = await supa.from("users").select("is_admin").eq("uid", user.id).single();
  return row?.is_admin ? user.id : null;
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const supa = createClient(SUPA_URL, SERVICE_KEY);
    let body: Record<string, unknown> = {};
    try { body = await req.json(); } catch { return J({ error: "bad json" }, 400); }
    const auid = await adminUid(req, body, supa);
    if (!auid) return J({ error: "forbidden" }, 403);

    const { order_id, action } = body as { order_id: string; action: string };
    const { data: o } = await supa.from("orders").select("*").eq("order_id", order_id).single();
    if (!o) return J({ error: "order not found" }, 404);
    if (o.status !== "pending") return J({ error: "already " + o.status }, 400);

    if (action === "reject") {
      await supa.from("orders").update({ status: "rejected" }).eq("order_id", order_id);
      return J({ ok: true, status: "rejected" });
    }

    const amount = Number(o.amount) || 0;
    const commission = Math.round(amount * 0.30);
    const earning = amount - commission;

    const { error: oErr } = await supa.from("orders")
      .update({ status: "approved", commission, seller_earning: earning }).eq("order_id", order_id);
    if (oErr) return J({ error: oErr.message }, 500);

    const { data: s } = await supa.from("users").select("wallet,total_earnings").eq("uid", o.seller_id).single();
    if (s) await supa.from("users").update({
      wallet: (Number(s.wallet) || 0) + earning,
      total_earnings: (Number(s.total_earnings) || 0) + earning,
    }).eq("uid", o.seller_id);

    const { data: a } = await supa.from("users").select("wallet,total_earnings").eq("uid", auid).single();
    if (a) await supa.from("users").update({
      wallet: (Number(a.wallet) || 0) + commission,
      total_earnings: (Number(a.total_earnings) || 0) + commission,
    }).eq("uid", auid);

    const { data: n } = await supa.from("notes").select("downloads").eq("note_id", o.note_id).single();
    if (n) await supa.from("notes").update({ downloads: (Number(n.downloads) || 0) + 1 }).eq("note_id", o.note_id);

    return J({ ok: true, status: "approved", commission, earning });
  } catch (e) {
    return J({ error: String((e as Error)?.message || e) }, 500);
  }
});
