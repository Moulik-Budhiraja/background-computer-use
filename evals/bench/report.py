"""Aggregate attempts into summary.json and REPORT tables: python -m bench.report results/DATE"""
import json
import math
import statistics as st
import sys
from collections import Counter, defaultdict
from pathlib import Path

# $ per 1M tokens, used only for Codex estimates (Claude reports its own cost).
CODEX_PRICE = None  # set via pricing.json in the results dir if known: {"input":..,"cached_input":..,"output":..}


def load(d: Path):
    recs = [json.loads(p.read_text()) for p in sorted((d / "attempts").glob("*.json"))]
    labels = json.loads((d / "labels.json").read_text()) if (d / "labels.json").exists() else {}
    for r in recs:
        tag = f"{r['task']}__{r['agent']}__t{r['trial']}"
        r["label"] = labels.get(tag)
    return recs, labels


def wilson(k, n, z=1.96):
    if n == 0:
        return (0, 0)
    p = k / n
    den = 1 + z * z / n
    c = (p + z * z / (2 * n)) / den
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / den
    return (max(0, c - h), min(1, c + h))


def group(recs, key):
    g = defaultdict(list)
    for r in recs:
        g[key(r)].append(r)
    return g


def rate(rs):
    return sum(r["passed"] for r in rs) / len(rs) if rs else 0.0


def pct(x):
    return f"{100 * x:.1f}%"


def tokens(r):
    u = r.get("usage") or {}
    if r["agent"] == "claude":
        return (u.get("input", 0) + u.get("cache_read", 0) + u.get("cache_write", 0), u.get("output", 0))
    return (u.get("input_tokens", 0), u.get("output_tokens", 0))


def codex_cost(r, price):
    if not price:
        return None
    u = r.get("usage") or {}
    inp = u.get("input_tokens", 0)
    cached = u.get("cached_input_tokens", 0)
    out = u.get("output_tokens", 0)
    return ((inp - cached) * price["input"] + cached * price["cached_input"] + out * price["output"]) / 1e6


