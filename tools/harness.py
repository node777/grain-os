#!/usr/bin/env python3
"""Boot a Caravan kernel in QEMU and report what it said.

The kernel and user programs write structured records to the serial console:

    @caravan <event> key=value key="quoted value" ...     (kernel)
    @grain <event> key=value ...                          (user space)

This harness runs QEMU, keeps only those records, and prints each one, either
as text or (with --json) as one JSON object per line. Its exit status is
QEMU's: 0 when the kernel exits through the test finisher with success, the
failure count otherwise, 124 on timeout.

    python3 tools/harness.py zig-out/bin/caravan
    python3 tools/harness.py --json --expect "test name=timer_interrupt result=pass" zig-out/bin/caravan
"""
import argparse
import json
import os
import shlex
import importlib.util
import subprocess
import sys
import tempfile
import threading
import time

PREFIXES = ("@caravan", "@grain")

QEMU_RISCV64 = [
    "qemu-system-riscv64", "-machine", "virt", "-cpu", "rv64",
    "-m", "256M", "-nographic", "-bios", "default", "-no-reboot",
    "-icount", "shift=0,sleep=off",
]


def record_prefix(line):
    for p in PREFIXES:
        if line.startswith(p + " "):
            return p
    return None


def parse_record(line):
    """Parse '@caravan event k=v k="v"' into {'source': 'caravan', 'event': ..., 'k': 'v', ...}."""
    prefix = record_prefix(line)
    if prefix is None:
        return None
    body = line[len(prefix):].strip()
    lexer = shlex.shlex(body, posix=True)
    lexer.whitespace_split = True
    lexer.commenters = ""
    tokens = list(lexer)
    if not tokens:
        return None
    rec = {"source": prefix[1:], "event": tokens[0]}
    for tok in tokens[1:]:
        key, sep, value = tok.partition("=")
        rec[key] = value if sep else True
    return rec


