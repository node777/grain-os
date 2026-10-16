"""An agent upgrades the system: it asks the owner for the store, uploads the
next generation (only the chunks the disk lacks), and switches to it. The
switch takes effect at the next boot, on trial.

Run by the harness with --agent; GRAIN_NEXT names a `grain-disk pack` directory.
"""
import os

from envoy import upload_generation


def run(s, check):
    granted = s.ask("tablecloth", reason="upgrade the system to the next generation")
    check("tablecloth_granted", granted.get("granted") is True, granted)
    before = s.call("tablecloth", "info")
    gen, sent, total = upload_generation(s, "tablecloth", os.environ["GRAIN_NEXT"])
    check("upload_deduplicated", 0 < sent < total, f"{sent} of {total} chunks sent")
    s.call("tablecloth", "switch_to", generation=gen)
    after = s.call("tablecloth", "info")
    check("generation_staged", after["pending"] == gen and after["current"] == before["current"], after)
    print(f"@agent upgrade generation={gen[:16]} sent={sent} total={total}", flush=True)
    s.bye()
