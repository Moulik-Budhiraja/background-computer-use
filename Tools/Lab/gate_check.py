#!/usr/bin/env python3
"""Front-gate check, for a macOS version the gate hasn't run on yet.

The gate (Sources/BCUCore/FrontGate.swift) uses LaunchServices calls that
aren't public, checked on macOS 15.7. On another version, run both parts
before trusting it. Each takes under a minute, uses the screen (a test app
and a Finder window open, a few clicks and one cmd+Tab are played), and
never leaves a list in place.

  gate_check.py probe OUT    macOS alone, no engine: is the list of apps permitted in
                             front honored, and does clearing it permit everyone again
  gate_check.py engine OUT   with this build's engine running (the app, or `bcu serve`):
                             the gate arms, the user can still click and cmd+Tab into the
                             agent's app, and the helper clears the list when the engine dies
                             (this part kills the engine: start it again afterwards)

One line per check: PASS, FAIL, or INFO for what's only reported. Also writes
OUT/results-probe.json or OUT/results-engine.json. Build the lab first
(Tools/Lab/build.sh); the shell needs Accessibility and Screen Recording.
"""
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run as lab  # noqa: E402

results = []


def note(kind, name, detail=""):
    results.append({"kind": kind, "name": name, "detail": detail})
    print("%-4s %-58s %s" % (kind, name, detail), flush=True)


def check(name, ok, detail=""):
    note("PASS" if ok else "FAIL", name, detail)
    return ok


def L(*a):
    r = subprocess.run([lab.LAB] + [str(x) for x in a], capture_output=True, text=True)
    return (r.stdout + r.stderr).strip()


def front():
    try:
        return json.loads(L("snapshot"))["front"]
    except Exception as e:  # noqa: BLE001
        return {"name": "?", "pid": 0, "error": str(e)}


def pid_of(name):
    out = subprocess.run(["pgrep", "-x", name], capture_output=True, text=True).stdout.split()
    return int(out[0]) if out else 0


def came_front(pid, seconds=1.6):
    """Did `pid` become the front app at any sample in the next `seconds`? (ms until it did, or None)"""
    t0 = time.time()
    while time.time() - t0 < seconds:
        if front().get("pid") == pid:
            return int((time.time() - t0) * 1000)
        time.sleep(0.03)
    return None


def put_front(pid, name):
    """Put an app back in front (a request on its behalf), and wait until it is."""
    for _ in range(4):
        L("prim", "set-front", "--pid", pid)
        for _ in range(30):
            if front().get("pid") == pid:
                return True
            time.sleep(0.05)
        subprocess.run(["open", "-a", name], capture_output=True)
        time.sleep(0.5)
    return front().get("pid") == pid


def finder_point():
    """A point where a Finder window (or the bare desktop, which is Finder's) is what a click would hit."""
    snap = json.loads(L("snapshot"))
    for w in snap.get("user_stack", []):
        if w.get("owner") != "Finder":
            continue
        bx, by, bw, bh = (w["bounds"][k] for k in ("x", "y", "w", "h"))
        if bw < 200 or bh < 100:
            continue
        for f in (0.5, 0.25, 0.75, 0.12, 0.88):
            x, y = int(bx + bw * f), int(by + 12)
            top = L("prim", "at", "--at", "%d,%d" % (x, y)).splitlines()
            if top and top[0].split()[0] == str(w["id"]):
                return x, y, "Finder window %d %r" % (w["id"], w.get("title", ""))
    d = [x for x in snap["displays"] if not x["agent"]][0]["bounds"]
    x, y = int(d["x"] + 40), int(d["y"] + d["h"] - 260)
    top = L("prim", "at", "--at", "%d,%d" % (x, y)).splitlines()
    return x, y, "desktop (%s)" % (top[0][:60] if top else "nothing under it")


def open_finder_window():
    """A Finder window on the user's screen, opened without bringing Finder forward."""
    subprocess.run(["open", "-g", os.path.expanduser("~")], capture_output=True)
    time.sleep(1.5)


