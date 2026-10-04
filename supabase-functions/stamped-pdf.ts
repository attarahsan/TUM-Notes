// stamped-pdf — returns the note's PDF with the buyer's name + email watermarked on every page.
// Auth: user JWT in Authorization header.
// Allowed: buyer with an APPROVED order, the seller, or an admin. Free (Rs 0) notes: any logged-in user.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { PDFDocument, rgb, degrees, StandardFonts } from "https://esm.sh/pdf-lib@1.17.1";

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
    const body = await req.json();
    const note_id = Number(body.note_id);
    if (!note_id) return J({ error: "note_id required" }, 400);

    const jwt = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
    if (!jwt) return J({ error: "login required" }, 401);

    const supa = createClient(SUPA_URL, SERVICE_KEY);
    const { data: { user } } = await supa.auth.getUser(jwt);
    if (!user) return J({ error: "invalid session" }, 401);

    const { data: notes } = await supa.from("notes")
      .select("note_id,file_url,seller_id,status,price,note_type")
      .eq("note_id", note_id).limit(1);
    const note = notes && notes[0];
    if (!note || note.status !== "approved" || !note.file_url) return J({ error: "note not found" }, 404);
    if (note.note_type === "images") return J({ error: "yeh photo-gallery note hye — PDF download nahi" }, 400);

    const { data: me } = await supa.from("users").select("uid,name,is_admin").eq("uid", user.id).limit(1);
    const meRow = me && me[0];
    const isAdmin = !!(meRow && meRow.is_admin);
    const isSeller = note.seller_id === user.id;
    const isFree = Number(note.price) === 0;
    let allowed = isAdmin || isSeller || isFree;
    if (!allowed) {
      const { data: orders } = await supa.from("orders").select("order_id")
        .eq("note_id", note_id).eq("buyer_id", user.id).eq("status", "approved").limit(1);
      allowed = !!(orders && orders.length);
    }
    if (!allowed) return J({ error: "aap ne yeh note unlock nahi kiya" }, 403);

    const pdfRes = await fetch(note.file_url);
    if (!pdfRes.ok) return J({ error: "file download nahi ho saki" }, 502);
    const pdfBytes = await pdfRes.arrayBuffer();

    let pdf;
    try { pdf = await PDFDocument.load(pdfBytes); }
    catch { return J({ error: "yeh valid PDF file nahi hye" }, 400); }

    const font = await pdf.embedFont(StandardFonts.HelveticaBold);
    const buyerName = (meRow && meRow.name) || user.user_metadata?.full_name || "TUM Buyer";
    const stamp = `${buyerName} · ${user.email || ""}`;
    const brand = "TUM Notes Hub — licensed copy";

    for (const page of pdf.getPages()) {
      const { width, height } = page.getSize();
      // diagonal watermark across the middle
      page.drawText(stamp, {
        x: width / 2 - font.widthOfTextAtSize(stamp, 15) / 2,
        y: height / 2,
        size: 15, font, color: rgb(0.72, 0.12, 0.12), opacity: 0.38,
        rotate: degrees(45),
      });
      // footer line
      const foot = `${stamp} · ${brand}`;
      page.drawText(foot, {
        x: 24, y: 18, size: 8.5, font, color: rgb(0.45, 0.45, 0.5), opacity: 0.85,
      });
    }

    const out = await pdf.save();
    return new Response(out, {
      status: 200,
      headers: {
        ...cors,
        "Content-Type": "application/pdf",
        "Content-Disposition": `attachment; filename="tum-note-${note_id}.pdf"`,
      },
    });
  } catch (e) {
    return J({ error: String((e as Error)?.message || e) }, 500);
  }
});
