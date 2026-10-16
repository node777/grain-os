#!/usr/bin/env python3
"""Talk to Grain's Envoy from the host.

Envoy speaks JSON lines on a virtio console that QEMU exposes as a Unix
socket. This module is three things:

  * a client library:      Session(path).call("store", "put", key=1, value=2)
  * grainsh, a structured shell:   python3 tools/envoy.py shell --socket PATH
  * an MCP bridge, so any MCP-capable agent sees Grain's typed methods as tools:
        python3 tools/envoy.py mcp --socket PATH

Everything the agent can do comes from what Envoy reports (discover and
describe); nothing about Grain's services is hard-coded here.
"""
import argparse
import base64
import json
import os
import shlex
import socket
import sys
import time

# ---------------------------------------------------------------------------
# BLAKE3 for inputs up to one chunk (1024 bytes): enough to check Envoy's
# audit chain, whose entries are short. Python's hashlib has no BLAKE3.

_IV = [0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19]
_PERM = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8]
_M32 = 0xFFFFFFFF


def _rotr(x, n):
    return ((x >> n) | (x << (32 - n))) & _M32


def _g(s, a, b, c, d, x, y):
    s[a] = (s[a] + s[b] + x) & _M32
    s[d] = _rotr(s[d] ^ s[a], 16)
    s[c] = (s[c] + s[d]) & _M32
    s[b] = _rotr(s[b] ^ s[c], 12)
    s[a] = (s[a] + s[b] + y) & _M32
    s[d] = _rotr(s[d] ^ s[a], 8)
    s[c] = (s[c] + s[d]) & _M32
    s[b] = _rotr(s[b] ^ s[c], 7)


def _compress(cv, m, block_len, flags):
    s = list(cv) + _IV[:4] + [0, 0, block_len, flags]
    m = list(m)
    for r in range(7):
        _g(s, 0, 4, 8, 12, m[0], m[1])
        _g(s, 1, 5, 9, 13, m[2], m[3])
        _g(s, 2, 6, 10, 14, m[4], m[5])
        _g(s, 3, 7, 11, 15, m[6], m[7])
        _g(s, 0, 5, 10, 15, m[8], m[9])
        _g(s, 1, 6, 11, 12, m[10], m[11])
        _g(s, 2, 7, 8, 13, m[12], m[13])
        _g(s, 3, 4, 9, 14, m[14], m[15])
        if r < 6:
            m = [m[i] for i in _PERM]
    return [s[i] ^ s[i + 8] for i in range(8)]


def blake3_small(data: bytes) -> bytes:
    """BLAKE3 of at most 1024 bytes (one chunk, so no tree)."""
    if len(data) > 1024:
        raise ValueError("blake3_small handles one chunk only")
    blocks = [data[i:i + 64] for i in range(0, len(data), 64)] or [b""]
    cv = _IV
    for i, blk in enumerate(blocks):
        flags = (1 if i == 0 else 0) | ((2 | 8) if i == len(blocks) - 1 else 0)
        padded = blk + b"\0" * (64 - len(blk))
        words = [int.from_bytes(padded[j:j + 4], "little") for j in range(0, 64, 4)]
        cv = _compress(cv, words, len(blk), flags)
    return b"".join(w.to_bytes(4, "little") for w in cv)


def verify_chain(actions):
    """Recompute Envoy's audit hashes. Returns (ok, index_of_first_bad)."""
    prev = bytes(32)
    for i, a in enumerate(actions):
        text = "{}|{}|{}|{}|{}|{}".format(a["seq"], a["verb"], a["cap"], a["method"], a["outcome"],
                                          a["undo_of"] or 0)
        h = blake3_small(prev + text.encode())
        if h.hex() != a["hash"]:
            return False, i
        prev = h
    return True, None


# ---------------------------------------------------------------------------
# The client


class EnvoyError(Exception):
    def __init__(self, response):
        self.response = response
        super().__init__(f"{response.get('error')}: {response.get('detail', '')}")

    @property
    def code(self):
        return self.response.get("error")