def click_finder():
    x, y, what = finder_point()
    L("mouse", "--to", "%d,%d" % (x, y), "--ms", 120, "--click")
    return what


def denials():
    r = subprocess.run(["sudo", "-n", "/usr/bin/log", "show", "--last", "3m", "--info", "--debug", "--predicate",
                        'process == "WindowServer" AND eventMessage CONTAINS[c] "the right to be in front"'],
                       capture_output=True, text=True)
    lines = [x for x in r.stdout.splitlines() if "right to be in front" in x]
    return lines


def setup_user(out):
    ready = lab.start_fixture(out)
    time.sleep(1.0)
    fx, fy, fw, fh = ready["windows"][0]["frame"]
    return ready["pid"], (fx, fy, fw, fh)


def probe(out):
    os.makedirs(out, exist_ok=True)
    note("INFO", "macOS", subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip())
    show = L("permit", "show")
    if "symbols missing" in show:
        note("INFO", "LaunchServices calls", "MISSING: the gate is off on this macOS, apps are put back after the fact")
        return
    check("LaunchServices calls exist", True, show)
    user, (fx, fy, fw, fh) = setup_user(out)
    finder = pid_of("Finder")
    open_finder_window()
    check("the user's app is in front to begin with", put_front(user, "BCU Fixture"), str(front()))
    if not finder:
        note("FAIL", "Finder is running", "no pid")
        return

    def activate():
        r = subprocess.run(["osascript", "-e", 'tell application "Finder" to activate'], capture_output=True, text=True)
        return "" if r.returncode == 0 else " (osascript: %s)" % r.stderr.strip()[:80]

    # --- Finder off the list: its own request to come forward
    note("INFO", "permit exclude Finder", L("permit", "exclude", "--pid", finder))
    note("INFO", "permit show", L("permit", "show"))
    err = activate()
    t = came_front(finder)
    check("list on: Finder's own activate (Apple event) is refused", t is None, "front after: %s%s%s" % (front().get("name"), "" if t is None else " (Finder in front after %d ms)" % t, err))
    put_front(user, "BCU Fixture")

    # --- cleared: everyone is permitted again
    note("INFO", "permit clear", L("permit", "clear"))
    show = L("permit", "show")
    check("cleared list reads back as no list", show.startswith("no list"), show)
    err = activate()
    t = came_front(finder, 3)
    check("list cleared: Finder's own activate goes through", t is not None, "after %s ms%s" % (t, err))
    check("list cleared: the user's app can be put back", put_front(user, "BCU Fixture"), str(front()))

    # --- on again: what else the list refuses (with no engine to open the gate for the user)
    note("INFO", "permit exclude Finder", L("permit", "exclude", "--pid", finder))
    subprocess.run(["open", "-a", "Finder"], capture_output=True)
    t = came_front(finder)
    note("INFO", "list on: `open -a Finder`", "refused" if t is None else "Finder in front after %d ms" % t)
    put_front(user, "BCU Fixture")

    what = click_finder()
    t = came_front(finder)
    note("INFO", "list on: the user's click on Finder", ("refused" if t is None else "Finder in front after %d ms" % t) + "; clicked " + what)
    put_front(user, "BCU Fixture")

    r = L("cmdtab")
    note("INFO", "list on: cmd+Tab", r)
    put_front(user, "BCU Fixture")

    L("prim", "set-front", "--pid", finder)
    t = came_front(finder)
    note("INFO", "list on: another process's set-front for Finder", "refused" if t is None else "Finder in front after %d ms" % t)
    put_front(user, "BCU Fixture")

    note("INFO", "permit clear", L("permit", "clear"))
    what = click_finder()
    t = came_front(finder, 3)
    check("list cleared: the user's click on Finder brings it forward", t is not None, "after %s ms; clicked %s" % (t, what))
    put_front(user, "BCU Fixture")
    subprocess.run(["kill", str(user)])


