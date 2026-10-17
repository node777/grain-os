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
import stat
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

# Arm: QEMU loads the ELF and enters it at EL1, PSCI through hvc (no
# firmware), the device tree at the start of RAM.
QEMU_AARCH64 = [
    "qemu-system-aarch64", "-machine", "virt", "-cpu", "cortex-a72",
    "-m", "256M", "-nographic", "-no-reboot",
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


class Screen:
    """The display, for scripts: QEMU's monitor (QMP) takes screenshots and
    types and clicks as the owner would, and records can be waited for.

    Coordinates are screen pixels; colours are 0xRRGGBB."""

    # What a character is typed with: QEMU key names (qcodes), shifted or not.
    SHIFTED = {'!': '1', '@': '2', '#': '3', '$': '4', '%': '5', '^': '6', '&': '7', '*': '8', '(': '9', ')': '0',
               '_': 'minus', '+': 'equal', '{': 'bracket_left', '}': 'bracket_right', ':': 'semicolon',
               '"': 'apostrophe', '~': 'grave_accent', '|': 'backslash', '<': 'comma', '>': 'dot', '?': 'slash'}
    PLAIN = {' ': 'spc', '\n': 'ret', '-': 'minus', '=': 'equal', '[': 'bracket_left', ']': 'bracket_right',
             ';': 'semicolon', "'": 'apostrophe', '`': 'grave_accent', '\\': 'backslash', ',': 'comma', '.': 'dot',
             '/': 'slash', '\b': 'backspace', '\t': 'tab'}

    def __init__(self, qmp_path, lines, proc, width, height):
        self.qmp_path, self.lines, self.proc = qmp_path, lines, proc
        self.width, self.height = width, height
        self.sock = None
        self.shots = 0

    def _qmp(self, command, **arguments):
        if self.sock is None:
            deadline = time.time() + 10
            while True:
                try:
                    s = socket.socket(socket.AF_UNIX)
                    s.connect(self.qmp_path)
                    break
                except OSError:
                    if time.time() > deadline:
                        raise
                    time.sleep(0.05)
            self.sock = s
            self.f = s.makefile("rw")
            self.f.readline()  # greeting
            self._qmp("qmp_capabilities")
        msg = {"execute": command}
        if arguments:
            msg["arguments"] = arguments
        self.f.write(json.dumps(msg) + "\n")
        self.f.flush()
        while True:
            r = json.loads(self.f.readline())
            if "error" in r:
                raise RuntimeError(f"QMP {command}: {r['error']}")
            if "return" in r:
                return r["return"]

    def wait(self, expectation, timeout=60.0, after=0):
        """Block until a record matching `expectation` appears (at or after
        line index `after`); returns its index."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            for i in range(after, len(self.lines)):
                line = self.lines[i]
                if record_prefix(line):
                    rec = parse_record(line)
                    if rec and matches(rec, expectation):
                        return i
            if self.proc.poll() is not None:
                break
            time.sleep(0.02)
        raise TimeoutError(f"no record {expectation!r}")

    def mark(self):
        """A position in the output, to wait for records after it."""
        return len(self.lines)

    def shot(self, keep=None):
        """A screenshot: (width, height, RGB bytes). `keep` saves the PPM."""
        path = keep or os.path.join(os.path.dirname(self.qmp_path), f"shot{self.shots}.ppm")
        self.shots += 1
        self._qmp("screendump", filename=os.path.abspath(path))
        with open(path, "rb") as f:
            data = f.read()
        # P6\n<w> <h>\n255\n<rgb>
        parts = data.split(b"\n", 3)
        w, h = (int(v) for v in parts[1].split())
        return w, h, parts[3]

    @staticmethod
    def pixel(image, x, y):
        w, _, rgb = image
        i = (y * w + x) * 3
        return rgb[i] << 16 | rgb[i + 1] << 8 | rgb[i + 2]

    def _keys(self, names, down):
        self._qmp("input-send-event", events=[{"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": n}}} for n in names])

    def key(self, *names):
        """Press and release keys together (e.g. key("shift", "a"))."""
        self._keys(names, True)
        self._keys(list(reversed(names)), False)

    def type(self, text, pace=0.05):
        """Type like a person: the device lends the guest only so many event
        buffers, and a burst beyond them is dropped, as on real hardware."""
        for ch in text:
            time.sleep(pace)
            if ch.isalpha() and ch.isupper():
                self.key("shift", ch.lower())
            elif ch.isalnum():
                self.key(ch)
            elif ch in self.SHIFTED:
                self.key("shift", self.SHIFTED[ch])
            else:
                self.key(self.PLAIN[ch])

    def move(self, x, y):
        self._qmp("input-send-event", events=[
            {"type": "abs", "data": {"axis": "x", "value": x * 32767 // (self.width - 1)}},
            {"type": "abs", "data": {"axis": "y", "value": y * 32767 // (self.height - 1)}}])

    def click(self, x, y):
        self.move(x, y)
        for down in (True, False):
            self._qmp("input-send-event", events=[{"type": "btn", "data": {"down": down, "button": "left"}}])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("kernel")
    ap.add_argument("--json", action="store_true", help="print records as JSON lines")
    ap.add_argument("--raw", action="store_true", help="also print non-record console output")
    ap.add_argument("--timeout", type=float, default=60.0)
    ap.add_argument("--smp", default="2", help="number of harts")
    ap.add_argument("--arch", choices=["riscv64", "aarch64"], default="riscv64",
                    help="the kernel's architecture (QEMU virt either way)")
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
    ap.add_argument("--disk-bus", choices=["virtio", "nvme"], default="virtio",
                    help="attach the --disk as virtio-blk (default) or as an NVMe drive on PCI")
    ap.add_argument("--disk-inplace", action="store_true",
                    help="use the --disk image itself, so a later run sees what this one wrote")
    ap.add_argument("--disk-seed", default=None,
                    help="with --disk-inplace: if the --disk image does not exist yet, start it as a copy of this one")
    ap.add_argument("--boots", type=int, default=1,
                    help="boot this many times in a row on the same disk; prefix --expect, "
                         "--expect-console, --console-input and --kill-on with 'N:' for one boot")
    ap.add_argument("--display", nargs="?", const="virtio", choices=["virtio", "native"], default=None,
                    help="attach a screen (1024x768), keyboard and tablet, driven through QMP: virtio devices, "
                         "or 'native' ones (a Bochs display on PCI, a USB keyboard and tablet on xHCI); "
                         "agent scripts with a third parameter get a Screen")
    ap.add_argument("--window", action="store_true",
                    help="with --display: show the screen in a window on the host (records still come on stdout)")
    ap.add_argument("--kill-on", action="append", default=[],
                    help="'N:record': cut the power (kill QEMU) the moment boot N prints this record")
    ap.add_argument("--envoy-path", default=None,
                    help="serve Envoy at this socket path (its directory must be private to you) "
                         "instead of a new one in a temporary directory")
    ap.add_argument("--owner-approve", action="append", default=[],
                    help="answer yes, as the owner would, when the system asks about this agent service")
    ap.add_argument("--owner-refuse", action="append", default=[],
                    help="answer no when the system asks about this agent service")
    ap.add_argument("--keep-temp", action="store_true", help="keep the temporary directory (sockets, disk copies)")
    args = ap.parse_args()
    if args.envoy_path:
        try:
            prepare_socket_path(args.envoy_path)
        except RuntimeError as e:
            print(f"harness: {e}", file=sys.stderr)
            return 2

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
    try:
        for boot in range(1, args.boots + 1):
            if args.boots > 1:
                print(f"harness: boot {boot} of {args.boots}", flush=True)
            st = run_boot(args, boot, tmpdir, disk)
            if st == 130:
                return st
            status = status or st
    finally:
        if args.keep_temp:
            print(f"harness: kept {tmpdir}", file=sys.stderr)
        else:
            shutil.rmtree(tmpdir, ignore_errors=True)
    if status != 0:
        print(f"harness: FAIL (status {status})", file=sys.stderr)
    return status


def prepare_socket_path(path):
    """Make `path` ready for QEMU to serve a socket at: its directory exists
    and is private (Envoy speaks for the agent, so only you may connect),
    and no live instance is serving there already."""
    d = os.path.dirname(os.path.abspath(path))
    if not os.path.isdir(d):
        os.makedirs(d, mode=0o700)
    st = os.stat(d)
    if st.st_uid != os.getuid() or st.st_mode & 0o077:
        raise RuntimeError(f"{d} must belong to you and be private to you (chmod 700 {d})")
    if os.path.lexists(path):
        if not stat.S_ISSOCK(os.lstat(path).st_mode):
            raise RuntimeError(f"{path} exists and is not a socket")
        probe = socket.socket(socket.AF_UNIX)
        try:
            probe.connect(path)
            raise RuntimeError(f"another instance is serving {path}")
        except OSError:
            os.unlink(path)  # left by an instance that has gone
        finally:
            probe.close()


class HiddenInput:
    """While a person types into the system's console, don't show what they
    type (the disk's passphrase goes this way). A no-op when stdin is not a
    terminal."""

    def __enter__(self):
        self.saved = None
        try:
            import termios
            if sys.stdin.isatty():
                fd = sys.stdin.fileno()
                self.saved = termios.tcgetattr(fd)
                quiet = termios.tcgetattr(fd)
                quiet[3] &= ~termios.ECHO
                termios.tcsetattr(fd, termios.TCSADRAIN, quiet)
        except (ImportError, OSError):
            self.saved = None
        return self

    def __exit__(self, *exc):
        if self.saved is not None:
            import termios
            termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, self.saved)


def answer_owner(rec, pump, approve, refuse):
    """Answer the system's question to its owner, as a person at the console
    would: `owner_asked service=X` is a question, `yes` or `no` the answer."""
    if not rec or rec.get("event") != "owner_asked":
        return
    service = rec.get("service")
    if service in approve or service in refuse:
        try:
            pump.send("yes\n" if service in approve else "no\n")
        except (AttributeError, OSError):
            pass  # the console is gone (or not yet up): the question stays open


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
    envoy_path = args.envoy_path or os.path.join(tmpdir, f"envoy{boot}.sock")
    # Envoy is a task that waits for its agent: give it a port only on boots
    # that have one (elsewhere it is skipped, its port being optional).
    envoy_socket = args.envoy_socket or args.interactive or bool(for_boot(args.agent, boot))
    if args.virtio_console or args.virtio_rng or envoy_socket or disk or args.display:
        devices += ["-global", "virtio-mmio.force-legacy=false"]
    qmp_path = os.path.join(tmpdir, f"qmp{boot}.sock")
    if args.display == "native":
        devices += ["-device", "bochs-display", "-device", "qemu-xhci,id=xhci",
                    "-device", "usb-kbd,bus=xhci.0", "-device", "usb-tablet,bus=xhci.0",
                    "-qmp", f"unix:{qmp_path},server=on,wait=off"]
    elif args.display:
        # Keyboard before tablet: device-tree order, so the manifest's
        # instance 0 and 1 (Surf tells them apart by what they report).
        devices += ["-device", "virtio-gpu-device,xres=1024,yres=768",
                    "-device", "virtio-keyboard-device", "-device", "virtio-tablet-device",
                    "-qmp", f"unix:{qmp_path},server=on,wait=off"]
    if args.virtio_rng:
        devices += ["-object", f"rng-random,id=rng0,filename={args.virtio_rng}", "-device", "virtio-rng-device,rng=rng0"]
    if disk:
        devices += ["-drive", f"file={disk},format=raw,if=none,id=disk0,cache=writeback",
                    "-device", "nvme,drive=disk0,serial=grain0" if args.disk_bus == "nvme" else "virtio-blk-device,drive=disk0"]
    expect = for_boot(args.expect, boot)
    expect_console = for_boot(args.expect_console, boot)
    console_input = for_boot(args.console_input, boot)
    kill_on = for_boot(args.kill_on, boot)
    agents = for_boot(args.agent, boot)
    pump = None
    if args.virtio_console or expect_console or console_input or args.interactive:
        console_path = os.path.join(tmpdir, f"console{boot}.txt")
        open(console_path, "wb").close()
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
    qemu = list(QEMU_AARCH64 if args.arch == "aarch64" else QEMU_RISCV64)
    if args.window:
        # A window for the screen; the serial console stays on stdout.
        qemu.remove("-nographic")
        qemu += ["-display", "default", "-serial", "stdio", "-monitor", "none"]
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
        if pump and sys.stdin.isatty():
            print("harness: what you type goes to the system's console and is not shown", flush=True)
        proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL)
        try:
            with HiddenInput():
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
            if pump and record_prefix(line):
                answer_owner(parse_record(line), pump, args.owner_approve, args.owner_refuse)
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
            # The harness's timeout bounds the whole boot; one request (a
            # reclaim under emulation) may take much of it.
            session = envoy.Session(envoy_path, connect_timeout=args.timeout, timeout=args.timeout)
            if args.display and script.run.__code__.co_argcount >= 3:
                script.run(session, check, Screen(qmp_path, lines, proc, 1024, 768))
            else:
                script.run(session, check)
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
