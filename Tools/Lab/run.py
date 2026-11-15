#!/usr/bin/env python3
"""Invisibility lab: does an agent at work stay invisible to the user?

Plays a user (typing steadily into an app of their own, the pointer resting
on something with a hover effect) while scripted agents work through the
running Background Computer Use engine, and measures from outside the engine
what the user would have seen and felt:

  menu bar      frames of the menu bar that differ from how it looked before
  window        frames of the user's title bar and of its shadow that differ
  hover         times the pointer "left" the tile it was resting on
  typing        how long each key took to arrive, and whether all arrived in order
  front app     every moment another app was the front app
  windows       another window on top of the user's, windows that appeared on
                their screen
  cursor        every time the pointer moved (the user never moves it)

  run.py scenario --agents 2 --rounds 1 --out DIR [--kinds helium,finder] [--user fixture|helium]
  run.py summarize DIR

Build first: Tools/Lab/build.sh. Needs the engine running (the app, or
`bcu serve`). Python 3.9 is enough.
"""

import argparse
import http.server
import json
import os
import re
import signal
import socket
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
LAB = os.path.join(ROOT, "build", "lab", "lab")
FIXTURE_APP = os.path.join(ROOT, "build", "lab", "BCU Fixture.app")
SUPPORT = os.environ.get("BCU_HOME") or os.path.expanduser("~/Library/Application Support/BackgroundComputerUse")
SOCK = os.path.join(SUPPORT, "bcu.sock")
LOG = os.path.join(SUPPORT, "logs", "bcu.log")

PARAGRAPH = ("the quick brown fox jumps over the lazy dog near the river bank. "
             "a small boat drifts past the old mill while children play on the grass. ")

FIXTURE_FRAME = (240, 140, 900, 620)
HELIUM_BIN = "/Applications/Helium.app/Contents/MacOS/Helium"


def uptime_ms():
    return time.clock_gettime(time.CLOCK_UPTIME_RAW) * 1000


def say(msg):
    sys.stderr.write("[lab %s] %s\n" % (time.strftime("%H:%M:%S"), msg))
    sys.stderr.flush()


class Client:
    """One agent session's connection to the engine (the `bcu call` protocol)."""

    def __init__(self, session):
        self.session = session
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.connect(SOCK)
        self.file = self.sock.makefile("rb")
        self.n = 0
        self.calls = []

    def call(self, tool, **args):
        self.n += 1
        args["_session"] = self.session
        t0 = uptime_ms()
        self.sock.sendall((json.dumps({"id": self.n, "tool": tool, "args": args}) + "\n").encode())
        line = self.file.readline()
        t1 = uptime_ms()
        r = json.loads(line) if line else {"ok": False, "error": "connection closed"}
        text = r.get("text") or r.get("error") or ""
        self.calls.append({"session": self.session, "tool": tool, "t0": t0, "t1": t1, "ok": bool(r.get("ok")),
                           "first": text.split("\n")[0][:200],
                           "guard": [l for l in text.split("\n") if l.startswith("[focus guard]")],
                           "notes": [l for l in text.split("\n") if l.startswith("[user first]") or l.startswith("[other agents]")]})
        return bool(r.get("ok")), text

    def close(self):
        # shutdown first: the file made from the socket keeps it open
        # otherwise, and the engine never learns the agent went away.
        for step in (lambda: self.sock.shutdown(socket.SHUT_RDWR), self.file.close, self.sock.close):
            try:
                step()
            except OSError:
                pass


# ------------------------------------------------------------------ web pages

class Pages(http.server.SimpleHTTPRequestHandler):
    """Serves the lab's pages and writes down what the user page reports."""
    log_path = None

    def __init__(self, *a, **kw):
        super().__init__(*a, directory=os.path.join(HERE, "www"), **kw)

    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n)
        now = uptime_ms()
        try:
            events = json.loads(body)
        except ValueError:
            events = []
        if Pages.log_path:
            with open(Pages.log_path, "a") as f:
                for e in events:
                    e["server_t"] = now
                    e["server_wall"] = time.time() * 1000
                    f.write(json.dumps(e) + "\n")
        self.send_response(204)
        self.end_headers()


def serve_pages(out_dir):
    Pages.log_path = os.path.join(out_dir, "page.jsonl")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Pages)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, "http://127.0.0.1:%d" % server.server_address[1]


# ------------------------------------------------------------------ the user