def engine(out):
    os.makedirs(out, exist_ok=True)
    if not os.path.exists(lab.SOCK):
        note("FAIL", "engine socket", "none at " + lab.SOCK)
        return
    user, (fx, fy, fw, fh) = setup_user(out)
    open_finder_window()
    put_front(user, "BCU Fixture")
    finder = pid_of("Finder")
    c = lab.Client("gate-check-%d" % int(time.time()))
    ok, text = c.call("open_window", app="Finder")
    wid = lab.window_id(text)
    check("agent opened a Finder window", bool(wid), text[:160].replace("\n", " "))
    if not wid:
        return
    time.sleep(1.5)
    check("the user's app is still in front after the agent's window opened", front().get("pid") == user, str(front()))
    show = L("permit", "show")
    armed = "not permitted" in show and "Finder" in show
    check("gate armed: Finder is off the permitted list", armed, show[:200])

    # The user switches into the app the agent works in: a click on the desktop (Finder's).
    what = click_finder()
    t = came_front(finder, 3)
    check("gate armed: the user's click on Finder still brings it forward", t is not None, "after %s ms; clicked %s; gate: %s" % (t, what, L("permit", "show")[:80]))
    # ...and back to their own app, by a click on its title bar.
    L("mouse", "--to", "%d,%d" % (fx + fw / 2, fy + 14), "--ms", 120, "--click")
    t = came_front(user, 3)
    check("a click on their own window brings their app back", t is not None, "after %s ms" % t)
    if t is None:
        put_front(user, "BCU Fixture")
    time.sleep(2.5)
    show = L("permit", "show")
    check("gate armed again 2.5 s after the user's clicks", "not permitted" in show and "Finder" in show, show[:160])

    # cmd+Tab goes to the app used before: Finder.
    r = L("cmdtab")
    check("gate armed: cmd+Tab still switches app", front().get("pid") != user, r)
    L("mouse", "--to", "%d,%d" % (fx + fw / 2, fy + 14), "--ms", 120, "--click")
    came_front(user, 3) or put_front(user, "BCU Fixture")
    time.sleep(2.5)

    # An agent step that makes Finder want the front: a second window.
    ok, text2 = c.call("open_window", app="Finder")
    wid2 = lab.window_id(text2)
    t = came_front(finder, 1.5)
    check("a second Finder window opens without Finder taking the front", t is None and bool(wid2), "front: %s; %s" % (front().get("name"), text2[:100].replace("\n", " ")))

    # The engine dies with the gate armed: the watchdog must clear the list.
    show = L("permit", "show")
    serve = (subprocess.run(["pgrep", "-f", "bcu serve"], capture_output=True, text=True).stdout.split()
             or subprocess.run(["pgrep", "-x", "BackgroundComputerUse"], capture_output=True, text=True).stdout.split())
    note("INFO", "before killing the engine", "gate: %s | engine pids %s" % (show[:100], serve))
    if "not permitted" in show and serve:
        subprocess.run(["kill", "-9", serve[0]])
        t0 = time.time()
        cleared = None
        while time.time() - t0 < 6:
            if L("permit", "show").startswith("no list"):
                cleared = int((time.time() - t0) * 1000)
                break
            time.sleep(0.05)
        check("engine killed with the gate armed: the watchdog clears the list", cleared is not None, "after %s ms" % cleared)
        if cleared is None:
            L("permit", "clear")
    else:
        note("INFO", "watchdog check skipped", "gate wasn't armed")
    subprocess.run(["kill", str(user)])


if __name__ == "__main__":
    mode, out = sys.argv[1], sys.argv[2]
    try:
        {"probe": probe, "engine": engine}[mode](out)
    finally:
        # Never leave a list behind on the machine.
        print("final:", L("permit", "clear"), "|", L("permit", "show"), flush=True)
        json.dump(results, open(os.path.join(out, "results-%s.json" % mode), "w"), indent=1)
    sys.exit(1 if any(r["kind"] == "FAIL" for r in results) else 0)
