// request-withdrawal — seller asks to withdraw from wallet (user JWT only)
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
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    if (!jwt) return J({ error: "missing auth" }, 401);
    const { data: { user } } = await supa.auth.getUser(jwt);
    if (!user) return J({ error: "bad token" }, 401);

    const { amount, easypaisa_number, withdraw_pass_hash } = await req.json();
    const amt = Math.floor(Number(amount) || 0);
    if (!(amt >= 500)) return J({ error: "Min withdrawal Rs 500" }, 400);
    if (!easypaisa_number || String(easypaisa_number).length < 10)
      return J({ error: "Easypaisa number ghalat hye" }, 400);

    const { data: u } = await supa.from("users").select("wallet,withdraw_pass_hash,name").eq("uid", user.id).single();
    if (!u) return J({ error: "user not found" }, 404);
    if (!u.withdraw_pass_hash) return J({ error: "set password first" }, 400);
    if (u.withdraw_pass_hash !== withdraw_pass_hash) return J({ error: "wrong password" }, 403);
    if ((Number(u.wallet) || 0) < amt) return J({ error: "Insufficient balance" }, 400);

    const newBal = (Number(u.wallet) || 0) - amt;
    const { error: wErr } = await supa.from("users").update({ wallet: newBal }).eq("uid", user.id);
    if (wErr) return J({ error: wErr.message }, 500);

    // request_id is an auto-increment integer — let the DB assign it; timestamp is bigint millis
    const { data: wd, error: iErr } = await supa.from("withdrawals").insert({
      seller_id: user.id, seller_name: u.name || "", amount: amt, easypaisa_number,
      status: "pending", timestamp: Date.now(),
    }).select("request_id").single();
    if (iErr) {
      // refund on insert failure (no partial debit)
      await supa.from("users").update({ wallet: Number(u.wallet) || 0 }).eq("uid", user.id);
      return J({ error: iErr.message }, 500);
    }
    return J({ ok: true, request_id: wd.request_id, new_balance: newBal });
  } catch (e) {
    return J({ error: String((e as Error)?.message || e) }, 500);
  }
});
