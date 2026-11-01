"""Validate every checker: setup-only and known-bad end states must fail, known-good must pass."""
import json
import sys
import traceback

from .common import Ctx
from .tasks import TASKS


def run(ids=None, lane="v"):
    ctx = Ctx(lane=lane)
    rows, ok_all = [], True
    for t in TASKS:
        if ids and t.id not in ids:
            continue
        out = {"task": t.id}
        for mode in ("empty", "good", "bad"):
            try:
                ctx.reset()
                t.setup(ctx)
                text = "" if mode == "empty" else (t.good(ctx) if mode == "good" else t.bad(ctx))
                res = t.check(ctx, text)
                out[mode] = {"passed": res.passed, "score": round(res.score, 2),
                             "failed": [k for k, v in res.subgoals.items() if not v]}
            except Exception as e:
                out[mode] = {"error": repr(e), "tb": traceback.format_exc()[-800:]}
        good_ok = out["good"].get("passed") is True
        bad_ok = out["bad"].get("passed") is False
        empty_ok = out["empty"].get("passed") is False
        out["valid"] = good_ok and bad_ok and empty_ok
        ok_all &= out["valid"]
        rows.append(out)
        print(("OK  " if out["valid"] else "BAD ") + t.id, "" if out["valid"] else json.dumps(out)[:1500], flush=True)
    return ok_all, rows


if __name__ == "__main__":
    ok, rows = run(sys.argv[1:] or None)
    json.dump(rows, open("/tmp/bcu-validate.json", "w"), indent=1)
    print("ALL VALID" if ok else "SOME CHECKERS INVALID")
    sys.exit(0 if ok else 1)