def lab(*args, **kw):
    return subprocess.run([LAB] + [str(a) for a in args], capture_output=True, text=True, **kw)


def snapshot():
    return json.loads(lab("snapshot").stdout)


def read_jsonl(path):
    out = []
    if not os.path.exists(path):
        return out
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
    return out


def start_fixture(out_dir, frame=FIXTURE_FRAME):
    log = os.path.join(out_dir, "fixture.jsonl")
    if os.path.exists(log):
        os.remove(log)
    subprocess.run(["open", "-n", FIXTURE_APP, "--args", "--log", log, "--frame", ",".join(str(v) for v in frame)], check=True)
    deadline = time.time() + 15
    while time.time() < deadline:
        for e in read_jsonl(log):
            if e.get("ev") == "ready":
                return e
        time.sleep(0.1)
    raise SystemExit("the fixture app didn't start")


def start_browser_user(base, frame=FIXTURE_FRAME):
    """The user in a browser window of their own: the lab's user page, its text area focused."""
    subprocess.run([HELIUM_BIN, "--new-window", base + "/user.html"], capture_output=True)
    deadline = time.time() + 15
    win = None
    while time.time() < deadline and not win:
        time.sleep(0.3)
        win = next((w for w in snapshot()["user_stack"] if "Lab user page" in w["title"]), None)
    if not win:
        raise SystemExit("the user's browser window didn't open")
    placed = lab("prim", "ax-frame", "--pid", win["pid"], "--wid", win["id"], "--frame", ",".join(str(v) for v in frame)).stdout.strip()
    if "frame set" not in placed:
        raise SystemExit("couldn't place the user's browser window: " + placed)
    time.sleep(0.8)
    # The page says where its text area and hover tile are on screen.
    rects = [e for e in read_jsonl(Pages.log_path) if e.get("ev") == "rects"]
    if not rects:
        raise SystemExit("the user page didn't report where its fields are")
    nx, ny, nw, nh = rects[-1]["notes"]
    tx, ty, tw, th = rects[-1]["tile"]
    # Into the text area, then rest the pointer on the hover tile.
    lab("mouse", "--to", "%d,%d" % (nx + nw / 2, ny + nh / 2), "--ms", "200", "--click")
    time.sleep(0.3)
    lab("mouse", "--to", "%d,%d" % (tx + tw / 2, ty + th / 2), "--ms", "200")
    time.sleep(0.4)
    return {"pid": win["pid"], "windows": [{"num": win["id"], "frame": list(frame), "title": win["title"]}], "browser": True}


# ------------------------------------------------------------------ agents

def element(state, pattern):
    m = re.search(r"\[(\d+)\] " + pattern, state)
    return int(m.group(1)) if m else None


def window_id(text):
    m = re.search(r"Opened window (\d+)", text)
    return int(m.group(1)) if m else None


def patient(c, tool, **args):
    """Call, and when the step was refused because the user is typing in the
    same app, try again a little later, as an agent told to would."""
    for _ in range(4):
        ok, text = c.call(tool, **args)
        if ok or "their typing goes first" not in text:
            break
        time.sleep(2)
    return ok, text


def agent_helium(c, base, rounds):
    """A browser task: open, load, read, press, type, Return, scroll, a batch, a pixel click."""
    ok, text = patient(c, "open_window", app="Helium")
    wid = window_id(text)
    if not wid:
        return
    try:
        for _ in range(rounds):
            ok, text = patient(c, "navigate", window_id=wid, url=base + "/agent.html")
            if not ok:
                # No Automation permission: the address bar, like an agent would.
                c.call("press_key", window_id=wid, key="l", modifiers=["cmd"])
                c.call("type_text", window_id=wid, text=base + "/agent.html\n")
            ok, state = c.call("get_window_state", window_id=wid, full=True, screenshot=False)
            button = element(state, r'Button "Increment"')
            field = element(state, r'TextField "Agent field"')
            if button is not None:
                c.call("click", window_id=wid, element=button)
            if field is not None:
                c.call("type_text", window_id=wid, element=field, text="hello from agent")
            patient(c, "press_key", window_id=wid, key="return")
            c.call("scroll", window_id=wid, dy=10)
            if button is not None and field is not None:
                patient(c, "batch", window_id=wid, actions=[
                    {"tool": "click", "element": button},
                    {"tool": "type_text", "element": field, "text": "second"},
                    {"tool": "press_key", "key": "return"},
                    {"tool": "scroll", "dy": -10}])
            patient(c, "click", window_id=wid, x=400, y=300)
            c.call("get_window_state", window_id=wid, screenshot=True)
    finally:
        c.call("release_window", window_id=wid)


