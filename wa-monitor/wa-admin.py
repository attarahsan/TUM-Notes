#!/usr/bin/env python3
"""TUM Notes Hub admin actions for WhatsApp approval flow.
Usage:
  wa-admin.py order approve <order_id> | order reject <order_id>
  wa-admin.py note approve <note_id>   | note reject <note_id>
  wa-admin.py withdrawal approve <request_id> | withdrawal reject <request_id>
  wa-admin.py pending   (list current pending items, for testing)

Mirrors the exact logic of the admin panel on the live site
(subtle-quokka-c95094.netlify.app, v5): 30% admin commission / 70% seller.
"""
import json, sys, urllib.request, urllib.parse

SUPABASE_URL = "https://xsvkyiigcjibgkcytssr.supabase.co"
KEY = "sb_publishable_srRWNgXit_vUS9V2CXk39g_yVolDTNe"
ADMIN_COMMISSION = 0.30
ADMIN_UID = "admin_1791088953"

HEADERS = {
    "apikey": KEY,
    "Authorization": f"Bearer {KEY}",
    "Content-Type": "application/json",
}

def req(method, path, body=None):
    url = SUPABASE_URL + path
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, data=data, headers=HEADERS, method=method)
    with urllib.request.urlopen(r, timeout=20) as resp:
        txt = resp.read().decode()
        return json.loads(txt) if txt else None

def get_one(table, eq_col, eq_val, select="*"):
    rows = req("GET", f"/rest/v1/{table}?{eq_col}=eq.{urllib.parse.quote(str(eq_val))}&select={select}&limit=1")
    return rows[0] if rows else None

def patch(table, eq_col, eq_val, updates):
    return req("PATCH", f"/rest/v1/{table}?{eq_col}=eq.{urllib.parse.quote(str(eq_val))}", updates)

def order_approve(order_id):
    o = get_one("orders", "order_id", order_id)
    if not o: return fail(f"Order {order_id} not found")
    if o.get("status") != "pending": return fail(f"Order {order_id} is already {o.get('status')}")
    amount = int(o.get("amount") or 0)
    commission = round(amount * ADMIN_COMMISSION)
    earning = amount - commission
    patch("orders", "order_id", order_id, {"status": "approved", "commission": commission, "seller_earning": earning})
    s = get_one("users", "uid", o["seller_id"], "wallet,total_earnings")
    if s:
        patch("users", "uid", o["seller_id"], {"wallet": int(s.get("wallet") or 0) + earning,
                                               "total_earnings": int(s.get("total_earnings") or 0) + earning})
    a = get_one("users", "uid", ADMIN_UID, "wallet,total_earnings")
    if a:
        patch("users", "uid", ADMIN_UID, {"wallet": int(a.get("wallet") or 0) + commission,
                                         "total_earnings": int(a.get("total_earnings") or 0) + commission})
    n = get_one("notes", "note_id", o["note_id"], "downloads")
    if n:
        patch("notes", "note_id", o["note_id"], {"downloads": int(n.get("downloads") or 0) + 1})
    return ok(f"Order {order_id} approved: seller +Rs {earning}, admin commission Rs {commission}")

def order_reject(order_id):
    o = get_one("orders", "order_id", order_id)
    if not o: return fail(f"Order {order_id} not found")
    if o.get("status") != "pending": return fail(f"Order {order_id} is already {o.get('status')}")
    patch("orders", "order_id", order_id, {"status": "rejected"})
    return ok(f"Order {order_id} rejected")

def note_set(note_id, status):
    n = get_one("notes", "note_id", note_id)
    if not n: return fail(f"Note {note_id} not found")
    if n.get("status") != "pending": return fail(f"Note {note_id} is already {n.get('status')}")
    patch("notes", "note_id", note_id, {"status": status})
    return ok(f"Note {note_id} ({n.get('title','')[:40]}) {status}")

def withdrawal_set(request_id, status):
    w = get_one("withdrawals", "request_id", request_id)
    if not w: return fail(f"Withdrawal {request_id} not found")
    if w.get("status") != "pending": return fail(f"Withdrawal {request_id} is already {w.get('status')}")
    patch("withdrawals", "request_id", request_id, {"status": status})
    if status == "rejected":
        s = get_one("users", "uid", w["seller_id"], "wallet")
        if s:
            patch("users", "uid", w["seller_id"], {"wallet": int(s.get("wallet") or 0) + int(w.get("amount") or 0)})
        return ok(f"Withdrawal {request_id} rejected, Rs {w.get('amount')} refunded to seller wallet")
    return ok(f"Withdrawal {request_id} marked as sent (Rs {w.get('amount')})")

def pending():
    out = {}
    for t, sel in [("orders", "order_id,amount,buyer_id,note_id"),
                   ("withdrawals", "request_id,amount,seller_name,easypaisa_number"),
                   ("notes", "note_id,title,seller_name,price")]:
        out[t] = req("GET", f"/rest/v1/{t}?status=eq.pending&select={sel}&limit=50")
    print(json.dumps(out, indent=1))

def ok(msg): print("OK: " + msg)
def fail(msg): print("FAIL: " + msg); sys.exit(1)

def main():
    args = sys.argv[1:]
    if args == ["pending"]:
        pending(); return
    if len(args) != 3:
        print(__doc__); sys.exit(2)
    kind, action, rid = args
    if action not in ("approve", "approved", "reject", "rejected"):
        fail(f"Unknown action: {action}")
    status = "approved" if action.startswith("approv") else "rejected"
    if kind == "order":
        order_approve(rid) if status == "approved" else order_reject(rid)
    elif kind == "note":
        note_set(rid, status)
    elif kind == "withdrawal":
        withdrawal_set(rid, status)
    else:
        fail(f"Unknown kind: {kind} (use order|note|withdrawal)")

if __name__ == "__main__":
    main()
