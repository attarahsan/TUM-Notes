// request-withdrawal: user requests a withdrawal.
// Password check, balance check and wallet debit happen HERE server-side.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const MIN_WITHDRAWAL = 500;

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: { "Content-Type": "application/json" } });
}

async function sha256hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  try {
    const jwt = (req.headers.get("Authorization") || "").replace("Bearer ", "");
    if (!jwt) throw new Error("Missing auth token");
    const ucli = createClient(URL, ANON, { global: { headers: { Authorization: `Bearer ${jwt}` } } });
    const { data: { user }, error: ue } = await ucli.auth.getUser();
    if (ue || !user) throw new Error("Unauthorized");
    const uid = user.id;
    const svc = createClient(URL, SERVICE);

    const { amount, easypaisa_number, password } = await req.json();
    const amt = Math.floor(Number(amount));
    if (!amt || amt < MIN_WITHDRAWAL) return json({ error: `Minimum withdrawal is Rs ${MIN_WITHDRAWAL}.` }, 400);
    if (!easypaisa_number || !password) return json({ error: "Missing fields." }, 400);

    const { data: urow } = await svc.from("users").select("wallet,withdraw_pass_hash,name").eq("uid", uid).single();
    if (!urow) return json({ error: "Account nahi mila" }, 404);
    if (!urow.withdraw_pass_hash) return json({ error: "Withdrawal password set nahi hye." }, 400);
    const hash = await sha256hex("tum-withdraw::" + password);
    if (hash !== urow.withdraw_pass_hash) return json({ error: "❌ Ghalat withdrawal password." }, 403);

    const bal = Number(urow.wallet) || 0;
    if (amt > bal) return json({ error: `Insufficient balance. Available: Rs ${bal.toLocaleString()}` }, 400);

    await svc.from("users").update({ wallet: bal - amt, easypaisa_number }).eq("uid", uid);
    const { error: ie } = await svc.from("withdrawals").insert({
      seller_id: uid,
      seller_name: urow.name,
      amount: amt,
      easypaisa_number,
      status: "pending",
      timestamp: Date.now(),
    });
    if (ie) throw ie;
    return json({ ok: true });
  } catch (e) {
    return json({ error: (e as Error).message || "Failed" }, 500);
  }
});
