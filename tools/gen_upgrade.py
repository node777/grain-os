"""An agent upgrades the system: it asks the owner for the store, uploads the
next generation (only the chunks the disk lacks), and switches to it. The
switch takes effect at the next boot, on trial.

Run by the harness with --agent; GRAIN_NEXT names a `grain-disk pack` directory.
"""
import os

from envoy import upload_generation, verify_attestation


def run(s, check):
    granted = s.ask("tablecloth", reason="upgrade the system to the next generation")
    check("tablecloth_granted", granted.get("granted") is True, granted)
    before = s.call("tablecloth", "info")
    # Measured boot: what booted, signed by this instance with our nonce.
    nonce = os.urandom(32)
    quote = s.call("attest", "quote", nonce=nonce.hex())
    ok, why = verify_attestation(quote, nonce)
    check("attestation_verifies", ok, why)
    check("attestation_names_current_generation", quote["generation"] == before["current"], quote)
    stale, _ = verify_attestation(quote, os.urandom(32))
    check("attestation_bound_to_nonce", not stale, "a quote verified with another nonce")
    gen, sent, total = upload_generation(s, "tablecloth", os.environ["GRAIN_NEXT"])
    check("upload_deduplicated", 0 < sent < total, f"{sent} of {total} chunks sent")
    s.call("tablecloth", "switch_to", generation=gen)
    after = s.call("tablecloth", "info")
    check("generation_staged", after["pending"] == gen and after["current"] == before["current"], after)
    print(f"@agent upgrade generation={gen[:16]} sent={sent} total={total}", flush=True)
    s.bye()
