// cashmaal-webhook — receives CashMaal payment callbacks for deposits.
// Verifies the shared secret, then credits users.deposit_balance.
// Idempotent: a deposit is credited at most once.
//
// SETUP (user must do in CashMaal merchant dashboard):
//   1. Create merchant account, add website, get WEB ID.
//   2. Set this function's URL as the payment callback/webhook URL:
//      https://xsvkyiigcjibgkcytssr.supabase.co/functions/v1/cashmaal-webhook
//   3. Set Edge Function secrets: CASHMAAL_WEB_ID, CASHMAAL_WEB_SECRET.
//   4. When creating a payment, pass our deposit_id as the order/reference id
//      so this webhook can match it. Adjust the field parsing below to match
//      CashMaal's actual callback format from their API docs.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPA_URL = "https://xsvkyiigcjibgkcytssr.supabase.co";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const WEB_SECRET = Deno.env.get("CASHMAAL_WEB_SECRET") || "";

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
    const ct = req.headers.get("content-type") || "";
    try {
      if (ct.includes("application/x-www-form-urlencoded")) {
        const t = await req.text();
        for (const [k, v] of new URLSearchParams(t)) body[k] = v;
      } else {
        body = await req.json();
      }
    } catch { return J({ error: "bad body" }, 400); }

    // --- verify shared secret (adjust field name to CashMaal's docs) ---
    const secret = String(body.secret || body.web_secret || body.signature || "");
    if (!WEB_SECRET || secret !== WEB_SECRET) return J({ error: "bad signature" }, 403);

    // --- parse fields (adjust names to CashMaal's actual callback format) ---
    const depositId = Number(body.order_id || body.reference || body.deposit_id);
    const amount = Number(body.amount);
    const txnId = String(body.txn_id || body.transaction_id || "");
    const statusOk = ["success", "completed", "paid", "1", "true"].includes(String(body.status || "").toLowerCase());
    if (!depositId || !(amount > 0)) return J({ error: "bad fields" }, 400);
    if (!statusOk) {
      await supa.from("deposits").update({ status: "failed" }).eq("deposit_id", depositId).eq("status", "pending");
      return J({ ok: true, noted: "failed" });
    }

    const { data: d } = await supa.from("deposits").select("*").eq("deposit_id", depositId).single();
    if (!d) return J({ error: "deposit not found" }, 404);
    if ((d as { status: string }).status === "completed") return J({ ok: true, noted: "already credited" });
    if (Math.abs(Number((d as { amount: number }).amount) - amount) > 0.01)
      return J({ error: "amount mismatch" }, 400);

    // credit deposit balance (service_role bypasses the protect_balances trigger)
    const uid = (d as { user_id: string }).user_id;
    const { data: u } = await supa.from("users").select("deposit_balance").eq("uid", uid).single();
    const { error: uErr } = await supa.from("users").update({
      deposit_balance: (Number((u as { deposit_balance?: number })?.deposit_balance) || 0) + amount,
    }).eq("uid", uid);
    if (uErr) return J({ error: uErr.message }, 500);

    await supa.from("deposits").update({
      status: "completed", cashmaal_txn_id: txnId, completed_at: Date.now(),
    }).eq("deposit_id", depositId);

    return J({ ok: true, credited: amount });
  } catch (e) {
    return J({ error: String((e as Error)?.message || e) }, 500);
  }
});
