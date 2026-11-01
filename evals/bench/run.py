"""Run the suite: python -m bench.run [--agents claude,codex] [--trials 2] [--tasks E01,...] [--out results/DATE]"""
import argparse
import datetime
import json
import shutil
import subprocess
import sys
import time
import traceback
from collections import Counter
from pathlib import Path

from . import agents as A
from . import monitor as M
from .common import EVAL_ROOT, REPO_EVALS, WEB_STATE, Ctx
from .prompt import build
from .tasks import TASKS

RUNS = EVAL_ROOT / "runs"


def start_web():
    WEB_STATE.mkdir(parents=True, exist_ok=True)
    try:
        import urllib.request
        urllib.request.urlopen("http://localhost:8765/index.html", timeout=2)
        urllib.request.urlopen("http://localhost:8766/index.html", timeout=2)
        return None
    except Exception:
        pass
    p = subprocess.Popen([A.PY, str(REPO_EVALS / "bench/web/server.py"), str(WEB_STATE), "8765", "8766"],
                         stdout=open(EVAL_ROOT / "web-server.log", "a"), stderr=subprocess.STDOUT, start_new_session=True)
    time.sleep(1.5)
    return p


FORCE = False


def wait_ready(log):
    waited = 0
    if FORCE:
        return 0
    while True:
        st = M.bcu_status()
        busy = M.runner_busy()
        if M.permissions_ok(st) and not busy and "Paused" not in st:
            return waited
        if waited % 300 == 0:
            log(f"waiting: permissions_ok={M.permissions_ok(st)} runner_busy={busy} status={st.strip()[:160]!r}")
        time.sleep(30)
        waited += 30


def summarize_proxy(path: Path):
    calls, harness, guard_final, leftover = [], [], "", []
    if path.exists():
        for line in path.read_text().splitlines():
            try:
                d = json.loads(line)
            except Exception:
                continue
            if d.get("tool") == "_guard_report_final":
                guard_final = d.get("text", "")
            elif d.get("tool") == "_leftover_windows":
                leftover = json.loads(d.get("text") or "[]")
            elif d.get("source") == "agent":
                calls.append(d)
            elif d.get("source") == "harness":
                harness.append(d)
    by_tool = Counter(c["tool"] for c in calls)
    errors = [{"tool": c["tool"], "args": c.get("args"), "text": c.get("text", "")[:600]} for c in calls if c.get("is_error")]
    soft = [{"tool": c["tool"], "text": c.get("text", "")[:400]} for c in calls
            if not c.get("is_error") and any(k in c.get("text", "") for k in
                                             ("failed", "didn't", "no longer exists", "not found", "[focus guard]", "timed out", "Couldn't", "couldn't"))]
    lat = {}
    for c in calls:
        lat.setdefault(c["tool"], []).append(c.get("ms", 0))
    steps = [{"tool": c["tool"], "args": c.get("args"), "ms": c.get("ms"), "err": c.get("is_error"), "images": c.get("images"),
              "text": c.get("text", "")[:300]} for c in calls]
    return {"n_calls": len(calls), "by_tool": dict(by_tool), "errors": errors, "soft_issues": soft[:50],
            "latency_ms": {k: {"n": len(v), "mean": round(sum(v) / len(v)), "max": max(v)} for k, v in lat.items()},
            "total_tool_ms": sum(c.get("ms", 0) for c in calls), "screenshots": sum(c.get("images", 0) for c in calls),
            "leftover_windows": leftover, "harness_cleanup_calls": [{"tool": h["tool"], "args": h.get("args"),
                                                                     "text": h.get("text", "")[:200]} for h in harness],
            "guard_report_final": guard_final[:4000], "steps": steps}