def agent_finder(c, base, rounds):
    """A Finder task: open a window, read it, move the selection, scroll."""
    ok, text = c.call("open_window", app="Finder")
    wid = window_id(text)
    if not wid:
        return
    try:
        for _ in range(rounds):
            c.call("get_window_state", window_id=wid, screenshot=False)
            c.call("press_key", window_id=wid, key="down")
            c.call("press_key", window_id=wid, key="down")
            c.call("scroll", window_id=wid, dy=5)
            c.call("get_window_state", window_id=wid, screenshot=True)
    finally:
        c.call("release_window", window_id=wid)


def agent_textedit(c, base, rounds):
    """A TextEdit task that changes nothing: open, read, move the caret."""
    ok, text = c.call("open_window", app="TextEdit")
    wid = window_id(text)
    if not wid:
        return
    try:
        for _ in range(rounds):
            c.call("get_window_state", window_id=wid, screenshot=False)
            c.call("press_key", window_id=wid, key="right")
            c.call("click", window_id=wid, x=200, y=200)
            c.call("get_window_state", window_id=wid, screenshot=True)
    finally:
        c.call("release_window", window_id=wid)


AGENTS = {"helium": agent_helium, "finder": agent_finder, "textedit": agent_textedit}


# ------------------------------------------------------------------ scenario

def gate_busy():
    marker = os.path.expanduser("~/bcu-gate/IN-USE")
    running = subprocess.run(["pgrep", "-f", "gate.py run"], capture_output=True, text=True).stdout.strip()
    return os.path.exists(marker) or bool(running)


def scenario(args):
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    if gate_busy() and not args.force:
        raise SystemExit("another test run (~/bcu-gate) is using this Mac; wait for it or pass --force")
    if not os.path.exists(SOCK):
        raise SystemExit("no engine socket at %s: start the app first" % SOCK)
    for f in ("fixture.jsonl", "page.jsonl", "posts.jsonl", "watch.json", "stop.flag", "calls.json", "bcu.log"):
        p = os.path.join(out, f)
        if os.path.exists(p):
            os.remove(p)
    server, base = serve_pages(out)
    stop_flag = os.path.join(out, "stop.flag")
    log_offset = os.path.getsize(LOG) if os.path.exists(LOG) else 0

    if args.user == "helium":
        ready = start_browser_user(base)
    else:
        ready = start_fixture(out)
    pid = ready["pid"]
    win = ready["windows"][0]
    fx, fy, fw, fh = win["frame"]
    say("user in pid %d window %d at %d,%d %dx%d" % (pid, win["num"], fx, fy, fw, fh))
    if not ready.get("browser"):
        tx, ty, tw, th = ready["tile"]
        time.sleep(0.8)
        # The pointer rests on the hover tile for the whole run.
        lab("mouse", "--to", "%d,%d" % (tx + tw / 2, ty + th / 2), "--ms", "250")
        time.sleep(0.5)

    helium = subprocess.run(["pgrep", "-x", "Helium"], capture_output=True, text=True).stdout.split()
    films = [
        "menubar:0,0,420,24",
        "titlebar:%d,%d,%d,%d" % (fx, fy, fw, 28),
        "shadow:%d,%d,%d,%d" % (fx + 60, fy + fh + 2, fw - 120, 22),
        # The top of whatever is behind the user's window (the title bar or
        # toolbar of another window of theirs, often of the app an agent is in).
        "behind:%d,%d,%d,%d" % (fx + 100, 28, 700, 80),
    ]
    watch_cmd = [LAB, "watch", "--out", os.path.join(out, "watch.json"), "--stop", stop_flag, "--shots", os.path.join(out, "shots"), "--ax", str(pid)]
    for h in helium[:1]:
        watch_cmd += ["--ax", h]
    for f in films:
        watch_cmd += ["--film", f]
    watcher = subprocess.Popen(watch_cmd)
    time.sleep(1.0)

    typist = subprocess.Popen([LAB, "type", "--pid", str(pid), "--text", PARAGRAPH, "--repeat", "400",
                               "--interval", str(args.interval), "--hold", "45", "--jitter", "30",
                               "--burst", str(args.burst), "--pause", str(args.pause), "--spread", str(args.spread), "--seed", str(args.seed),
                               "--out", os.path.join(out, "posts.jsonl"), "--stop", stop_flag])
    # A few quiet seconds first: what typing feels like with no agent at work.
    quiet_from = uptime_ms()
    time.sleep(args.quiet)
    work_from = uptime_ms()

    kinds = [k.strip() for k in args.kinds.split(",") if k.strip()]
    clients, threads = [], []
    for i in range(args.agents):
        kind = kinds[i % len(kinds)]
        c = Client("lab-%s-%d-%d" % (kind, i, int(time.time())))
        clients.append(c)
        t = threading.Thread(target=run_agent, args=(AGENTS[kind], c, base, args.rounds), daemon=True)
        threads.append(t)
    for t in threads:
        t.start()
        time.sleep(args.stagger)
    for t in threads:
        t.join(timeout=args.timeout)
    work_to = uptime_ms()
    time.sleep(1.5)

    open(stop_flag, "w").close()
    try:
        typist.wait(timeout=10)
    except subprocess.TimeoutExpired:
        typist.kill()
    time.sleep(0.5)
    if not ready.get("browser"):
        os.kill(pid, signal.SIGUSR1)
    time.sleep(0.4)
    try:
        watcher.wait(timeout=15)
    except subprocess.TimeoutExpired:
        watcher.kill()
    calls = [call for c in clients for call in c.calls]
    for c in clients:
        c.close()
    json.dump({"calls": calls, "quiet_from": quiet_from, "work_from": work_from, "work_to": work_to, "agents": args.agents,
               "kinds": kinds, "rounds": args.rounds, "fixture": ready, "label": args.label,
               "wall_minus_uptime": time.time() * 1000 - uptime_ms()},
              open(os.path.join(out, "calls.json"), "w"))
    if os.path.exists(LOG):
        with open(LOG, "rb") as f:
            f.seek(log_offset)
            open(os.path.join(out, "bcu.log"), "wb").write(f.read())
    if ready.get("browser"):
        time.sleep(0.5)
        lab("prim", "ax-close", "--pid", pid, "--wid", win["num"])
    else:
        subprocess.run(["kill", str(pid)])
    server.shutdown()
    summary = summarize(out)
    print_summary(summary)
    return summary


