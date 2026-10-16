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
import shutil
import socket
import importlib.util
import subprocess
import sys
import tempfile
import threading
import time

PREFIXES = ("@aurora", "@caravan", "@grain")

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


class ConsolePump:
    """The virtio console, as a Unix socket QEMU serves (and waits on before
    starting the guest, so no output is lost). Output goes to a file (and,
    if asked, to stdout); input is what the owner would type."""

    def __init__(self, path, out_path, echo=False):
        self.path, self.out_path, self.echo = path, out_path, echo
        self.sock = None
        self.thread = threading.Thread(target=self._run, daemon=True)

    def start(self, proc, timeout=10.0):
        deadline = time.time() + timeout
        while self.sock is None:
            try:
                s = socket.socket(socket.AF_UNIX)
                s.connect(self.path)
                self.sock = s
            except OSError:
                if proc.poll() is not None or time.time() > deadline:
                    raise RuntimeError("QEMU never opened the console socket")
                time.sleep(0.02)
        self.thread.start()

    def _run(self):
        with open(self.out_path, "ab") as out:
            pending = b""
            while True:
                try:
                    data = self.sock.recv(4096)
                except OSError:
                    break
                if not data:
                    break
                out.write(data)
                out.flush()
                if self.echo:
                    pending += data
                    *lines, pending = pending.split(b"\n")
                    for line in lines:
                        print(f"console| {line.decode('utf-8', 'replace')}", flush=True)

    def send(self, text):
        self.sock.sendall(text.encode())

    def join(self, timeout=5.0):
        self.thread.join(timeout=timeout)


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
    ap.add_argument("--agent", action="append", default=[],
                    help="Python file with run(session, check): an agent session to run against Envoy "
                         "('N:file' for boot N only)")
    ap.add_argument("--agent-env", action="append", default=[],
                    help="K=V to set in the environment of agent scripts")
    ap.add_argument("--realtime", action="store_true",
                    help="run QEMU free (no -icount): guest time is real time, for lease durations "
                         "and interactive use; not deterministic")
    ap.add_argument("--interactive", action="store_true",
                    help="print the Envoy socket and wait (connect with tools/envoy.py shell); "
                         "what you type goes to the console")
    ap.add_argument("--console-input", action="append", default=[],
                    help="a line to type on the console (e.g. the disk passphrase); repeatable")
    ap.add_argument("--disk", default=None,
                    help="attach this raw disk image (virtio-blk); a fresh copy unless --disk-inplace")
    ap.add_argument("--disk-inplace", action="store_true",
                    help="use the --disk image itself, so a later run sees what this one wrote")
    ap.add_argument("--disk-seed", default=None,
                    help="with --disk-inplace: if the --disk image does not exist yet, start it as a copy of this one")
    ap.add_argument("--boots", type=int, default=1,
                    help="boot this many times in a row on the same disk; prefix --expect, "
                         "--expect-console, --console-input and --kill-on with 'N:' for one boot")
    ap.add_argument("--kill-on", action="append", default=[],
                    help="'N:record': cut the power (kill QEMU) the moment boot N prints this record")
    args = ap.parse_args()

    for kv in args.agent_env:
        k, _, v = kv.partition("=")
        os.environ[k] = v
    tmpdir = tempfile.mkdtemp(prefix="grain-")
    disk = None
    if args.disk:
        disk = args.disk
        if args.disk_inplace and args.disk_seed and not os.path.exists(disk):
            shutil.copyfile(args.disk_seed, disk)
            print(f"harness: new disk {disk}", flush=True)
        if not args.disk_inplace:
            disk = os.path.join(tmpdir, "disk.img")
            shutil.copyfile(args.disk, disk)
    status = 0
    for boot in range(1, args.boots + 1):
        if args.boots > 1:
            print(f"harness: boot {boot} of {args.boots}", flush=True)
        st = run_boot(args, boot, tmpdir, disk)
        if st == 130:
            return st
        status = status or st
    if status != 0:
        print(f"harness: FAIL (status {status})", file=sys.stderr)
    return status


def for_boot(values, boot):
    """The values that apply to this boot: unprefixed ones, and 'N:...' for N == boot."""
    out = []
    for v in values:
        head, sep, rest = v.partition(":")
        if sep and head.isdigit():
            if int(head) == boot:
                out.append(rest)
        else:
            out.append(v)
    return out


