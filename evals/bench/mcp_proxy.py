#!/usr/bin/env python3
"""Transparent stdio proxy between an agent CLI and `bcu mcp`.

It forwards every JSON-RPC line unchanged and appends one JSON line per
tool call to $BCU_EVAL_PROXY_LOG (tool, args, latency, isError, result text,
image count). When the agent goes away (stdin EOF or a signal) it forks a
detached child that keeps the `bcu mcp` connection, so it can:

  1. read guard_report,
  2. release every window the agent opened and didn't release, answering
     "save changes?" sheets with Don't Save / Delete,

before closing BCU. The harness waits for $BCU_EVAL_PROXY_LOG.done.
"""
import json
import os
import re
import select
import signal
import subprocess
import sys
import time

BCU = "/Applications/Background Computer Use.app/Contents/MacOS/bcu"
LOG = os.environ.get("BCU_EVAL_PROXY_LOG", "/tmp/bcu-eval-proxy.jsonl")


def now():
    return time.time()


def write_log(rec):
    with open(LOG, "a") as f:
        f.write(json.dumps(rec) + "\n")


class Proxy:
    def __init__(self):
        self.child = subprocess.Popen([BCU, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                      bufsize=0, start_new_session=True)
        self.pending = {}  # id -> (tool, args, t0)
        self.open_windows = set()
        self.cbuf = b""
        self.ibuf = b""
        self.next_id = 900000

    # ---- forwarding ----
    def from_agent(self, line):
        try:
            msg = json.loads(line)
            if msg.get("method") == "tools/call":
                p = msg.get("params", {})
                self.pending[msg.get("id")] = (p.get("name"), p.get("arguments", {}), now())
        except Exception:
            pass
        self.child.stdin.write(line)
        self.child.stdin.flush()

    def from_bcu(self, line):
        try:
            msg = json.loads(line)
            mid = msg.get("id")
            if mid in self.pending:
                tool, args, t0 = self.pending.pop(mid)
                self.record(tool, args, t0, msg, source="agent")
        except Exception:
            pass
        sys.stdout.buffer.write(line)
        sys.stdout.buffer.flush()

    def record(self, tool, args, t0, msg, source):
        res = msg.get("result") or {}
        content = res.get("content") or []
        texts = [c.get("text", "") for c in content if c.get("type") == "text"]
        images = sum(1 for c in content if c.get("type") == "image")
        text = "\n".join(texts)
        is_err = bool(res.get("isError")) or ("error" in msg)
        if "error" in msg:
            text = json.dumps(msg["error"])
        if tool == "open_window" and not is_err:
            m = re.search(r"window[_ ]id\D{0,5}(\d+)", text) or re.search(r"\b(\d{3,})\b", text)
            if m:
                self.open_windows.add(int(m.group(1)))
        if tool == "release_window" and not is_err and "didn't close" not in text:
            try:
                self.open_windows.discard(int(args.get("window_id")))
            except Exception:
                pass
        write_log({"t0": t0, "t1": now(), "ms": round((now() - t0) * 1000), "source": source, "tool": tool,
                   "args": args, "is_error": is_err, "images": images, "text_len": len(text),
                   "text": text[:4000]})

    def pump(self):
        stdin_fd = sys.stdin.buffer.fileno()
        out_fd = self.child.stdout.fileno()
        stdin_open = True
        while True:
            fds = [out_fd] + ([stdin_fd] if stdin_open else [])
            r, _, _ = select.select(fds, [], [], 1.0)
            if out_fd in r:
                data = os.read(out_fd, 1 << 20)
                if not data:
                    return
                self.cbuf += data
                while b"\n" in self.cbuf:
                    line, self.cbuf = self.cbuf.split(b"\n", 1)
                    self.from_bcu(line + b"\n")
            if stdin_open and stdin_fd in r:
                data = os.read(stdin_fd, 1 << 20)
                if not data:
                    return  # agent closed the connection
                self.ibuf += data
                while b"\n" in self.ibuf:
                    line, self.ibuf = self.ibuf.split(b"\n", 1)
                    self.from_agent(line + b"\n")

    # ---- cleanup in the detached child ----
    def call(self, tool, args, timeout=30):
        self.next_id += 1
        mid = self.next_id
        msg = {"jsonrpc": "2.0", "id": mid, "method": "tools/call", "params": {"name": tool, "arguments": args}}
        t0 = now()
        self.child.stdin.write((json.dumps(msg) + "\n").encode())
        self.child.stdin.flush()
        out_fd = self.child.stdout.fileno()
        deadline = now() + timeout
        while now() < deadline:
            r, _, _ = select.select([out_fd], [], [], 1.0)
            if not r:
                continue
            data = os.read(out_fd, 1 << 20)
            if not data:
                return None
            self.cbuf += data
            while b"\n" in self.cbuf:
                line, self.cbuf = self.cbuf.split(b"\n", 1)
                try:
                    resp = json.loads(line)
                except Exception:
                    continue
                if resp.get("id") == mid:
                    self.record(tool, args, t0, resp, source="harness")
                    content = (resp.get("result") or {}).get("content") or []
                    return "\n".join(c.get("text", "") for c in content if c.get("type") == "text")
        return None

    def cleanup(self):
        report = self.call("guard_report", {})
        write_log({"t0": now(), "source": "harness", "tool": "_guard_report_final", "text": (report or "")[:20000]})
        st = self.call("status", {}) or ""
        ids = set(self.open_windows)
        for m in re.finditer(r"window[ _]?(?:id)?\D{0,4}(\d{3,})", st):
            ids.add(int(m.group(1)))
        leftover = sorted(ids)
        write_log({"t0": now(), "source": "harness", "tool": "_leftover_windows", "text": json.dumps(leftover),
                   "status": st[:2000]})
        for wid in leftover:
            out = self.call("release_window", {"window_id": wid}) or ""
            tries = 0
            while ("didn't close" in out or "dialog" in out.lower()) and tries < 3:
                tries += 1
                state = self.call("get_window_state", {"window_id": wid, "full": True, "screenshot": False}) or ""
                btn = None
                for pat in [r"\[(\d+)\] Button \"Don.t Save\"", r"\[(\d+)\] Button \"Delete\"",
                            r"\[(\d+)\] Button \"Revert Changes\"", r"\[(\d+)\] Button \"Don.t Replace\"",
                            r"\[(\d+)\] Button \"Cancel\""]:
                    m = re.search(pat, state)
                    if m:
                        btn = int(m.group(1))
                        break
                if btn is None:
                    self.call("press_key", {"window_id": wid, "key": "escape"})
                else:
                    self.call("click", {"window_id": wid, "element": btn})
                time.sleep(0.5)
                out = self.call("release_window", {"window_id": wid}) or ""
        try:
            self.child.stdin.close()
            self.child.wait(timeout=5)
        except Exception:
            self.child.kill()


def main():
    p = Proxy()

    def on_signal(signum, frame):
        raise KeyboardInterrupt

    for s in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(s, on_signal)
    try:
        p.pump()
    except KeyboardInterrupt:
        pass
    except Exception as e:
        write_log({"t0": now(), "source": "proxy", "tool": "_proxy_error", "text": repr(e)})
    # Detach so the agent CLI killing us doesn't cut the cleanup short.
    if os.fork() != 0:
        os._exit(0)
    os.setsid()
    for s in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(s, signal.SIG_IGN)
    try:
        devnull = os.open(os.devnull, os.O_RDWR)
        os.dup2(devnull, 0)
        os.dup2(devnull, 1)
        p.cleanup()
    except Exception as e:
        write_log({"t0": now(), "source": "proxy", "tool": "_cleanup_error", "text": repr(e)})
    finally:
        open(LOG + ".done", "w").write(str(now()))
        os._exit(0)


if __name__ == "__main__":
    main()