class Session:
    """One connection to Envoy. Requests are answered in order."""

    def __init__(self, path, connect_timeout=30.0, timeout=60.0):
        deadline = time.time() + connect_timeout
        while True:
            try:
                self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.sock.connect(path)
                break
            except OSError:
                self.sock.close()
                if time.time() > deadline:
                    raise
                time.sleep(0.1)
        self.sock.settimeout(timeout)
        self.buf = b""
        self.next_id = 1
        self.transcript = []

    def request(self, verb, **fields):
        req = {"id": self.next_id, "verb": verb, **fields}
        self.next_id += 1
        line = json.dumps(req, separators=(",", ":")) + "\n"
        self.sock.sendall(line.encode())
        while b"\n" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("Envoy closed the connection")
            self.buf += chunk
        raw, self.buf = self.buf.split(b"\n", 1)
        resp = json.loads(raw)
        self.transcript.append((req, resp))
        return resp

    def ok(self, verb, **fields):
        resp = self.request(verb, **fields)
        if not resp.get("ok"):
            raise EnvoyError(resp)
        return resp["result"]

    # Verbs
    def hello(self):
        return self.ok("hello")

    def discover(self):
        return self.ok("discover")["capabilities"]

    def describe(self, cap):
        return self.ok("describe", cap=cap)["descriptor"]

    def call(self, cap, method, **args):
        return self.ok("call", cap=cap, method=method, args=args)

    def plan(self, steps):
        return self.ok("plan", steps=steps)

    def apply(self, steps, allow_partial=False):
        return self.ok("apply", steps=steps, allow_partial=allow_partial)

    def undo(self, action):
        return self.ok("undo", action=action)

    def ask(self, cap, reason=""):
        return self.ok("ask", cap=cap, reason=reason)

    def observe(self, since=0):
        return self.ok("observe", since=since)

    def upload(self, cap, data, piece=2048):
        """Store bytes (up to 64 KiB) as a public object in a content store the
        agent holds; returns the hex hash. One audited action."""
        for off in range(0, len(data), piece):
            self.ok("upload", cap=cap, offset=off, data=base64.b64encode(data[off:off + piece]).decode())
        return self.ok("upload", cap=cap, done=True, len=len(data))["hash"]

    def bye(self):
        return self.ok("bye")


def upload_generation(s, cap, pack_dir):
    """Upload a generation `grain-disk pack` wrote, sending only the chunks the
    store lacks; returns (generation hash, chunks sent, chunks in all)."""
    chunks = os.path.join(pack_dir, "chunks")
    names = sorted(os.listdir(chunks))
    sent = 0
    for name in names:
        if s.call(cap, "has", hash=name)["found"]:
            continue
        with open(os.path.join(chunks, name), "rb") as f:
            got = s.upload(cap, f.read())
        if got != name:
            raise EnvoyError({"error": "hash_mismatch", "detail": f"{name} stored as {got}"})
        sent += 1
    with open(os.path.join(pack_dir, "descriptor"), "rb") as f:
        gen = s.upload(cap, f.read())
    with open(os.path.join(pack_dir, "generation")) as f:
        if gen != f.read().strip():
            raise EnvoyError({"error": "hash_mismatch", "detail": "descriptor"})
    return gen, sent, len(names)


# ---------------------------------------------------------------------------
# MCP bridge: every method of every capability the agent holds becomes a
# tool named <cap>__<method>, with a JSON Schema derived from the
# descriptor. A few grain_* tools expose the Envoy verbs themselves.

MCP_VERSION = "2025-06-18"


def json_schema(field_type):
    if field_type == "bool":
        return {"type": "boolean"}
    if field_type.startswith("enum("):
        return {"type": "string", "enum": field_type[5:-1].split("|")}
    if field_type.startswith("text("):
        return {"type": "string", "maxLength": int(field_type[5:-1])}
    if field_type.startswith("bytes("):
        n = int(field_type[6:-1])
        return {"type": "string", "pattern": "^([0-9a-f]{2})*$", "maxLength": 2 * n,
                "description": f"up to {n} bytes, as hex"}
    if field_type.startswith("u"):
        bits = int(field_type[1:])
        return {"type": "integer", "minimum": 0, "maximum": 2 ** bits - 1}
    if field_type.startswith("i"):
        bits = int(field_type[1:])
        return {"type": "integer", "minimum": -(2 ** (bits - 1)), "maximum": 2 ** (bits - 1) - 1}
    return {}