def run_agent(fn, client, base, rounds):
    try:
        fn(client, base, rounds)
    except Exception as e:  # noqa: BLE001 - a broken agent run is a result too
        say("agent %s failed: %r" % (client.session, e))


# ------------------------------------------------------------------ scoring

def pct(values, p):
    if not values:
        return None
    s = sorted(values)
    return s[min(len(s) - 1, int(round(p / 100.0 * (len(s) - 1))))]


def summarize(out):
    meta = json.load(open(os.path.join(out, "calls.json")))
    watch = json.load(open(os.path.join(out, "watch.json")))
    fixture = read_jsonl(os.path.join(out, "fixture.jsonl"))
    posts = read_jsonl(os.path.join(out, "posts.jsonl"))
    t0 = watch["t0_uptime_ms"]
    work_from, work_to = meta["work_from"], meta["work_to"]
    ready = meta["fixture"]
    user_pid = ready["pid"]
    user_win = ready["windows"][0]["num"]
    calls = meta["calls"]

    def during(t):
        """Tool calls running at uptime t."""
        return sorted({c["tool"] for c in calls if c["t0"] - 5 <= t <= c["t1"] + 800})

    # Front app: every span with another app in front.
    flips = []
    front = watch["front"]
    for i, e in enumerate(front):
        if e["pid"] == user_pid or i == 0 and e["pid"] == user_pid:
            continue
        end = front[i + 1]["t"] if i + 1 < len(front) else watch["duration_ms"]
        if e["t"] == 0 and e["pid"] != user_pid:
            continue
        flips.append({"t": e["t"] + t0, "ms": end - e["t"], "app": e["name"], "during": during(e["t"] + t0)})

    films = {}
    for f in watch["film"]:
        runs = [r for r in f["runs"]]
        films[f["name"]] = {
            "frames": f["frames"], "max_gap_ms": f["max_gap_ms"], "pixels": f["pixels"],
            "runs": len(runs), "total_ms": sum(r["ms"] for r in runs), "max_ms": max([r["ms"] for r in runs] or [0]),
            "max_px": max([r["max_px"] for r in runs] or [0]),
            "list": [{"t": r["t"] + t0, "ms": r["ms"], "max_px": r["max_px"], "during": during(r["t"] + t0)} for r in runs][:60],
        }

    # What the user's app itself noticed, once the agents were at work.
    def count(ev, **match):
        return sum(1 for e in fixture if e.get("ev") == ev and e["t"] >= work_from and all(e.get(k) == v for k, v in match.items()))
    app_events = {
        "app_inactive": count("app_inactive"), "win_unkey": count("win_unkey"), "win_unmain": count("win_unmain"),
        "hover_exit_always": count("hover_exit", kind="always"),
        "hover_exit_active_app": count("hover_exit", kind="active-app"),
        "hover_exit_key_window": count("hover_exit", kind="key-window"),
        "covered": sum(1 for e in fixture if e.get("ev") == "win_occlusion" and e["t"] >= work_from and not e.get("visible")),
    }

    browser = bool(ready.get("browser"))
    if browser:
        # What the user's page reported, on the uptime clock.
        off = meta.get("wall_minus_uptime", 0)
        # In the page's own order: its reports can reach the server out of order.
        page = sorted(read_jsonl(os.path.join(out, "page.jsonl")), key=lambda e: e.get("perf", 0))
        posts_by_i = [p for p in posts if "ch" in p]
        fixture = []
        n = 0
        for e in page:
            t = e["wall"] - off
            if e["ev"] == "keydown" and not e.get("repeat"):
                sent_t = posts_by_i[n]["t"] if n < len(posts_by_i) else t
                fixture.append({"ev": "keydown", "t": t, "lat": t - sent_t, "ch": e.get("key"), "keywin": user_win, "active": True})
                n += 1
            elif e["ev"] == "hover_exit":
                fixture.append({"ev": "hover_exit", "t": t, "kind": "always"})
            elif e["ev"] == "blur":
                fixture.append({"ev": "win_unkey", "t": t})
            elif e["ev"] == "input":
                fixture.append({"ev": "text_len", "t": t, "len": e.get("len")})
        app_events = {
            "app_inactive": 0, "win_unkey": sum(1 for e in fixture if e["ev"] == "win_unkey" and e["t"] >= work_from), "win_unmain": 0,
            "hover_exit_always": sum(1 for e in fixture if e["ev"] == "hover_exit" and e["t"] >= work_from),
            "hover_exit_active_app": 0, "hover_exit_key_window": 0, "covered": 0,
        }
    # Typing.
    downs = [e for e in fixture if e.get("ev") == "keydown" and not e.get("repeat")]
    sent = [p for p in posts if "ch" in p]
    end_note = next((p.get("end") for p in posts if "end" in p), "?")
    text = next((e.get("text") for e in reversed(fixture) if e.get("ev") == "text"), None)
    if browser:
        text = "".join(e["ch"] for e in downs)
    expected = "".join(p["ch"] for p in sent)
    if not browser and len(downs) == len(sent):
        # From when the typist meant to press the key, not from the event's
        # own timestamp: while macOS is stalled (a display being added) the
        # typist can't even make the event, and a real key pressed then
        # would be stamped on time and wait just the same.
        for e, p in zip(downs, sent):
            e["lat"] = max(e["lat"], e["t"] - p["t"])
    quiet = [e["lat"] for e in downs if e["t"] < work_from]
    busy = [e["lat"] for e in downs if work_from <= e["t"] <= work_to + 1000]

    def lat(values):
        return {"keys": len(values), "p50": pct(values, 50), "p95": pct(values, 95), "p99": pct(values, 99), "max": max(values) if values else None,
                "over_50ms": sum(1 for v in values if v > 50), "over_100ms": sum(1 for v in values if v > 100), "over_250ms": sum(1 for v in values if v > 250)}
    wrong_window = sum(1 for e in downs if e.get("keywin") != user_win or not e.get("active"))
    typing = {"sent": len(sent), "received": len(downs), "text_matches": text == expected if text is not None else None,
              "typist": end_note, "quiet": lat(quiet), "busy": lat(busy), "keys_while_not_key_or_active": wrong_window,
              "front_waits": sum(1 for p in sent if p.get("front_wait", 0) > 0),
              "front_wait_ms": sum(p.get("front_wait", 0) for p in sent)}
    if text is not None and text != expected:
        typing["text_len"] = len(text)
        typing["expected_len"] = len(expected)
        for i, (a, b) in enumerate(zip(text, expected)):
            if a != b:
                typing["first_diff"] = {"at": i, "got": text[max(0, i - 15):i + 15], "want": expected[max(0, i - 15):i + 15]}
                break

    # Windows on the user's screen.
    stack = watch["stack"]
    on_top = []
    for i, e in enumerate(stack):
        top = e["order"][0] if e["order"] else None
        if top is None or top["id"] == user_win:
            continue
        end = stack[i + 1]["t"] if i + 1 < len(stack) else watch["duration_ms"]
        on_top.append({"t": e["t"] + t0, "ms": end - e["t"], "window": top["id"], "owner": top["owner"], "title": top["title"], "during": during(e["t"] + t0)})
    appeared = [{"owner": a["owner"], "title": a["title"], "ms": a["last"] - a["first"], "t": a["first"] + t0, "bounds": a["bounds"],
                 "during": during(a["first"] + t0)} for a in watch["appeared"]]

    cursor = [c for c in watch["cursor"] if c["t"] + t0 >= work_from]
    ax_user = [a for a in watch["ax"] if a["pid"] == user_pid and a["t"] + t0 >= work_from]

    guard = []
    path = os.path.join(out, "bcu.log")
    if os.path.exists(path):
        for line in open(path, errors="replace"):
            if "guard:" in line or "freeze:" in line or "defer:" in line or "swap:" in line or "lease:" in line or "held the user" in line:
                guard.append(line.rstrip()[:260])
    kinds = {
        "activated_agent_caused": sum(1 for l in guard if "activated" in l and "agentCaused=true" in l),
        "restores": sum(1 for l in guard if "guard: restore" in l),
        "held_keys": sum(1 for l in guard if "held" in l and "key events" in l or "replayed" in l),
        "covers": sum(1 for l in guard if "freeze: copies up" in l),
        "gave_key_back": sum(1 for l in guard if "gave key back" in l),
        "moved_back": sum(1 for l in guard if "moved your agent" in l),
        "cursor_back": sum(1 for l in guard if "cursor was" in l),
        "could_not": sum(1 for l in guard if "COULD NOT" in l or "dropped" in l),
    }

    by_tool = {}
    for c in calls:
        b = by_tool.setdefault(c["tool"], {"n": 0, "ms": 0.0, "failed": 0, "guard_notes": 0, "max_ms": 0.0})
        b["n"] += 1
        b["ms"] += c["t1"] - c["t0"]
        b["max_ms"] = max(b["max_ms"], c["t1"] - c["t0"])
        b["failed"] += 0 if c["ok"] else 1
        b["guard_notes"] += 1 if c["guard"] else 0

    summary = {
        "label": meta.get("label"), "agents": meta["agents"], "kinds": meta["kinds"], "rounds": meta["rounds"],
        "work_s": (work_to - work_from) / 1000,
        "front_flips": {"n": len(flips), "total_ms": sum(f["ms"] for f in flips), "max_ms": max([f["ms"] for f in flips] or [0]), "list": flips[:80]},
        "film": films, "user_app": app_events, "typing": typing,
        "on_top": {"n": len(on_top), "total_ms": sum(o["ms"] for o in on_top), "list": on_top[:40]},
        "appeared": appeared[:40],
        "cursor_moves": {"n": len(cursor), "max_jump": max([c["jump"] for c in cursor] or [0]), "on_agent_ms": watch["cursor_on_agent_ms"]},
        "user_key_window_changes": ax_user[:40],
        "displays": watch["displays"],
        "guard_log": kinds, "tools": by_tool,
        "failed_calls": [c for c in calls if not c["ok"]][:20],
    }
    json.dump(summary, open(os.path.join(out, "summary.json"), "w"), indent=1)
    return summary


