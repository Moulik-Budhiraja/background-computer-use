"""Side-effect monitoring during an attempt: bcu.log slice, windows on the user's display, front app, clipboard."""
import re
import subprocess
import threading
import time

from .common import BCU, BCU_LOG


class LogSlice:
    def __init__(self):
        self.start = BCU_LOG.stat().st_size if BCU_LOG.exists() else 0

    def read(self):
        if not BCU_LOG.exists():
            return []
        with open(BCU_LOG, "rb") as f:
            f.seek(self.start)
            return f.read().decode("utf-8", errors="replace").splitlines()


def summarize_log(lines):
    out = {"lines": len(lines), "errors": [], "guard": [], "cursor_pulls": 0, "restores": 0, "self_activations": 0,
           "user_front_changes": [], "replayed_events": 0, "fits": 0, "tap_disabled": 0, "displays_created": 0}
    for l in lines:
        body = l.split(" ", 1)[1] if " " in l else l
        if body.startswith("error:") or " failed after " in body:
            out["errors"].append(l[:400])
        if body.startswith("guard:"):
            out["guard"].append(l[:300])
            if "cursor was on the agent display" in body:
                out["cursor_pulls"] += 1
            if "guard: restore" in body:
                out["restores"] += 1
            if "guard: activated" in body:
                out["self_activations"] += 1
                if "agentCaused=false" in body:
                    out["user_front_changes"].append(l[:200])
            m = re.search(r"replayed (\d+) held events", body)
            if m:
                out["replayed_events"] += int(m.group(1))
            if "disabled the event tap" in body:
                out["tap_disabled"] += 1
        if body.startswith("fit "):
            out["fits"] += 1
        if "Created the agent display" in body or "Created agent display" in body:
            out["displays_created"] += 1
    out["guard"] = out["guard"][:200]
    out["errors"] = out["errors"][:200]
    return out


class ScreenSampler(threading.Thread):
    """Samples on-screen windows ~20x/s. Records new windows whose frame overlaps a user display
    and changes of the topmost (front) window owner."""

    def __init__(self, interval=0.05):
        super().__init__(daemon=True)
        import Quartz
        self.Q = Quartz
        self.interval = interval
        self.stop_flag = False
        # User displays = displays online before the agent's display exists (CG, top-left coordinates).
        err, ids, n = Quartz.CGGetActiveDisplayList(16, None, None)
        self.user_rects = []
        for d in (ids or [])[:n]:
            r = Quartz.CGDisplayBounds(d)
            self.user_rects.append((r.origin.x, r.origin.y, r.size.width, r.size.height))
        self.baseline = {w["id"] for w in self._windows()}
        self.new_on_user = {}  # id -> record
        self.front_changes = []
        self.last_front = None
        self.samples = 0

    def _windows(self):
        Q = self.Q
        ws = Q.CGWindowListCopyWindowInfo(Q.kCGWindowListOptionOnScreenOnly | Q.kCGWindowListExcludeDesktopElements, Q.kCGNullWindowID) or []
        out = []
        for w in ws:
            if w.get("kCGWindowLayer") != 0:
                continue
            b = w.get("kCGWindowBounds") or {}
            out.append({"id": int(w.get("kCGWindowNumber")), "owner": str(w.get("kCGWindowOwnerName")),
                        "pid": int(w.get("kCGWindowOwnerPID")), "x": b.get("X", 0), "y": b.get("Y", 0),
                        "w": b.get("Width", 0), "h": b.get("Height", 0), "alpha": w.get("kCGWindowAlpha", 1)})
        return out

    def _on_user(self, w):
        for (x, y, W, H) in self.user_rects:
            if w["x"] < x + W and w["x"] + w["w"] > x and w["y"] < y + H and w["y"] + w["h"] > y:
                return True
        return False

    def run(self):
        while not self.stop_flag:
            try:
                ws = self._windows()
                self.samples += 1
                now = time.time()
                if ws:
                    front = ws[0]["owner"]
                    if front != self.last_front:
                        self.front_changes.append((round(now, 3), front))
                        self.last_front = front
                for w in ws:
                    if w["id"] in self.baseline or w["w"] < 60 or w["h"] < 60:
                        continue
                    if self._on_user(w):
                        rec = self.new_on_user.get(w["id"])
                        if rec is None:
                            self.new_on_user[w["id"]] = {"owner": w["owner"], "first": now, "last": now,
                                                         "frame": [w["x"], w["y"], w["w"], w["h"]], "samples": 1}
                        else:
                            rec["last"] = now
                            rec["samples"] += 1
            except Exception:
                pass
            time.sleep(self.interval)

    def result(self):
        recs = []
        for wid, r in self.new_on_user.items():
            recs.append({"window": wid, "owner": r["owner"], "visible_ms": round((r["last"] - r["first"]) * 1000) + 50,
                         "samples": r["samples"], "frame": r["frame"]})
        return {"samples": self.samples, "new_windows_on_user_display": recs, "front_owner_changes": self.front_changes[:300]}


def clipboard_get():
    try:
        return subprocess.run(["pbpaste"], capture_output=True, timeout=5).stdout
    except Exception:
        return b""


def clipboard_set(data: bytes):
    try:
        subprocess.run(["pbcopy"], input=data, timeout=5)
    except Exception:
        pass


def bcu_status():
    try:
        return subprocess.run([BCU, "status"], capture_output=True, text=True, timeout=20).stdout
    except Exception as e:
        return f"error: {e}"


def permissions_ok(status=None):
    s = status or bcu_status()
    return "accessibility MISSING" not in s and "screen recording MISSING" not in s and "Permissions:" in s


def runner_busy():
    r = subprocess.run(["pgrep", "-f", "Runner.Worker|actions-runner/bin/Runner"], capture_output=True, text=True)
    return bool(r.stdout.strip())
