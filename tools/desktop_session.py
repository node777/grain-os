"""The Phase 6 session: boot to the desktop, open the shell, use it, and read
every visible element back as typed data through Envoy.

Run by the harness with --display (part of `zig build qemu-test`). The agent
holds scene.v1 and nothing that draws; the harness's Screen types and clicks
as the owner would and takes screenshots, so the test can hold the scene
against the pixels: every filled element must show its colour where the
scene says it is topmost, and every line of text must have ink.
"""


def elements(s, window):
    n = s.call("scene", "window", index=window)["elements"]
    return [dict(s.call("scene", "element", window=window, index=i), index=i) for i in range(n)]


def scene_matches_screen(s, screen, check, name):
    """Hold every shown element against a fresh screenshot."""
    w = s.call("scene", "windows")
    img = screen.shot()
    px, py = w["pointer_x"], w["pointer_y"]
    under_pointer = lambda x, y: px <= x < px + 12 and py <= y < py + 18
    bad, checked = [], 0
    for wi in range(w["count"]):
        if not s.call("scene", "window", index=wi)["shown"]:
            continue
        for e in elements(s, wi):
            if e["w"] <= 0 or e["h"] <= 0:
                continue
            if e["kind"] in ("fill", "panel"):
                # A point inside, clear of rounded corners and centred text.
                x, y = e["x"] + max(1, e["w"] // 8), e["y"] + e["h"] // 2
                if e["text"]:
                    x = e["x"] + 4
                top = s.call("scene", "at", x=x, y=y)
                if top != {"window": wi, "element": e["index"]} or under_pointer(x, y):
                    continue
                got = screen.pixel(img, x, y)
                checked += 1
                if got != e["color"]:
                    bad.append((wi, e["index"], e["role"], hex(e["color"]), hex(got)))
            elif e["kind"] == "text" and e["text"].strip():
                # Ink: some pixel inside the text's box differs from the
                # pixel just left of it.
                ground = screen.pixel(img, e["x"] - 1, e["y"] + 9)
                inked = any(screen.pixel(img, x, y) != ground
                            for x in range(e["x"], e["x"] + e["w"], 2) for y in range(e["y"], e["y"] + e["h"], 2))
                checked += 1
                if not inked:
                    bad.append((wi, e["index"], e["role"], e["text"], "no ink"))
    check(name, not bad and checked > 3, f"{checked} checked, mismatches: {bad}")
    return img


def window_of(s, owner):
    count = s.call("scene", "windows")["count"]
    return next((i for i in range(1, count) if s.call("scene", "window", index=i)["owner"] == owner), -1)


def run(s, check, screen):
    screen.wait("surf_ready", timeout=120)
    screen.wait("shell_ready", timeout=120)
    screen.wait("kumara_ready", timeout=120)
    hello = s.hello()

    caps = {c["name"]: c for c in s.discover()}
    check("scene_granted", caps["scene"]["granted"] and caps["scene"]["protocol"] == "scene.v1", caps.get("scene"))
    w = s.call("scene", "windows")
    check("desktop_up", w["width"] == 1024 and w["height"] == 768 and w["count"] == 3, w)
    sw = window_of(s, "shell")
    check("apps_have_windows", sw > 0 and window_of(s, "tasks") > 0, w)
    shell_win = s.call("scene", "window", index=sw)
    check("shell_waits_in_dock", shell_win["owner"] == "shell" and not shell_win["shown"], shell_win)
    launcher = next((e for e in elements(s, 0) if e["role"] == "launcher" and e["text"] == "shell"), None)
    check("launcher_in_scene", launcher is not None and launcher["id"] != 0, launcher)
    scene_matches_screen(s, screen, check, "desktop_matches_scene")

    # Open the shell from the dock, as the owner would.
    m = screen.mark()
    screen.click(launcher["x"] + launcher["w"] // 2, launcher["y"] + launcher["h"] // 2)
    screen.wait("surf_window_shown title=shell", after=m)
    w = s.call("scene", "windows")
    check("shell_opened", s.call("scene", "window", index=sw)["shown"] and w["focused"] == sw, w)

    # Ask it who this instance is.
    m = screen.mark()
    screen.type("whoami\n")
    screen.wait("shell_ran command=whoami ok=true", after=m)
    screen.wait("surf_presented owner=shell", after=m)
    lines = [e for e in elements(s, sw) if e["kind"] == "text"]
    answers = [e["text"] for e in lines if e["role"] == "answer"]
    check("whoami_on_screen", hello["identity"] in answers and any(e["text"] == "> whoami" and e["role"] == "command" for e in lines),
          (hello["identity"], answers))
    img = scene_matches_screen(s, screen, check, "shell_matches_scene")

    # The window's frame and title are where the scene says.
    frame = s.call("scene", "window", index=sw)
    check("frame_where_scene_says", screen.pixel(img, frame["x"] + frame["w"] // 2, frame["y"] + 2) in (0xfaf4ea, 0xf3ece2),
          hex(screen.pixel(img, frame["x"] + frame["w"] // 2, frame["y"] + 2)))

    # Surf's frame: drag the window by its title bar, then resize it from
    # the corner; the shell lays itself out again for its new size.
    m = screen.mark()
    screen.drag(frame["x"] + 60, frame["y"] + 12, frame["x"] + 140, frame["y"] + 52)
    screen.wait("surf_window_moved owner=shell", after=m)
    moved = s.call("scene", "window", index=sw)
    check("window_dragged", moved["x"] == frame["x"] + 80 and moved["y"] == frame["y"] + 40, (frame, moved))
    m = screen.mark()
    screen.drag(moved["x"] + moved["w"] - 5, moved["y"] + moved["h"] - 5, moved["x"] + moved["w"] + 55, moved["y"] + moved["h"] + 25)
    screen.wait("surf_window_resized owner=shell", after=m)
    screen.wait("surf_presented owner=shell", after=m)
    grown = s.call("scene", "window", index=sw)
    prompt = next(e for e in elements(s, sw) if e["role"] == "prompt")
    check("window_resized", grown["w"] == moved["w"] + 60 and grown["h"] == moved["h"] + 30
          and prompt["y"] > grown["y"] + grown["h"] - 60, (moved, grown, prompt))
    scene_matches_screen(s, screen, check, "resized_matches_scene")

    # Clicking an element reaches the application: clear the page.
    clear = next(e for e in elements(s, sw) if e["role"] == "button" and e["text"] == "clear")
    m = screen.mark()
    screen.click(clear["x"] + clear["w"] // 2, clear["y"] + clear["h"] // 2)
    screen.wait("surf_presented owner=shell", after=m)
    left = [e for e in elements(s, sw) if e["role"] in ("answer", "command")]
    check("click_reaches_app", not left, left)

    # The launcher puts the window away again.
    m = screen.mark()
    screen.click(launcher["x"] + launcher["w"] // 2, launcher["y"] + launcher["h"] // 2)
    screen.wait("surf_window_hidden title=shell", after=m)
    check("shell_put_away", not s.call("scene", "window", index=sw)["shown"])
    scene_matches_screen(s, screen, check, "desktop_matches_scene_again")
    print(f"@agent desktop identity={hello['identity']}", flush=True)
    s.bye()
