"""The Phase 7 session: two instances meet, one hosts an application the
other uses, a file moves between them, and access is revoked.

Run by tools/pair.py (part of `zig build qemu-test`). Each instance has its
own disk, entropy and identity; their network devices share one link. Each
owner's agent drives its own instance through Envoy, asking for Comlink
first (lending things to other people is the owner's call).
"""
import os

from envoy import EnvoyError

CONTENT = (b"A letter from one instance to another: content-addressed, so what "
           b"arrives is checked against the name it was sent under. " * 3)


def refused(fn):
    try:
        fn()
        return None
    except EnvoyError as e:
        return e.code


def run(a, b, check):
    na = a.wait("kumara_ready", timeout=240)["name"]
    nb = b.wait("kumara_ready", timeout=240)["name"]
    sa = a.wait("comlink_session", timeout=240)
    sb = b.wait("comlink_session", timeout=240)
    check("introduced", na != nb and sa["peer"] == nb and sb["peer"] == na and sa["hash"] == sb["hash"],
          (na, nb, sa, sb))

    A, B = a.session(), b.session()
    check("comlink_asked", A.ask("comlink", reason="share with a friend")["granted"]
          and B.ask("comlink", reason="use what friends share")["granted"])
    peer = A.call("comlink", "peer", index=0)
    check("peer_by_identity", peer["name"] == nb and peer["session"], peer)

    # A hosts the guestbook and lends it to B: a lease, at most three calls.
    m = b.mark()
    share = A.call("comlink", "share", service="guestbook", to=nb, uses=3, seconds=0)["share"]
    a.wait("ledger_appended by=comlink kind=comlink_share")
    b.wait("comlink_imported kind=service service=guestbook", after=m)
    cap = f"guestbook@{na}"
    caps = {c["name"]: c for c in B.discover()}
    check("remote_capability", cap in caps and caps[cap]["remote"] and caps[cap]["protocol"] == "guestbook.v1",
          sorted(caps))
    sign = next(x for x in B.describe(cap)["methods"] if x["name"] == "sign")
    check("remote_descriptor", sign["params"][0]["name"] == "text", sign)

    # B's agent signs A's guestbook, as if it were local.
    r = B.call(cap, "sign", text=f"hello from {nb}")
    a.wait("guestbook_signed entry=0 by=comlink")
    line = B.call(cap, "read", entry=0)
    check("hosted_app_used", r["entry"] == 0 and line["text"] == f"hello from {nb}" and line["by"] == "comlink", line)

    # The lease counts: the third call was the last one it allows.
    B.call(cap, "count")
    over = refused(lambda: B.call(cap, "count"))
    a.wait("comlink_served ok=false status=lease_exhausted")
    check("lease_limits_remote_use", over is not None, over)

    # A file moves from A to B, by its hash.
    A.ask("tablecloth", reason="share a file")
    h = A.upload("tablecloth", CONTENT)
    m = b.mark()
    A.call("comlink", "share_object", hash=h, to=nb)
    b.wait("comlink_imported kind=object", after=m)
    imports = [B.call("comlink", "imported", index=i) for i in range(B.call("comlink", "whoami")["imports"])]
    obj = next(i for i, x in enumerate(imports) if x["kind"] == "object")
    got = B.call("comlink", "fetch", **{"import": obj})
    B.ask("tablecloth", reason="read what arrived")
    back = B.call("tablecloth", "read", hash=h, offset=0)
    check("file_moved", got["hash"] == h and got["size"] == len(CONTENT) and bytes.fromhex(back["data"]) == CONTENT[:480],
          (got, h))

    # A second lease on the guestbook, then A takes it back.
    m = b.mark()
    share2 = A.call("comlink", "share", service="guestbook", to=nb, uses=0, seconds=0)["share"]
    b.wait("comlink_imported kind=service", after=m)
    B.discover()
    B.call(cap, "sign", text="before")
    m = b.mark()
    A.call("comlink", "revoke", share=share2)
    a.wait("comlink_revoked service=guestbook")
    a.wait("ledger_appended by=comlink kind=comlink_revoke")
    b.wait("comlink_withdrawn service=guestbook", after=m)
    after = refused(lambda: B.call(cap, "sign", text="after"))
    gone = cap not in {c["name"] for c in B.discover()}
    check("revoked", after is not None and gone, (after, gone))
    entries = A.call("comlink", "shared", index=share2)
    check("revocation_recorded", not entries["active"], entries)
    print(f"@pair session a={na} b={nb}", flush=True)
    A.bye()
    B.bye()