class Bridge:
    def __init__(self, session):
        self.s = session

    def tools(self):
        tools = []
        for cap in self.s.discover():
            if not cap["granted"]:
                continue
            desc = self.s.describe(cap["name"])
            for m in desc["methods"]:
                props = {p["name"]: {**json_schema(p["type"]), "description": p["doc"]} for p in m["params"]}
                lease = cap["lease"]
                limits = []
                if lease and lease.get("uses_left") is not None:
                    limits.append(f"{lease['uses_left']} uses left")
                if lease and lease.get("expires_in_ms") is not None:
                    limits.append(f"expires in {lease['expires_in_ms']} ms")
                tools.append({
                    "name": f"{cap['name']}__{m['name']}",
                    "description": f"{m['doc']} [{desc['protocol']}, effect: {m['effect']}"
                                   + (f", undo: {m['undo']}" if m["undo"] else "")
                                   + (f", lease: {', '.join(limits)}" if limits else "") + "]",
                    "inputSchema": {"type": "object", "properties": props,
                                    "required": [p["name"] for p in m["params"]]},
                    "annotations": {"readOnlyHint": m["effect"] == "pure",
                                    "destructiveHint": m["effect"] == "external"},
                })
        tools += [
            {"name": "grain_discover", "description": "List the capabilities you hold, with lease limits.",
             "inputSchema": {"type": "object", "properties": {}}},
            {"name": "grain_ask", "description": "Ask the owner for an askable capability.",
             "inputSchema": {"type": "object", "properties": {"cap": {"type": "string"}, "reason": {"type": "string"}},
                             "required": ["cap"]}},
            {"name": "grain_plan", "description": "Dry-run a list of steps {cap, method, args}; changes nothing.",
             "inputSchema": {"type": "object", "properties": {"steps": {"type": "array"}}, "required": ["steps"]}},
            {"name": "grain_apply", "description": "Run steps all-or-nothing (undoable steps only, unless allow_partial).",
             "inputSchema": {"type": "object", "properties": {"steps": {"type": "array"},
                                                              "allow_partial": {"type": "boolean"}},
                             "required": ["steps"]}},
            {"name": "grain_undo", "description": "Undo an earlier action by its number.",
             "inputSchema": {"type": "object", "properties": {"action": {"type": "integer"}}, "required": ["action"]}},
            {"name": "grain_observe", "description": "The audit log of your actions, hash-chained.",
             "inputSchema": {"type": "object", "properties": {"since": {"type": "integer"}}}},
        ]
        return tools

    def call_tool(self, name, args):
        verbs = {"grain_discover": ("discover", {}), "grain_ask": ("ask", args), "grain_plan": ("plan", args),
                 "grain_apply": ("apply", args), "grain_undo": ("undo", args), "grain_observe": ("observe", args)}
        if name in verbs:
            verb, fields = verbs[name]
            resp = self.s.request(verb, **fields)
        else:
            cap, _, method = name.partition("__")
            resp = self.s.request("call", cap=cap, method=method, args=args)
        text = json.dumps(resp.get("result") if resp.get("ok") else resp, separators=(",", ":"))
        return {"content": [{"type": "text", "text": text}], "isError": not resp.get("ok")}

    def handle(self, msg):
        """One JSON-RPC message in, a response out (None for notifications)."""
        method, mid, params = msg.get("method"), msg.get("id"), msg.get("params") or {}
        if mid is None:
            return None
        try:
            if method == "initialize":
                hello = self.s.hello()
                result = {"protocolVersion": MCP_VERSION, "capabilities": {"tools": {}},
                          "serverInfo": {"name": "grain-envoy", "version": "0.4"},
                          "instructions": f"Grain system {hello['system']} (closure {hello['closure'][:16]}...). "
                                          "You are an agent with leased, limited authority."}
            elif method == "tools/list":
                result = {"tools": self.tools()}
            elif method == "tools/call":
                result = self.call_tool(params["name"], params.get("arguments") or {})
            elif method == "ping":
                result = {}
            else:
                return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"unknown method {method}"}}
        except EnvoyError as e:
            return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32000, "message": str(e)}}
        return {"jsonrpc": "2.0", "id": mid, "result": result}


def run_mcp(session):
    bridge = Bridge(session)
    for line in sys.stdin:
        if not line.strip():
            continue
        out = bridge.handle(json.loads(line))
        if out is not None:
            sys.stdout.write(json.dumps(out) + "\n")
            sys.stdout.flush()


# ---------------------------------------------------------------------------
# grainsh: the structured shell. Same verbs, rendered as tables.

def _table(rows, cols):
    def cell(r, c):
        v = r.get(c)
        return "" if v is None else str(v)
    widths = [max(len(c), *(len(cell(r, c)) for r in rows)) if rows else len(c) for c in cols]
    lines = ["  ".join(c.ljust(w) for c, w in zip(cols, widths)).rstrip()]
    lines += ["  ".join(cell(r, c).ljust(w) for c, w in zip(cols, widths)).rstrip() for r in rows]
    return "\n".join(lines)


