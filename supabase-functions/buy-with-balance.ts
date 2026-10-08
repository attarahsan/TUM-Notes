// buy-with-balance — buyer purchases a note INSTANTLY using deposited balance.
// Only deposit_balance can buy notes. Earned wallet money can NOT buy (withdraw-only).
// Auth: buyer user JWT.
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
    const supa = createClient(SUPA_URL, SERVICE_KEY);
    let body: Record<string, unknown> = {};
    try { body = await req.json(); } catch { return J({ error: "bad json" }, 400); }

    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    if (!jwt) return J({ error: "login required" }, 401);
    const { data: { user } } = await supa.auth.getUser(jwt);
    if (!user) return J({ error: "login required" }, 401);
    const buyerId = user.id;

    const { note_id } = body as { note_id: string | number };
    const { data: n } = await supa.from("notes")
      .select("note_id,seller_id,price,status,title").eq("note_id", note_id).single();
    if (!n) return J({ error: "note not found" }, 404);
    if (n.status !== "approved") return J({ error: "note not available" }, 400);
    if (n.seller_id === buyerId) return J({ error: "ye aapka apna note hai" }, 400);

    // already bought?
    const { data: owned } = await supa.from("orders").select("order_id")
      .eq("note_id", note_id).eq("buyer_id", buyerId).eq("status", "approved").limit(1);
    if (owned && owned.length) return J({ error: "already purchased", owned: true }, 400);

    const price = Number(n.price) || 0;
    if (price <= 0) return J({ error: "invalid price" }, 400);

    const { data: b } = await supa.from("users")
      .select("deposit_balance").eq("uid", buyerId).single();
    const depBal = Number((b as { deposit_balance?: number })?.deposit_balance) || 0;
    if (depBal < price) return J({ error: "insufficient deposit balance", need: price, have: depBal }, 400);

    // commission by seller's effective plan (same as approve-order)
    const PLAN_RANK: Record<string, number> = { free: 0, pro: 1, business: 2 };
    const { data: subs } = await supa.from("subscriptions")
      .select("plan,expires_at").eq("seller_id", n.seller_id).eq("status", "approved")
      .gt("expires_at", Date.now());
    let splan = "free";
    for (const s2 of (subs as { plan: string }[]) || [])
      if ((PLAN_RANK[s2.plan] || 0) > (PLAN_RANK[splan] || 0)) splan = s2.plan;
    const RATES: Record<string, number> = { business: 0.15, pro: 0.23 };
    const rate = RATES[splan] ?? 0.30;
    const commission = Math.round(price * rate);
    const earning = price - commission;

    // referral cut from admin's share (same as approve-order)
    let referrerUid: string | null = null;
    let referrerCut = 0;
    try {
      const { data: srow } = await supa.from("users").select("referred_by").eq("uid", n.seller_id).single();
      const refCode = (srow as { referred_by?: string })?.referred_by;
      if (refCode) {
        const { data: ref } = await supa.from("users").select("uid").eq("referral_code", refCode).limit(1).single();
        if ((ref as { uid?: string })?.uid && (ref as { uid?: string }).uid !== n.seller_id) {
          referrerUid = (ref as { uid: string }).uid;
          const { count: prevSales } = await supa.from("orders")
            .select("order_id", { count: "exact", head: true })
            .eq("referrer_uid", referrerUid).eq("seller_id", n.seller_id).eq("status", "approved");
          referrerCut = Math.round(price * ((prevSales || 0) >= 20 ? 0.05 : 0.10));
        }
      }
    } catch { /* no referrer */ }
    const adminCut = commission - referrerCut;

    // 1. deduct buyer's deposit balance
    const { error: dErr } = await supa.from("users").update({
      deposit_balance: depBal - price,
    }).eq("uid", buyerId);
    if (dErr) return J({ error: dErr.message }, 500);

    // 2. create approved order (instant — prepaid, no admin approval needed)
    const { data: ord, error: oErr } = await supa.from("orders").insert({
      buyer_id: buyerId, seller_id: n.seller_id, note_id: n.note_id,
      amount: price, commission: adminCut, seller_earning: earning,
      referrer_uid: referrerUid, referrer_cut: referrerCut,
      status: "approved", payment_method: "deposit_balance", timestamp: Date.now(),
    }).select("order_id").single();
    if (oErr) {
      // rollback buyer deduction
      await supa.from("users").update({ deposit_balance: depBal }).eq("uid", buyerId);
      return J({ error: oErr.message }, 500);
    }

    // 3. credit seller earnings -> wallet (withdraw-only, can NOT buy notes)
    const { data: s } = await supa.from("users").select("wallet,total_earnings").eq("uid", n.seller_id).single();
    if (s) await supa.from("users").update({
      wallet: (Number((s as { wallet?: number }).wallet) || 0) + earning,
      total_earnings: (Number((s as { total_earnings?: number }).total_earnings) || 0) + earning,
    }).eq("uid", n.seller_id);

    // 4. referrer + admin cuts -> wallet
    if (referrerUid && referrerCut > 0) {
      const { data: ru } = await supa.from("users").select("wallet,total_earnings").eq("uid", referrerUid).single();
      if (ru) await supa.from("users").update({
        wallet: (Number((ru as { wallet?: number }).wallet) || 0) + referrerCut,
        total_earnings: (Number((ru as { total_earnings?: number }).total_earnings) || 0) + referrerCut,
      }).eq("uid", referrerUid);
    }
    const { data: adm } = await supa.from("users").select("uid,wallet").eq("is_admin", true).limit(1).single();
    if (adm && adminCut > 0) {
      await supa.from("users").update({
        wallet: (Number((adm as { wallet?: number }).wallet) || 0) + adminCut,
      }).eq("uid", (adm as { uid: string }).uid);
    }

    return J({ ok: true, order_id: (ord as { order_id: number }).order_id, price });
  } catch (e) {
    return J({ error: String((e as Error)?.message || e) }, 500);
  }
});