def matches(rec, expectation):
    want = parse_record("@grain " + expectation)
    want.pop("source")
    return all(rec.get(k) == v for k, v in want.items())


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("kernel")
    ap.add_argument("--json", action="store_true", help="print records as JSON lines")
    ap.add_argument("--raw", action="store_true", help="also print non-record console output")
    ap.add_argument("--timeout", type=float, default=60.0)
    ap.add_argument("--smp", default="2", help="number of harts")
    ap.add_argument("--expect", action="append", default=[],
                    help='record that must appear, e.g. "test name=timer_interrupt result=pass"')
    ap.add_argument("--qemu-arg", action="append", default=[], help="extra QEMU argument")
    ap.add_argument("--filter", default="", help="comma-separated events to print (default: all)")
    ap.add_argument("--virtio-console", action="store_true",
                    help="attach a virtio console whose output goes to a temporary file")
    ap.add_argument("--show-console", action="store_true", help="print the virtio console output afterwards")
    ap.add_argument("--expect-console", action="append", default=[], help="text the virtio console must contain")
    ap.add_argument("--virtio-rng", default=None, help="attach a virtio entropy device reading this file")
    ap.add_argument("--envoy-socket", action="store_true",
                    help="attach a second virtio console for Envoy, as a Unix socket")
    ap.add_argument("--agent", default=None,
                    help="Python file with run(session, check): an agent session to run against Envoy")
    ap.add_argument("--realtime", action="store_true",
                    help="run QEMU free (no -icount): guest time is real time, for lease durations "
                         "and interactive use; not deterministic")
    ap.add_argument("--interactive", action="store_true",
                    help="print the Envoy socket and wait (connect with tools/envoy.py shell)")
    args = ap.parse_args()

    devices = []
    console_path = None
    tmpdir = tempfile.mkdtemp(prefix="grain-")
    envoy_path = os.path.join(tmpdir, "envoy.sock")
    if args.agent or args.interactive:
        args.envoy_socket = True
    if args.virtio_console or args.virtio_rng or args.envoy_socket:
        devices += ["-global", "virtio-mmio.force-legacy=false"]
    if args.virtio_rng:
        devices += ["-object", f"rng-random,id=rng0,filename={args.virtio_rng}", "-device", "virtio-rng-device,rng=rng0"]
    if args.virtio_console or args.expect_console:
        fd, console_path = tempfile.mkstemp(prefix="grain-console-")
        os.close(fd)
        devices += ["-device", "virtio-serial-device,id=vser0", "-chardev", f"file,id=con0,path={console_path}",
                    "-device", "virtconsole,chardev=con0,bus=vser0.0"]
    if args.envoy_socket:
        # Created after the first console, so it is the second virtio console
        # in device-tree order (manifest: instance = 1).
        devices += ["-device", "virtio-serial-device,id=vser1", "-chardev", f"socket,id=envoy0,path={envoy_path},server=on,wait=off",
                    "-device", "virtconsole,chardev=envoy0,bus=vser1.0"]
    qemu = list(QEMU_RISCV64)
    if args.realtime or args.interactive:
        # Not -icount sleep=on: with QEMU 8.2 and two harts that stalls the
        # boot (no progress once a hart-1 domain starts; the same image runs
        # under sleep=off and free-running TCG). Free TCG is real time anyway.
        i = qemu.index("-icount")
        del qemu[i:i + 2]
    cmd = qemu + ["-smp", args.smp] + devices + args.qemu_arg + ["-kernel", args.kernel]
    if args.interactive and not args.agent:
        # A person drives this run: stream the output, wait for the guest to
        # halt (the agent's `bye` ends Envoy) or for ^C.
        print(f"harness: Envoy socket: {envoy_path}", flush=True)
        print(f"harness: connect with: python3 tools/envoy.py shell --socket {envoy_path}", flush=True)
        try:
            return subprocess.call(cmd, stdin=subprocess.DEVNULL)
        except KeyboardInterrupt:
            return 130
    proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    chunks = []
    reader = threading.Thread(target=lambda: chunks.append(proc.stdout.read()), daemon=True)
    reader.start()

    agent_failures = []
    if args.agent:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import envoy
        spec = importlib.util.spec_from_file_location("agent_script", args.agent)
        script = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(script)

        def check(name, ok, detail=""):
            print(f"@agent check name={name} result={'pass' if ok else 'fail'}"
                  + ("" if ok else f" detail={json.dumps(str(detail))}"))
            if not ok:
                agent_failures.append(name)
        try:
            script.run(envoy.Session(envoy_path, connect_timeout=args.timeout), check)
        except Exception as e:  # report and fail, don't hang
            print(f"@agent error={type(e).__name__} detail={json.dumps(str(e))}")
            agent_failures.append("exception")

    try:
        status = proc.wait(timeout=args.timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        status = 124
    reader.join(timeout=5)
    out = b"".join(chunks)
    if agent_failures:
        print(f"harness: agent checks failed: {', '.join(agent_failures)}", file=sys.stderr)
        status = status or 1

    records = []
    for raw in out.decode("utf-8", "replace").splitlines():
        line = raw.strip("\r")
        if record_prefix(line):
            rec = parse_record(line)
            if rec:
                records.append(rec)
                shown = not args.filter or rec["event"] in args.filter.split(",")
                if shown:
                    print(json.dumps(rec) if args.json else line)
        elif args.raw:
            print(line)

    console = ""
    if console_path:
        with open(console_path, "rb") as f:
            console = f.read().decode("utf-8", "replace")
        os.unlink(console_path)
        if args.show_console:
            for line in console.splitlines():
                print(f"console| {line}")
    for text in args.expect_console:
        if text not in console:
            print(f"harness: virtio console output lacks: {text!r}", file=sys.stderr)
            status = status or 1

    missing = [e for e in args.expect if not any(matches(r, e) for r in records)]
    for e in missing:
        print(f"harness: missing expected record: {e}", file=sys.stderr)
    if status == 124:
        print(f"harness: timed out after {args.timeout}s", file=sys.stderr)
    if not records:
        print("harness: kernel produced no records", file=sys.stderr)
        status = status or 1
    if missing:
        status = status or 1
    if status != 0:
        print(f"harness: FAIL (status {status})", file=sys.stderr)
    return status


if __name__ == "__main__":
    sys.exit(main())
