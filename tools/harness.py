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
import shlex
import subprocess
import sys

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
    args = ap.parse_args()

    cmd = QEMU_RISCV64 + ["-smp", args.smp] + args.qemu_arg + ["-kernel", args.kernel]
    try:
        proc = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, timeout=args.timeout)
        status = proc.returncode
        out = proc.stdout
    except subprocess.TimeoutExpired as e:
        status = 124
        out = e.stdout or b""

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
