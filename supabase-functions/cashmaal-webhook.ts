// cashmaal-webhook — receives CashMaal IPN callbacks for deposits.
// Verifies web_id + ipn_key, then credits users.deposit_balance.
// Idempotent: a deposit is credited at most once.
//
// Real IPN fields (from cashmaal.com/en/verify_transaction_ipn.txt):
//   status: "1"=success | "2"=pending | "3"=rejected | "0"=cancelled
//   web_id, CM_TID, Amount, currency, fee, client_email, order_id, date_time, addi_info, ipn_key
//
// SETUP (merchant dashboard):
//   1. Create merchant account at cashmaal.com, add website → get WEB ID + IPN Key.
//   2. Set IPN URL to: https://xsvkyiigcjibgkcytssr.supabase.co/functions/v1/cashmaal-webhook
//   3. Set Edge Function secrets: CASHMAAL_WEB_ID, CASHMAAL_IPN_KEY.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPA_URL = "https://xsvkyiigcjibgkcytssr.supabase.co";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const WEB_ID = Deno.env.get("CASHMAAL_WEB_ID") || "";
const IPN_KEY = Deno.env.get("CASHMAAL_IPN_KEY") || "";

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

    // --- verify: web_id + ipn_key must match our merchant credentials ---
    const webId = String(body.web_id || "");
    const ipnKey = String(body.ipn_key || "");
    if (!WEB_ID || !IPN_KEY) return J({ error: "cashmaal not configured" }, 500);
    if (webId !== WEB_ID || ipnKey !== IPN_KEY) return J({ error: "bad signature" }, 403);

    // --- parse real IPN fields ---
    const status = String(body.status || "");
    // order_id is "{depositId}-{timestamp}" — extract the deposit id prefix
    const depositId = Number(String(body.order_id || "").split("-")[0]);
    const amount = Number(body.Amount);
    const txnId = String(body.CM_TID || "");
    const currency = String(body.currency || "").toUpperCase();
    if (!depositId || !(amount > 0)) return J({ error: "bad fields" }, 400);
    if (currency && currency !== "PKR") return J({ error: "currency must be PKR" }, 400);

    if (status === "2") return J({ ok: true, noted: "pending" }); // still pending at CashMaal
    if (status === "3" || status === "0") {
      await supa.from("deposits").update({ status: "failed" }).eq("deposit_id", depositId).eq("status", "pending");
      return J({ ok: true, noted: "failed" });
    }
    if (status !== "1") return J({ error: "unknown status" }, 400);

    const { data: d } = await supa.from("deposits").select("*").eq("deposit_id", depositId).single();
    const dep = d as { deposit_id: number; user_id: string; amount: number; status: string; method: string } | null;
    if (!dep) return J({ error: "deposit not found" }, 404);
    if (dep.status === "completed") return J({ ok: true, noted: "already credited" });
    if (dep.method !== "cashmaal") return J({ error: "not a cashmaal deposit" }, 400);
    if (Math.abs(Number(dep.amount) - amount) > 0.01) return J({ error: "amount mismatch" }, 400);

    // credit deposit balance (service_role bypasses the protect_balances trigger)
    const { data: u } = await supa.from("users").select("deposit_balance").eq("uid", dep.user_id).single();
    const cur = Number((u as { deposit_balance?: number })?.deposit_balance) || 0;
    const { error: uErr } = await supa.from("users")
      .update({ deposit_balance: cur + amount })
      .eq("uid", dep.user_id);
    if (uErr) return J({ error: uErr.message }, 500);

    await supa.from("deposits").update({
      status: "completed", cashmaal_txn_id: txnId, completed_at: Date.now(),
    }).eq("deposit_id", depositId);

    return J({ ok: true, credited: amount });
  } catch (e) {
    return J({ error: String((e as Error)?.message || e) }, 500);
  }
});
