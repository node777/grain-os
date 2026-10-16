"""An agent rolls the system back to the generation it ran before the last
switch. Like an upgrade, the rollback boots on trial.
"""


def run(s, check):
    granted = s.ask("tablecloth", reason="roll the system back")
    check("tablecloth_granted", granted.get("granted") is True, granted)
    before = s.call("tablecloth", "info")
    r = s.call("tablecloth", "rollback")
    after = s.call("tablecloth", "info")
    check("rollback_staged", r["generation"] == before["previous"] and after["pending"] == before["previous"], after)
    print(f"@agent rollback generation={r['generation'][:16]}", flush=True)
    s.bye()
