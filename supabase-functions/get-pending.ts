// get-pending — returns pending orders/withdrawals/notes for the WhatsApp admin hook.
// Auth: WA_ADMIN_SECRET only (no user JWT path).
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

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const supa = createClient(SUPA_URL, SERVICE_KEY);
    let body: Record<string, unknown> = {};
    try { body = await req.json(); } catch { /* fall through to 403 */ }
    if (!WA_SECRET || body.admin_secret !== WA_SECRET) return J({ error: "forbidden" }, 403);

    const [orders, withdrawals, notes] = await Promise.all([
      supa.from("orders").select("order_id,buyer_id,seller_id,note_id,amount,payment_proof_url,timestamp")
        .eq("status", "pending").order("timestamp", { ascending: false }).limit(20),
      supa.from("withdrawals").select("request_id,seller_id,seller_name,amount,easypaisa_number,timestamp")
        .eq("status", "pending").order("timestamp", { ascending: false }).limit(20),
      supa.from("notes").select("note_id,seller_id,seller_name,title,subject,price,file_url,created_at")
        .eq("status", "pending").order("created_at", { ascending: false }).limit(20),
    ]);
    return J({
      orders: orders.data || [],
      withdrawals: withdrawals.data || [],
      notes: notes.data || [],
    });
  } catch (e) {
    return J({ error: String((e as Error)?.message || e) }, 500);
  }
});
