#!/usr/bin/env python3
"""Boot two Grain instances on one network link and run a scenario across
both: what Comlink is for, two people's machines meeting.

Each instance gets its own disk, entropy, console (the passphrase is typed
on it) and Envoy socket; their network devices are joined by a pair of
Unix datagram sockets, so frames go only between them and nothing touches
the host's network. The scenario is a Python file with

    def run(a, b, check): ...

where `a` and `b` are Instances: `a.session()` is an Envoy session (the
agent on that instance), `a.wait(record)` blocks until that instance prints
a matching record, and `check(name, ok, detail)` reports like the harness.

    python3 tools/pair.py --scenario tools/comlink_session.py \\
        --disk-a A.img --disk-b B.img --rng-a A.bin --rng-b B.bin zig-out/bin/caravan
"""
import argparse
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import envoy  # noqa: E402
from harness import QEMU_RISCV64, ConsolePump, answer_owner, matches, parse_record, record_prefix  # noqa: E402


class Instance:
    def __init__(self, name, kernel, tmpdir, disk, rng, mac, here, there, passphrase, smp, realtime, nic="virtio"):
        self.name = name
        self.tmpdir = tmpdir
        self.envoy_path = os.path.join(tmpdir, f"envoy-{name}.sock")
        console_sock = os.path.join(tmpdir, f"console-{name}.sock")
        self.console_path = os.path.join(tmpdir, f"console-{name}.txt")
        self.disk = os.path.join(tmpdir, f"disk-{name}.img")
        shutil.copyfile(disk, self.disk)
        qemu = list(QEMU_RISCV64)
        if realtime:
            i = qemu.index("-icount")
            del qemu[i:i + 2]
        self.cmd = qemu + ["-smp", smp, "-global", "virtio-mmio.force-legacy=false",
                           "-object", f"rng-random,id=rng0,filename={rng}", "-device", "virtio-rng-device,rng=rng0",
                           "-drive", f"file={self.disk},format=raw,if=none,id=disk0,cache=writeback",
                           "-device", "virtio-blk-device,drive=disk0",
                           "-device", "virtio-serial-device,id=vser0",
                           "-chardev", f"socket,id=con0,path={console_sock},server=on,wait=on",
                           "-device", "virtconsole,chardev=con0,bus=vser0.0",
                           "-device", "virtio-serial-device,id=vser1",
                           "-chardev", f"socket,id=envoy0,path={self.envoy_path},server=on,wait=off",
                           "-device", "virtconsole,chardev=envoy0,bus=vser1.0",
                           "-netdev", f"dgram,id=net0,local.type=unix,local.path={here},remote.type=unix,remote.path={there}",
                           "-device", f"{'e1000' if nic == 'e1000' else 'virtio-net-device'},netdev=net0,mac={mac}",
                           "-kernel", kernel]
        self.pump = ConsolePump(console_sock, self.console_path)
        self.passphrase = passphrase
        self.lines = []
        self.proc = None
        self._session = None

    def start(self):
        self.proc = subprocess.Popen(self.cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        threading.Thread(target=self._read, daemon=True).start()
        self.pump.start(self.proc)
        for _ in range(2):  # a new disk asks twice
            self.pump.send(self.passphrase + "\n")

    def _read(self):
        for raw in self.proc.stdout:
            line = raw.decode("utf-8", "replace").rstrip("\r\n")
            self.lines.append(line)
            if record_prefix(line):
                print(f"{self.name}| {line}", flush=True)
                # The owner of each instance says yes to whatever its agent asks for.
                rec = parse_record(line)
                if rec and rec.get("event") == "owner_asked":
                    answer_owner(rec, self.pump, [rec.get("service")], [])

    def session(self):
        if self._session is None:
            self._session = envoy.Session(self.envoy_path, connect_timeout=120)
        return self._session

    def mark(self):
        return len(self.lines)

    def wait(self, expectation, timeout=120.0, after=0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            for i in range(after, len(self.lines)):
                rec = parse_record(self.lines[i]) if record_prefix(self.lines[i]) else None
                if rec and matches(rec, expectation):
                    return rec
            if self.proc.poll() is not None:
                break
            time.sleep(0.02)
        raise TimeoutError(f"{self.name}: no record {expectation!r}")

    def finish(self, timeout):
        try:
            return self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
            return 124


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("kernel")
    ap.add_argument("--scenario", required=True)
    ap.add_argument("--disk-a", required=True)
    ap.add_argument("--disk-b", required=True)
    ap.add_argument("--rng-a", required=True)
    ap.add_argument("--rng-b", required=True)
    ap.add_argument("--passphrase", default="open sesame")
    ap.add_argument("--smp", default="2")
    ap.add_argument("--timeout", type=float, default=300.0)
    ap.add_argument("--realtime", action="store_true", help="no -icount (leases expire by the clock)")
    ap.add_argument("--nic-a", choices=["virtio", "e1000"], default="virtio", help="instance a's network card")
    ap.add_argument("--nic-b", choices=["virtio", "e1000"], default="virtio", help="instance b's network card")
    args = ap.parse_args()

    tmpdir = tempfile.mkdtemp(prefix="grain-pair-")
    link_a, link_b = os.path.join(tmpdir, "link-a.sock"), os.path.join(tmpdir, "link-b.sock")
    a = Instance("a", args.kernel, tmpdir, args.disk_a, args.rng_a, "52:54:00:00:00:0a", link_a, link_b, args.passphrase, args.smp, args.realtime, args.nic_a)
    b = Instance("b", args.kernel, tmpdir, args.disk_b, args.rng_b, "52:54:00:00:00:0b", link_b, link_a, args.passphrase, args.smp, args.realtime, args.nic_b)

    failures = []

    def check(name, ok, detail=""):
        print(f"@pair check name={name} result={'pass' if ok else 'fail'}"
              + ("" if ok else f" detail={json.dumps(str(detail))}"), flush=True)
        if not ok:
            failures.append(name)

    spec = importlib.util.spec_from_file_location("scenario", args.scenario)
    scenario = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(scenario)
    status = 0
    try:
        a.start()
        b.start()
        scenario.run(a, b, check)
    except Exception as e:  # report and fail, don't hang
        print(f"@pair error={type(e).__name__} detail={json.dumps(str(e))}", flush=True)
        failures.append("exception")
    finally:
        for inst in (a, b):
            st = inst.finish(args.timeout) if not failures else (inst.proc.kill() or inst.finish(5))
            if st not in (0, None) and not failures:
                print(f"pair: instance {inst.name} exited with {st}", file=sys.stderr)
                status = status or st
    shutil.rmtree(tmpdir, ignore_errors=True)
    if failures:
        print(f"pair: checks failed: {', '.join(failures)}", file=sys.stderr)
        status = status or 1
    return status


if __name__ == "__main__":
    sys.exit(main())
