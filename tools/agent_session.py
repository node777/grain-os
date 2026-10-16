"""The Phase 4 agent session: what an AI agent does on a fresh Grain system.

Run by `tools/harness.py --agent tools/agent_session.py` (part of
`zig build qemu-test`). Each check is reported as an `@agent check ...`
line; the harness fails if any check fails.

The exit criterion: the agent discovers and calls a service it was leased,
and is refused once the lease expires.
"""
import contextlib
import io
import sys
import time

from envoy import Bridge, EnvoyError, run_shell, verify_chain

AGENT_BADGE = 0xA6E7


def run(s, check):
    hello = s.hello()
    check("hello", hello["system"] == "grain-dev" and len(hello["closure"]) == 64, hello["system"])

    caps = {c["name"]: c for c in s.discover()}
    check("discover_grants", all(caps[n]["granted"] for n in ("echo", "store", "console")), sorted(caps))
    check("discover_askable", caps["entropy"]["askable"] and not caps["entropy"]["granted"], caps["entropy"])
    check("discover_lease_limits", caps["console"]["lease"]["uses_left"] == 20
          and caps["echo"]["lease"]["expires_in_ms"] is not None, caps["echo"]["lease"])

    d = s.describe("echo")
    ping = next(m for m in d["methods"] if m["name"] == "ping")
    check("describe_from_registry", d["protocol"] == "echo.v1" and ping["params"][0]["name"] == "value"
          and ping["effect"] == "pure", ping)

    r = s.call("echo", "ping", value=41)
    check("call_leased_service", r["value"] == 42 and r["badge"] == AGENT_BADGE, r)

    bridge = Bridge(s)
    init = bridge.handle({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
    tools = bridge.handle({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})["result"]["tools"]
    names = {t["name"] for t in tools}
    out = bridge.handle({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                         "params": {"name": "echo__ping", "arguments": {"value": 1}}})["result"]
    check("mcp_bridge", init["result"]["serverInfo"]["name"] == "grain-envoy"
          and {"echo__ping", "store__put", "grain_ask"} <= names and '"value":2' in out["content"][0]["text"],
          {"server": init["result"]["serverInfo"]["name"], "missing": sorted({"echo__ping", "store__put", "grain_ask"} - names),
           "ping": out["content"][0]["text"][:120]})

    s.call("console", "write", text="agent was here\n")

    steps = [{"cap": "store", "method": "put", "args": {"key": 1, "value": 100}},
             {"cap": "store", "method": "put", "args": {"key": 2, "value": 200}}]
    plan = s.plan(steps)
    count = s.call("store", "count")["count"]
    check("plan_changes_nothing", plan["atomic"] and plan["executable"] and not plan["changes_made"] and count == 0,
          plan)

    applied = s.apply(steps)
    got = s.call("store", "get", key=1)
    check("apply_all_or_nothing", applied["committed"] and got == {"value": 100, "found": True}, applied)

    second = applied["results"][1]["action"]
    s.undo(second)
    got2 = s.call("store", "get", key=2)
    check("undo", got2["found"] is False and s.call("store", "get", key=1)["value"] == 100, got2)

    try:
        s.apply([{"cap": "store", "method": "put", "args": {"key": 3, "value": 3}},
                 {"cap": "console", "method": "write", "args": {"text": "x"}}])
        refused = False
    except EnvoyError as e:
        refused = e.code == "not_atomic"
    check("apply_refuses_non_atomic", refused, "external steps cannot be undone")

    try:
        s.call("entropy", "get")
        before = "allowed"
    except EnvoyError as e:
        before = e.code
    granted = s.ask("entropy", reason="need randomness for a nonce")
    a = s.call("entropy", "get")
    b = s.call("entropy", "get")
    try:
        s.call("entropy", "get")
        third = "allowed"
    except EnvoyError as e:
        third = e.code
    try:
        s.ask("entropy")
        again = "granted"
    except EnvoyError as e:
        again = e.response.get("detail")
    check("ask_and_use_limit", before == "not_granted" and granted["granted"] and a != b
          and third == "lease_exhausted" and again == "already_granted", [before, third, again])

    # Wait out the echo lease; then the same call is refused.
    lease = {c["name"]: c for c in s.discover()}["echo"]["lease"]
    time.sleep(lease["expires_in_ms"] / 1000 + 0.5)
    try:
        s.call("echo", "ping", value=1)
        expired = "allowed"
    except EnvoyError as e:
        expired = e.code
    check("refused_after_lease_expires", expired == "lease_expired", expired)

    # grainsh, the human shell, on the same session: same verbs, same data.
    script = "caps\ncall store put key=9 value=90\ncall store.get key=9\nlog\n"
    shown = io.StringIO()
    stdin = sys.stdin
    try:
        sys.stdin = io.StringIO(script)
        with contextlib.redirect_stdout(shown):
            run_shell(s)
    finally:
        sys.stdin = stdin
    text = shown.getvalue()
    check("grainsh", "kv.v1" in text and '"value": 90' in text and "hash chain: verified" in text
          and "refused" not in text, text[-300:])

    obs = s.observe()
    ok, bad = verify_chain(obs["actions"])
    outcomes = [a["outcome"] for a in obs["actions"]]
    check("audit_chain", ok and obs["head"] == obs["actions"][-1]["hash"]
          and "lease_expired" in outcomes and "lease_exhausted" in outcomes, f"{len(outcomes)} actions, bad={bad}")

    # With a disk attached, every action is also in the durable, signed Ledger.
    if obs.get("ledger") is not None:
        check("ledger_has_every_action", obs["ledger"]["seq"] == len(obs["actions"]), obs["ledger"])
    ident = s.hello().get("identity")
    if ident is not None:
        check("identity_named", len(ident.split("-")) == 3 and all(len(w) == 4 for w in ident.split("-")), ident)

    s.bye()