def _value(text):
    if text in ("true", "false"):
        return text == "true"
    try:
        return int(text, 0)
    except ValueError:
        return text.encode().decode("unicode_escape")


def _limit(lease, key):
    """Blank when there is no lease yet; "-" for a lease without that limit."""
    if not lease:
        return ""
    return "-" if lease.get(key) is None else lease[key]


def _parse_call(words):
    """`store.put key=1 value=2` or `store put key=1 value=2`."""
    cap, _, method = words[0].partition(".")
    rest = words[1:]
    if not method and rest and "=" not in rest[0]:
        method, rest = rest[0], rest[1:]
    args = {}
    for w in rest:
        k, _, v = w.partition("=")
        args[k] = _value(v)
    return {"cap": cap, "method": method, "args": args}


SHELL_HELP = """commands:
  hello                          system, closure hash, verbs
  caps                           what you hold (discover)
  describe <cap>                 methods, parameters, effects, docs
  call <cap>.<method> k=v ...    one call (or: call <cap> <method> k=v ...)
  plan <step> ; <step> ...       dry run (step = cap.method k=v ...)
  apply <step> ; <step> ...      all-or-nothing
  undo <action>                  reverse an action
  ask <cap>                      request an askable capability
  log                            audit log (hash chain checked)
  bye                            end the session"""


def run_shell(session):
    print("grainsh: talking to Envoy. 'help' lists commands.")
    while True:
        try:
            line = input("grain> ").strip()
        except EOFError:
            break
        if not line:
            continue
        words = shlex.split(line)
        cmd = words[0]
        try:
            if cmd == "help":
                print(SHELL_HELP)
            elif cmd == "hello":
                print(json.dumps(session.hello(), indent=2))
            elif cmd == "caps":
                rows = []
                for c in session.discover():
                    lease = c["lease"]
                    rows.append({"name": c["name"], "protocol": c["protocol"], "granted": c["granted"],
                                 "askable": c["askable"],
                                 "uses_left": _limit(lease, "uses_left"),
                                 "expires_in_ms": _limit(lease, "expires_in_ms")})
                print(_table(rows, ["name", "protocol", "granted", "askable", "uses_left", "expires_in_ms"]))
            elif cmd == "describe":
                d = session.describe(words[1])
                print(f"{d['protocol']}: {d['doc']}")
                for m in d["methods"]:
                    params = ", ".join(f"{p['name']}: {p['type']}" for p in m["params"])
                    results = ", ".join(f"{p['name']}: {p['type']}" for p in m["results"])
                    print(f"  {m['name']}({params}) -> ({results})  [{m['effect']}"
                          + (f", undo={m['undo']}" if m["undo"] else "") + f"]  {m['doc']}")
            elif cmd == "call":
                step = _parse_call(words[1:])
                print(json.dumps(session.call(step["cap"], step["method"], **step["args"])))
            elif cmd in ("plan", "apply"):
                steps = [_parse_call(shlex.split(part)) for part in " ".join(words[1:]).split(";")]
                fn = session.plan if cmd == "plan" else session.apply
                print(json.dumps(fn(steps), indent=2))
            elif cmd == "undo":
                print(json.dumps(session.undo(int(words[1]))))
            elif cmd == "ask":
                print(json.dumps(session.ask(words[1], " ".join(words[2:]))))
            elif cmd == "log":
                obs = session.observe()
                ok, bad = verify_chain(obs["actions"])
                print(_table(obs["actions"], ["seq", "verb", "cap", "method", "outcome", "undo_of", "undone"]))
                print(f"hash chain: {'verified' if ok else f'BROKEN at entry {bad}'}  head {obs['head'][:16]}...")
            elif cmd == "bye":
                print(json.dumps(session.bye()))
                break
            else:
                print(f"unknown command {cmd!r}; try 'help'")
        except EnvoyError as e:
            print(f"refused: {e}")
        except (IndexError, ValueError) as e:
            print(f"usage error: {e}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=["shell", "mcp"])
    ap.add_argument("--socket", required=True, help="the Envoy socket QEMU exposes")
    args = ap.parse_args()
    session = Session(args.socket)
    if args.mode == "shell":
        run_shell(session)
    else:
        run_mcp(session)


if __name__ == "__main__":
    main()