def summarize(d: Path):
    recs, labels = load(d)
    price = json.loads((d / "pricing.json").read_text()) if (d / "pricing.json").exists() else None
    agents = sorted({r["agent"] for r in recs})
    S = {"n_attempts": len(recs), "agents": {}}
    for a in agents:
        rs = [r for r in recs if r["agent"] == a]
        trials = sorted({r["trial"] for r in rs})
        per_trial = {t: rate([r for r in rs if r["trial"] == t]) for t in trials}
        by_task = group(rs, lambda r: r["task"])
        complete = {k: v for k, v in by_task.items() if len(v) == len(trials)}
        costs = [r["cost_usd"] if a == "claude" else codex_cost(r, price) for r in rs]
        costs = [c for c in costs if c is not None]
        feas = [r for r in rs if not r["infeasible"]]
        inf = [r for r in rs if r["infeasible"]]
        k = sum(r["passed"] for r in rs)
        S["agents"][a] = {
            "model": rs[0].get("model"), "effort": rs[0].get("effort"),
            "attempts": len(rs), "tasks": len(by_task), "trials": trials,
            "pass_rate": rate(rs), "pass_rate_ci95": wilson(k, len(rs)),
            "per_trial_pass_rate": per_trial,
            "trial_std": st.pstdev(per_trial.values()) if len(per_trial) > 1 else 0.0,
            "pass_at_k_any": (sum(any(x["passed"] for x in v) for v in complete.values()) / len(complete)) if complete else None,
            "pass_all_k": (sum(all(x["passed"] for x in v) for v in complete.values()) / len(complete)) if complete else None,
            "flaky_tasks": sorted(k2 for k2, v in complete.items() if len({x["passed"] for x in v}) > 1),
            "mean_partial_score": st.mean(r["score"] for r in rs) if rs else 0,
            "by_tier": {t: {"n": len(v), "pass": rate(v), "score": st.mean(x["score"] for x in v)} for t, v in group(rs, lambda r: r["tier"]).items()},
            "by_category": {t: {"n": len(v), "pass": rate(v), "score": st.mean(x["score"] for x in v)} for t, v in group(rs, lambda r: r["category"]).items()},
            "by_app": {t: {"n": len(v), "pass": rate(v)} for t, v in group(rs, lambda r: "+".join(r["apps"])).items()},
            "wall_s_mean": st.mean(r["wall_s"] for r in rs), "wall_s_median": st.median(r["wall_s"] for r in rs),
            "wall_s_mean_passed": st.mean([r["wall_s"] for r in rs if r["passed"]] or [0]),
            "tool_calls_mean": st.mean(r["proxy"]["n_calls"] for r in rs),
            "tool_calls_median": st.median(r["proxy"]["n_calls"] for r in rs),
            "screenshots_mean": st.mean(r["proxy"]["screenshots"] for r in rs),
            "tool_time_share": (sum(r["proxy"]["total_tool_ms"] for r in rs) / 1000) / max(1, sum(r["wall_s"] for r in rs)),
            "input_tokens_mean": st.mean(tokens(r)[0] for r in rs), "output_tokens_mean": st.mean(tokens(r)[1] for r in rs),
            "cost_usd_mean": st.mean(costs) if costs else None, "cost_usd_total": sum(costs) if costs else None,
            "timeouts": sum(r["timed_out"] for r in rs),
            "within_step_budget_pass_rate": rate([dict(r, passed=r["passed"] and r["within_step_budget"]) for r in rs]),
            "feasible_pass_rate": rate(feas),
            "infeasible_correct_rate": rate(inf) if inf else None,
            "false_infeasible": sum(1 for r in feas if r["result"].get("said_infeasible")),
            "out_of_band_calls": sum(len(r["out_of_band_tool_calls"]) for r in rs),
            "agent_released_all_windows": sum(1 for r in rs if not r["proxy"]["leftover_windows"]),
            "clipboard_changed": sum(1 for r in rs if r.get("clipboard_changed")),
        }
    # BCU tool reliability across all attempts
    calls = defaultdict(lambda: {"n": 0, "err": 0, "ms": []})
    for r in recs:
        for s in r["proxy"]["steps"]:
            c = calls[s["tool"]]
            c["n"] += 1
            c["err"] += 1 if s.get("err") else 0
            c["ms"].append(s.get("ms") or 0)
    S["bcu_tools"] = {k: {"calls": v["n"], "errors": v["err"], "error_rate": v["err"] / v["n"] if v["n"] else 0,
                          "mean_ms": round(st.mean(v["ms"])) if v["ms"] else 0,
                          "p90_ms": round(sorted(v["ms"])[int(0.9 * (len(v["ms"]) - 1))]) if v["ms"] else 0}
                      for k, v in sorted(calls.items(), key=lambda kv: -kv[1]["n"])}
    # side effects on the user's screen
    se = {"attempts_with_window_on_user_display": 0, "windows_on_user_display": [], "front_app_changes_not_agent": 0,
          "guard_restores": 0, "self_activations": 0, "cursor_pulls": 0, "replayed_events": 0, "bcu_log_errors": 0,
          "clipboard_changed": 0, "attempts_with_leftover_windows": 0}
    for r in recs:
        w = r["screen"]["new_windows_on_user_display"]
        if w:
            se["attempts_with_window_on_user_display"] += 1
            for x in w:
                se["windows_on_user_display"].append({"attempt": f"{r['task']}__{r['agent']}__t{r['trial']}", **x})
        b = r["bcu_log"]
        se["guard_restores"] += b["restores"]
        se["self_activations"] += b["self_activations"]
        se["cursor_pulls"] += b["cursor_pulls"]
        se["replayed_events"] += b["replayed_events"]
        se["bcu_log_errors"] += len(b["errors"])
        se["clipboard_changed"] += 1 if r.get("clipboard_changed") else 0
        se["attempts_with_leftover_windows"] += 1 if r["proxy"]["leftover_windows"] else 0
    S["side_effects"] = se
    # failure taxonomy from labels
    tax = defaultdict(lambda: Counter())
    issues = Counter()
    issue_tasks = defaultdict(set)
    for r in recs:
        if r["passed"]:
            continue
        lab = r.get("label") or {}
        tax[r["agent"]][lab.get("class", "unlabeled")] += 1
        for iss in lab.get("bcu_issues", []):
            issues[iss] += 1
            issue_tasks[iss].add(f"{r['task']}__{r['agent']}__t{r['trial']}")
    S["failure_taxonomy"] = {a: dict(c) for a, c in tax.items()}
    S["bcu_issues_ranked"] = [{"issue": k, "attempts_lost": v, "attempts": sorted(issue_tasks[k])} for k, v in issues.most_common()]
    # per task table
    S["per_task"] = {}
    for tid, v in group(recs, lambda r: r["task"]).items():
        S["per_task"][tid] = {"tier": v[0]["tier"], "category": v[0]["category"],
                              **{a: {"passed": [x["passed"] for x in sorted(v, key=lambda x: x["trial"]) if x["agent"] == a],
                                     "score": [x["score"] for x in sorted(v, key=lambda x: x["trial"]) if x["agent"] == a],
                                     "wall_s": [x["wall_s"] for x in sorted(v, key=lambda x: x["trial"]) if x["agent"] == a],
                                     "calls": [x["proxy"]["n_calls"] for x in sorted(v, key=lambda x: x["trial"]) if x["agent"] == a]}
                                 for a in agents}}
    return S


def failures(d: Path):
    """Compact list of failed attempts for labeling."""
    recs, labels = load(d)
    out = []
    for r in recs:
        if r["passed"]:
            continue
        out.append({"tag": f"{r['task']}__{r['agent']}__t{r['trial']}", "score": r["score"],
                    "failed_subgoals": [k for k, v in r["result"]["subgoals"].items() if not v],
                    "timed_out": r["timed_out"], "wall_s": r["wall_s"], "calls": r["proxy"]["n_calls"],
                    "tool_errors": r["proxy"]["errors"][:8], "soft": r["proxy"]["soft_issues"][:8],
                    "final": r["final_text"][-600:], "raw_dir": r["raw_dir"], "label": r.get("label")})
    return out


if __name__ == "__main__":
    d = Path(sys.argv[1])
    S = summarize(d)
    (d / "summary.json").write_text(json.dumps(S, indent=1, default=str))
    (d / "failures.json").write_text(json.dumps(failures(d), indent=1, default=str))
    for a, s in S["agents"].items():
        print(a, s["model"], s["effort"], "pass", pct(s["pass_rate"]), "n", s["attempts"], "score", round(s["mean_partial_score"], 3),
              "wall", round(s["wall_s_mean"]), "calls", round(s["tool_calls_mean"], 1), "cost", s["cost_usd_mean"])
        for t, v in sorted(s["by_tier"].items()):
            print("   ", t, pct(v["pass"]), v["n"])
