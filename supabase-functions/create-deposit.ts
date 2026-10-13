// create-deposit — buyer starts a deposit (CashMaal instant OR manual Easypaisa+screenshot).
// method=cashmaal: creates pending deposit, returns CashMaal payment URL (needs CASHMAAL_WEB_ID).
// method=manual: creates pending deposit with payment proof screenshot; admin approves via decide-deposit.
// Auth: buyer user JWT.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPA_URL = "https://xsvkyiigcjibgkcytssr.supabase.co";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CASHMAAL_WEB_ID = Deno.env.get("CASHMAAL_WEB_ID") || "";
const APP_URL = "https://tumpronote.netlify.app";

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

    const amount = Math.round(Number(body.amount) || 0);
    if (!(amount >= 50)) return J({ error: "minimum deposit Rs 50" }, 400);
    if (amount > 100000) return J({ error: "maximum deposit Rs 100,000" }, 400);

    const method = String(body.method || "cashmaal");
    if (method !== "cashmaal" && method !== "manual") return J({ error: "bad method" }, 400);

    const { data: me } = await supa.from("users").select("name,email").eq("uid", user.id).single();
    const meRow = (me as { name?: string; email?: string }) || {};

    if (method === "manual") {
      const proof_url = String(body.proof_url || "");
      if (!proof_url) return J({ error: "payment screenshot zaroori hai" }, 400);
      const { data: dep, error: dErr } = await supa.from("deposits").insert({
        user_id: user.id, amount, status: "pending", method: "manual",
        payment_proof_url: proof_url,
        user_name: meRow.name || "", user_email: meRow.email || user.email || "",
      }).select("deposit_id").single();
      if (dErr) return J({ error: dErr.message }, 500);
      return J({ ok: true, deposit_id: (dep as { deposit_id: number }).deposit_id, amount, method: "manual",
        note: "Screenshot mil gaya — admin verify karke deposit balance me add karega." });
    }

    // cashmaal
    const { data: dep, error: dErr } = await supa.from("deposits").insert({
      user_id: user.id, amount, status: "pending", method: "cashmaal",
      user_name: meRow.name || "", user_email: meRow.email || user.email || "",
    }).select("deposit_id").single();
    if (dErr) return J({ error: dErr.message }, 500);
    const depositId = (dep as { deposit_id: number }).deposit_id;

    // CashMaal hosted payment page. Confirm exact params from merchant API docs
    // once the merchant account is created; fields below follow the IPN doc's
    // naming (web_id, order_id, Amount).
    let payment_url: string | null = null;
    let payment_form: Record<string, string> | null = null;
    if (CASHMAAL_WEB_ID) {
      payment_form = {
        web_id: CASHMAAL_WEB_ID,
        order_id: String(depositId),
        Amount: String(amount),
        currency: "PKR",
        client_email: user.email || "",
        addi_info: "TUM Notes deposit #" + depositId,
        callback_url: APP_URL + "/#wallet",
      };
      payment_url = "https://www.cashmaal.com/pay";
    }

    return J({ ok: true, deposit_id: depositId, amount, method: "cashmaal",
      payment_url, payment_form,
      manual: !payment_url ? "CashMaal abhi connect nahi — manual method istemal karein" : null });
  } catch (e) {
    return J({ error: String((e as Error)?.message || e) }, 500);
  }
});
