#!/usr/bin/env python3
"""TUM Notes Hub admin actions for WhatsApp approval flow.
Thin wrapper over the server Edge Functions — ALL money logic lives there.
Auth: WA_ADMIN_SECRET from .service_key (gitignored, never commit).
Usage:
  wa-admin.py order approve <order_id> | order reject <order_id>
  wa-admin.py note approve <note_id>   | note reject <note_id>
  wa-admin.py withdrawal approve <request_id> | withdrawal reject <request_id>
  wa-admin.py pending   (list current pending items, for testing)
"""
import json, sys, os, urllib.request, urllib.error

SUPABASE_URL = "https://xsvkyiigcjibgkcytssr.supabase.co"
# anon key: only used to pass the functions gateway; real auth is admin_secret
ANON = "sb_publishable_srRWNgXit_vUS9V2CXk39g_yVolDTNe"

def _load_secret():
    here = os.path.dirname(os.path.abspath(__file__))
    p = os.path.join(here, ".service_key")
    if os.path.exists(p):
        s = open(p).read().strip()
        if s:
            return s
    print("FAIL: .service_key missing — cannot authenticate")
    sys.exit(1)

SECRET = _load_secret()

def call_fn(name, payload):
    payload = dict(payload)
    payload["admin_secret"] = SECRET
    url = SUPABASE_URL + "/functions/v1/" + name
    data = json.dumps(payload).encode()
    r = urllib.request.Request(url, data=data, headers={
        "apikey": ANON,
        "Authorization": "Bearer " + ANON,
        "Content-Type": "application/json",
    }, method="POST")
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        try:
            body = json.loads(e.read().decode())
        except Exception:
            body = {"error": "http " + str(e.code)}
        print("FAIL: " + str(body.get("error", body)))
        sys.exit(1)

def ok(msg): print("OK: " + msg)
def fail(msg): print("FAIL: " + msg); sys.exit(1)

def main():
    args = sys.argv[1:]
    if args == ["pending"]:
        print(json.dumps(call_fn("get-pending", {}), indent=1))
        return
    if len(args) != 3:
        print(__doc__); sys.exit(2)
    kind, action, rid = args
    if action not in ("approve", "approved", "reject", "rejected"):
        fail("Unknown action: " + action)
    act = "approve" if action.startswith("approv") else "reject"
    if kind == "order":
        d = call_fn("approve-order", {"order_id": rid, "action": act})
        ok("Order %s -> %s (seller +%s, commission %s)" % (rid, d.get("status"), d.get("earning"), d.get("commission")))
    elif kind == "note":
        d = call_fn("decide-note", {"note_id": rid, "action": act})
        ok("Note %s -> %s" % (rid, d.get("status")))
    elif kind == "withdrawal":
        d = call_fn("decide-withdrawal", {"request_id": rid, "action": act})
        ok("Withdrawal %s -> %s" % (rid, d.get("status")))
    else:
        fail("Unknown kind: " + kind + " (use order|note|withdrawal)")

if __name__ == "__main__":
    main()
