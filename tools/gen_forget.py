"""An agent lets the generation it no longer needs go, and brings the space
back: the chunks only that generation used are dropped, and the one that is
running still boots (the harness boots once more to prove it).
"""


def run(s, check):
    granted = s.ask("tablecloth", reason="free the space of the old generation")
    check("tablecloth_granted", granted.get("granted") is True, granted)
    before = s.call("tablecloth", "info")
    s.call("tablecloth", "forget", generation=before["previous"])
    r = s.call("tablecloth", "reclaim", budget=1 << 20)
    after = s.call("tablecloth", "info")
    check("generation_forgotten", after["previous"] == "0" * 64, after)
    check("space_reclaimed", r["dropped"] > 0 and after["free"] > before["free"]
          and after["objects"] < before["objects"], (before, r, after))
    print(f"@agent reclaim dropped={r['dropped']} copied={r['copied']} free={r['free']}", flush=True)
    s.bye()