def run_attempt(task, agent, trial, ctx, out_dir: Path, log):
    tag = f"{task.id}__{agent}__t{trial}"
    rec_path = out_dir / "attempts" / f"{tag}.json"
    if rec_path.exists():
        return json.loads(rec_path.read_text())
    waited = wait_ready(log)
    adir = RUNS / out_dir.name / tag
    if adir.exists():
        shutil.rmtree(adir)
    adir.mkdir(parents=True)
    ctx.reset()
    task.setup(ctx)
    text = task.prompt(ctx)
    prompt = build(text)
    clip_before = M.clipboard_get()
    logslice = M.LogSlice()
    sampler = M.ScreenSampler()
    sampler.start()
    started = datetime.datetime.now().isoformat(timespec="seconds")
    log(f"start {tag}")
    try:
        run = A.run_agent(agent, prompt, adir, task.budget_s)
    finally:
        sampler.stop_flag = True
        sampler.join(timeout=2)
    time.sleep(1.0)
    log_lines = logslice.read()
    clip_after = M.clipboard_get()
    clipboard_changed = clip_after != clip_before
    if clipboard_changed:
        M.clipboard_set(clip_before)
    parsed = (A.parse_claude if agent == "claude" else A.parse_codex)(adir)
    try:
        res = task.check(ctx, parsed["final_text"]).to_dict()
    except Exception as e:
        res = {"passed": False, "score": 0.0, "subgoals": {}, "notes": [f"checker error: {e!r}", traceback.format_exc()[-600:]]}
    proxy = summarize_proxy(adir / "proxy.jsonl")
    oob = [t for t in parsed["agent_tool_calls"] if not str(t).startswith("mcp__bcu__")]
    rec = {
        "task": task.id, "tier": task.tier, "category": task.category, "apps": task.apps, "mechanics": task.mechanics,
        "infeasible": task.infeasible, "agent": agent, "trial": trial, "started": started, "lane": ctx.lane,
        "model": parsed.get("model"), "effort": A.CLAUDE_EFFORT if agent == "claude" else A.CODEX_EFFORT,
        "instruction": text, "budget_s": task.budget_s, "step_budget": task.step_budget, "waited_for_ready_s": waited,
        **run, "result": res, "passed": res["passed"], "score": res["score"],
        "final_text": parsed["final_text"][-3000:], "usage": parsed.get("usage"), "cost_usd": parsed.get("cost_usd"),
        "agent_tool_calls": len(parsed["agent_tool_calls"]), "out_of_band_tool_calls": oob,
        "agent_errors": parsed.get("errors"), "proxy": proxy,
        "within_step_budget": proxy["n_calls"] <= task.step_budget,
        "bcu_log": M.summarize_log(log_lines), "screen": sampler.result(), "clipboard_changed": clipboard_changed,
        "raw_dir": str(adir),
    }
    (adir / "bcu.log.slice").write_text("\n".join(log_lines))
    rec_path.parent.mkdir(parents=True, exist_ok=True)
    rec_path.write_text(json.dumps(rec, indent=1, default=str))
    log(f"done  {tag}: passed={res['passed']} score={res['score']} wall={run['wall_s']}s calls={proxy['n_calls']} "
        f"timeout={run['timed_out']} oob={len(oob)}")
    return rec


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--agents", default="claude,codex")
    ap.add_argument("--trials", type=int, default=2)
    ap.add_argument("--tasks", default="")
    ap.add_argument("--out", default=str(REPO_EVALS / "results" / datetime.date.today().isoformat()))
    ap.add_argument("--lane", default="a")
    ap.add_argument("--force", action="store_true", help="skip the permission/runner wait (smoke tests)")
    args = ap.parse_args()
    global FORCE
    FORCE = args.force
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    logf = open(out / "run.log", "a")

    def log(msg):
        line = f"{datetime.datetime.now().strftime('%H:%M:%S')} {msg}"
        print(line, flush=True)
        logf.write(line + "\n")
        logf.flush()

    start_web()
    A.ensure_codex_home()
    ids = [x for x in args.tasks.split(",") if x]
    tasks = [t for t in TASKS if not ids or any(t.id.startswith(i) for i in ids)]
    agents = args.agents.split(",")
    ctx = Ctx(lane=args.lane)
    log(f"run: {len(tasks)} tasks x {agents} x {args.trials} trials -> {out}")
    for trial in range(1, args.trials + 1):
        for t in tasks:
            order = agents if trial % 2 == 1 else list(reversed(agents))
            for ag in order:
                try:
                    run_attempt(t, ag, trial, ctx, out, log)
                except Exception as e:
                    log(f"ERROR {t.id} {ag} t{trial}: {e!r}\n{traceback.format_exc()[-1500:]}")
    log("run complete")


if __name__ == "__main__":
    main()
