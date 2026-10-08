// create-deposit — buyer starts a CashMaal deposit.
// Creates a pending deposit record and returns the CashMaal payment URL.
// Auth: buyer user JWT.
//
// NOTE: The CashMaal payment URL construction needs the merchant WEB ID and
// their API docs (available after the user creates a merchant account).
// Until then, this returns the deposit_id so the user can pay manually
// referencing it; the cashmaal-webhook credits on callback.
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

    const { data: dep, error: dErr } = await supa.from("deposits").insert({
      user_id: user.id, amount, status: "pending",
    }).select("deposit_id").single();
    if (dErr) return J({ error: dErr.message }, 500);
    const depositId = (dep as { deposit_id: number }).deposit_id;

    // TODO: build real CashMaal payment URL once WEB ID + API docs are available.
    // Expected shape (to confirm from docs):
    //   https://www.cashmaal.com/pay?web_id=WEB_ID&amount=AMOUNT&order_id=DEPOSIT_ID&callback=...
    let payment_url: string | null = null;
    if (CASHMAAL_WEB_ID) {
      payment_url = "https://www.cashmaal.com/pay?web_id=" + encodeURIComponent(CASHMAAL_WEB_ID) +
        "&amount=" + amount + "&order_id=" + depositId +
        "&callback=" + encodeURIComponent(APP_URL + "/#wallet");
    }

    return J({ ok: true, deposit_id: depositId, amount, payment_url,
      manual: !payment_url ? "CashMaal abhi connect nahi — deposit_id note kar lein" : null });
  } catch (e) {
    return J({ error: String((e as Error)?.message || e) }, 500);
  }
});
