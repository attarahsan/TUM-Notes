// approve-order: admin approves/rejects a note purchase.
// Money split (70% seller / 30% admin) happens HERE server-side — never trust client math.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const ADMIN_COMMISSION = 0.3;

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: { "Content-Type": "application/json" } });
}

async function requireAdmin(req: Request) {
  const jwt = (req.headers.get("Authorization") || "").replace("Bearer ", "");
  if (!jwt) throw new Error("Missing auth token");
  const ucli = createClient(URL, ANON, { global: { headers: { Authorization: `Bearer ${jwt}` } } });
  const { data: { user }, error } = await ucli.auth.getUser();
  if (error || !user) throw new Error("Unauthorized");
  const svc = createClient(URL, SERVICE);
  const { data: row } = await svc.from("users").select("is_admin").eq("uid", user.id).single();
  if (!row || !row.is_admin) throw new Error("Admin only");
  return { svc, adminUid: user.id };
}

serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  try {
    const { svc, adminUid } = await requireAdmin(req);
    const { order_id, decision } = await req.json();
    if (!order_id || (decision !== "approved" && decision !== "rejected")) {
      return json({ error: "Bad request" }, 400);
    }
    const { data: o, error: oe } = await svc.from("orders").select("*").eq("order_id", order_id).single();
    if (oe || !o) return json({ error: "Order not found" }, 404);
    if (o.status !== "pending") return json({ error: "Order already decided" }, 400);

    if (decision === "rejected") {
      await svc.from("orders").update({ status: "rejected" }).eq("order_id", order_id);
      return json({ ok: true });
    }

    // APPROVED — recompute amounts from the NOTE price (never trust the client-sent amount)
    const { data: note } = await svc.from("notes").select("price").eq("note_id", o.note_id).single();
    const amount = Math.floor(Number(note?.price ?? o.amount) || 0);
    const commission = Math.round(amount * ADMIN_COMMISSION);
    const earning = amount - commission;

    await svc.from("orders").update(
      { status: "approved", amount, commission, seller_earning: earning },
    ).eq("order_id", order_id);

    // credit seller (70%)
    const { data: srow } = await svc.from("users").select("wallet,total_earnings").eq("uid", o.seller_id).single();
    if (srow) {
      await svc.from("users").update({
        wallet: (Number(srow.wallet) || 0) + earning,
        total_earnings: (Number(srow.total_earnings) || 0) + earning,
      }).eq("uid", o.seller_id);
    }
    // credit approving admin (30% commission)
    const { data: arow } = await svc.from("users").select("wallet,total_earnings").eq("uid", adminUid).single();
    if (arow) {
      await svc.from("users").update({
        wallet: (Number(arow.wallet) || 0) + commission,
        total_earnings: (Number(arow.total_earnings) || 0) + commission,
      }).eq("uid", adminUid);
    }
    // bump download counter
    const { data: nrow } = await svc.from("notes").select("downloads").eq("note_id", o.note_id).single();
    if (nrow) {
      await svc.from("notes").update({ downloads: (Number(nrow.downloads) || 0) + 1 }).eq("note_id", o.note_id);
    }
    return json({ ok: true, earning, commission });
  } catch (e) {
    return json({ error: (e as Error).message || "Failed" }, 500);
  }
});