def run_boot(args, boot, tmpdir, disk):
    devices = []
    console_path = None
    envoy_path = os.path.join(tmpdir, f"envoy{boot}.sock")
    # Envoy is a task that waits for its agent: give it a port only on boots
    # that have one (elsewhere it is skipped, its port being optional).
    envoy_socket = args.envoy_socket or args.interactive or bool(for_boot(args.agent, boot))
    if args.virtio_console or args.virtio_rng or envoy_socket or disk:
        devices += ["-global", "virtio-mmio.force-legacy=false"]
    if args.virtio_rng:
        devices += ["-object", f"rng-random,id=rng0,filename={args.virtio_rng}", "-device", "virtio-rng-device,rng=rng0"]
    if disk:
        devices += ["-drive", f"file={disk},format=raw,if=none,id=disk0,cache=writeback",
                    "-device", "virtio-blk-device,drive=disk0"]
    expect = for_boot(args.expect, boot)
    expect_console = for_boot(args.expect_console, boot)
    console_input = for_boot(args.console_input, boot)
    kill_on = for_boot(args.kill_on, boot)
    agents = for_boot(args.agent, boot)
    pump = None
    if args.virtio_console or expect_console or console_input or args.interactive:
        fd, console_path = tempfile.mkstemp(prefix="grain-console-")
        os.close(fd)
        console_sock = os.path.join(tmpdir, f"console{boot}.sock")
        devices += ["-device", "virtio-serial-device,id=vser0",
                    "-chardev", f"socket,id=con0,path={console_sock},server=on,wait=on",
                    "-device", "virtconsole,chardev=con0,bus=vser0.0"]
        pump = ConsolePump(console_sock, console_path, echo=args.interactive)
    if envoy_socket:
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
    if args.interactive and not agents:
        # A person drives this run: stream the output, wait for the guest to
        # halt (the agent's `bye` ends Envoy) or for ^C.
        print(f"harness: Envoy socket: {envoy_path}", flush=True)
        print(f"harness: connect with: python3 tools/envoy.py shell --socket {envoy_path}", flush=True)
        proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL)
        try:
            if pump:
                pump.start(proc)
                for line in console_input:
                    pump.send(line + "\n")

                def typing():
                    for line in sys.stdin:
                        try:
                            pump.send(line)
                        except OSError:
                            return
                threading.Thread(target=typing, daemon=True).start()
            return proc.wait()
        except KeyboardInterrupt:
            proc.kill()
            return 130
    proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    lines = []
    killed = []

    def read_output():
        for raw in proc.stdout:
            line = raw.decode("utf-8", "replace").rstrip("\r\n")
            lines.append(line)
            if kill_on and record_prefix(line):
                rec = parse_record(line)
                if rec and any(matches(rec, k) for k in kill_on) and not killed:
                    proc.kill()  # the power goes, mid-whatever
                    killed.append(line)
    reader = threading.Thread(target=read_output, daemon=True)
    reader.start()
    if pump:
        pump.start(proc)
        for line in console_input:
            pump.send(line + "\n")

    agent_failures = []
    for agent in agents:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import envoy
        spec = importlib.util.spec_from_file_location("agent_script", agent)
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
    if killed:
        print(f"harness: power cut at: {killed[0]}")
        status = 0
    if agent_failures:
        print(f"harness: agent checks failed: {', '.join(agent_failures)}", file=sys.stderr)
        status = status or 1

    records = []
    for line in lines:
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
    if pump:
        pump.join()
    if console_path:
        with open(console_path, "rb") as f:
            console = f.read().decode("utf-8", "replace")
        os.unlink(console_path)
        if args.show_console:
            for line in console.splitlines():
                print(f"console| {line}")
    for text in expect_console:
        if text not in console:
            print(f"harness: virtio console output lacks: {text!r}", file=sys.stderr)
            status = status or 1

    missing = [e for e in expect if not any(matches(r, e) for r in records)]
    for e in missing:
        print(f"harness: missing expected record{f' (boot {boot})' if args.boots > 1 else ''}: {e}", file=sys.stderr)
    if status == 124:
        print(f"harness: timed out after {args.timeout}s", file=sys.stderr)
    if not records:
        print("harness: kernel produced no records", file=sys.stderr)
        status = status or 1
    if missing:
        status = status or 1
    return status


if __name__ == "__main__":
    sys.exit(main())