def print_summary(s):
    def ms(v):
        return "-" if v is None else "%.0f" % v
    print("== %s: %d agent(s) [%s], %.1f s of agent work" % (s.get("label") or "run", s["agents"], ",".join(s["kinds"]), s["work_s"]))
    f = s["front_flips"]
    print("front app   %d times another app was in front, %s ms in all, longest %s ms" % (f["n"], ms(f["total_ms"]), ms(f["max_ms"])))
    for name, film in s["film"].items():
        print("%-11s %d flickers, %s ms in all, longest %s ms, up to %d of %d px (%d frames, longest gap %s ms)" % (
            name, film["runs"], ms(film["total_ms"]), ms(film["max_ms"]), film["max_px"], film["pixels"], film["frames"], ms(film["max_gap_ms"])))
    a = s["user_app"]
    print("user's app  inactive %d, window lost key %d, lost main %d, covered %d" % (a["app_inactive"], a["win_unkey"], a["win_unmain"], a["covered"]))
    print("hover       lost %d (pointer), %d (active-app hover), %d (key-window hover)" % (a["hover_exit_always"], a["hover_exit_active_app"], a["hover_exit_key_window"]))
    t = s["typing"]
    q, b = t["quiet"], t["busy"]
    print("typing      sent %d, received %d, text %s (%s); keys in a window that wasn't key/active: %d; typist waited for the front %d times (%s ms)" % (
        t["sent"], t["received"], {True: "matches", False: "DIFFERS", None: "unread"}[t["text_matches"]], t["typist"], t["keys_while_not_key_or_active"],
        t["front_waits"], ms(t["front_wait_ms"])))
    print("  key delay quiet: p50 %s p95 %s max %s ms (%d keys) | agents working: p50 %s p95 %s p99 %s max %s ms (%d keys; %d >50, %d >100, %d >250 ms)" % (
        ms(q["p50"]), ms(q["p95"]), ms(q["max"]), q["keys"], ms(b["p50"]), ms(b["p95"]), ms(b["p99"]), ms(b["max"]), b["keys"],
        b["over_50ms"], b["over_100ms"], b["over_250ms"]))
    o = s["on_top"]
    print("windows     another window on top of the user's %d times (%s ms); %d windows appeared on their screen" % (o["n"], ms(o["total_ms"]), len(s["appeared"])))
    for w in s["appeared"][:8]:
        print("    appeared: %s \"%s\" for %s ms during %s" % (w["owner"], w["title"], ms(w["ms"]), ",".join(w["during"])))
    c = s["cursor_moves"]
    print("cursor      moved %d times (largest jump %s px), on an agent display %s ms" % (c["n"], ms(c["max_jump"]), ms(c["on_agent_ms"])))
    print("displays    %d arrangement changes" % (len(s["displays"]) - 1))
    print("guard log   %s" % ", ".join("%s %d" % kv for kv in s["guard_log"].items()))
    print("tools       " + "; ".join("%s x%d avg %.0f ms max %.0f%s%s" % (
        k, v["n"], v["ms"] / v["n"], v["max_ms"], (", %d failed" % v["failed"]) if v["failed"] else "",
        (", %d with a focus note" % v["guard_notes"]) if v["guard_notes"] else "") for k, v in sorted(s["tools"].items())))
    causes = {}
    for flip in f["list"]:
        for tool in flip["during"] or ["(no call)"]:
            causes[tool] = causes.get(tool, 0) + 1
    if causes:
        print("front flips by running call: " + ", ".join("%s %d" % kv for kv in sorted(causes.items(), key=lambda kv: -kv[1])))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sc = sub.add_parser("scenario")
    sc.add_argument("--out", required=True)
    sc.add_argument("--agents", type=int, default=1)
    sc.add_argument("--rounds", type=int, default=1)
    sc.add_argument("--kinds", default="helium")
    sc.add_argument("--user", default="fixture", choices=["fixture", "helium"],
                    help="where the user is: an app of their own, or a browser window (the same app the agents use)")
    sc.add_argument("--interval", type=float, default=110, help="ms between the user's keys")
    sc.add_argument("--burst", type=int, default=0, help="the user types in runs of about this many keys (0: nonstop)")
    sc.add_argument("--pause", type=float, default=1800, help="ms the user pauses after each run, give or take")
    sc.add_argument("--seed", type=int, default=0, help="the same bursts and pauses every run (0: different each time)")
    sc.add_argument("--spread", type=float, default=0, help="spread of those pauses (sigma of a log-normal around --pause; 0: 0.6 to 1.6 times it)")
    sc.add_argument("--quiet", type=float, default=6, help="seconds of typing before the agents start")
    sc.add_argument("--stagger", type=float, default=0.7, help="seconds between agents starting")
    sc.add_argument("--timeout", type=float, default=240)
    sc.add_argument("--label", default="")
    sc.add_argument("--force", action="store_true")
    sm = sub.add_parser("summarize")
    sm.add_argument("dir")
    args = ap.parse_args()
    if args.cmd == "scenario":
        scenario(args)
    else:
        print_summary(summarize(os.path.abspath(args.dir)))


if __name__ == "__main__":
    main()
