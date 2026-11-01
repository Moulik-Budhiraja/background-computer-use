"""Launch Claude Code or Codex headless, with only the BCU MCP server (through the logging proxy)."""
import json
import os
import signal
import subprocess
import time
from pathlib import Path

from .common import EVAL_ROOT, REPO_EVALS

PY = str(REPO_EVALS / ".venv/bin/python")
PROXY = str(REPO_EVALS / "bench/mcp_proxy.py")
CLAUDE = str(Path.home() / ".local/bin/claude")
CODEX = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
CODEX_HOME = EVAL_ROOT / "codex-home"

CLAUDE_MODEL = "claude-opus-5-5"
CLAUDE_EFFORT = "high"
CODEX_MODEL = "gpt-6-astra"
CODEX_EFFORT = "high"

CODEX_CONFIG = f"""model = "{CODEX_MODEL}"
model_reasoning_effort = "{CODEX_EFFORT}"
approval_policy = "never"
sandbox_mode = "read-only"
web_search = "disabled"

[mcp_servers.bcu]
command = "{PY}"
args = ["{PROXY}"]
startup_timeout_sec = 60
tool_timeout_sec = 300
default_tools_approval_mode = "approve"

[features]
shell_tool = false
unified_exec = false
apps = false
plugins = false
browser_use = false
browser_use_external = false
computer_use = false
in_app_browser = false
multi_agent = false
image_generation = false
view_image = false
code_mode_host = true
skill_search = false
tool_suggest = false
hooks = false
goals = false
memories = false
shell_snapshot = false
in_app_local_automation = false
remote_plugin = false
plugin_discovery_prefetch = false
skill_mcp_dependency_install = false
"""


def ensure_codex_home():
    CODEX_HOME.mkdir(parents=True, exist_ok=True)
    auth = CODEX_HOME / "auth.json"
    if not auth.exists():
        auth.symlink_to(Path.home() / ".codex/auth.json")
    (CODEX_HOME / "config.toml").write_text(CODEX_CONFIG)


def claude_cmd(prompt, attempt_dir, proxy_log):
    mcp = {"mcpServers": {"bcu": {"command": PY, "args": [PROXY], "env": {"BCU_EVAL_PROXY_LOG": str(proxy_log)}}}}
    cfg = attempt_dir / "mcp.json"
    cfg.write_text(json.dumps(mcp))
    cmd = [CLAUDE, "-p", prompt, "--model", CLAUDE_MODEL, "--effort", CLAUDE_EFFORT,
           "--output-format", "stream-json", "--verbose",
           "--strict-mcp-config", "--mcp-config", str(cfg),
           "--tools", "", "--allowedTools", "mcp__bcu__*",
           "--permission-mode", "dontAsk", "--setting-sources", "",
           "--disable-slash-commands", "--no-chrome", "--no-session-persistence"]
    env = dict(os.environ, ENABLE_CLAUDEAI_MCP_SERVERS="false", CLAUDE_CODE_DISABLE_AUTO_MEMORY="1")
    return cmd, env


def codex_cmd(prompt, attempt_dir, proxy_log):
    ensure_codex_home()
    cmd = [CODEX, "exec", "--json", "--ephemeral", "--skip-git-repo-check", "--strict-config",
           "-C", str(attempt_dir), "-o", str(attempt_dir / "last_message.txt"),
           "-c", f'mcp_servers.bcu.env={{BCU_EVAL_PROXY_LOG="{proxy_log}"}}',
           prompt]
    env = dict(os.environ, CODEX_HOME=str(CODEX_HOME))
    return cmd, env


def run_agent(agent, prompt, attempt_dir: Path, timeout_s):
    attempt_dir.mkdir(parents=True, exist_ok=True)
    proxy_log = attempt_dir / "proxy.jsonl"
    cmd, env = (claude_cmd if agent == "claude" else codex_cmd)(prompt, attempt_dir, proxy_log)
    out = open(attempt_dir / "transcript.jsonl", "w")
    err = open(attempt_dir / "stderr.txt", "w")
    t0 = time.time()
    p = subprocess.Popen(cmd, cwd=str(attempt_dir), env=env, stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                         start_new_session=True)
    timed_out = False
    try:
        p.wait(timeout=timeout_s)
    except subprocess.TimeoutExpired:
        timed_out = True
        try:
            os.killpg(p.pid, signal.SIGTERM)
            p.wait(timeout=15)
        except Exception:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except Exception:
                pass
            p.wait()
    wall = time.time() - t0
    out.close()
    err.close()
    # wait for the proxy's cleanup (guard report + releasing leftover windows)
    done = Path(str(proxy_log) + ".done")
    deadline = time.time() + 90
    while time.time() < deadline and not done.exists():
        time.sleep(0.5)
    return {"wall_s": round(wall, 1), "exit_code": p.returncode, "timed_out": timed_out,
            "proxy_cleanup_done": done.exists(), "cmd": [c if len(c) < 300 else c[:80] + "…" for c in cmd]}


# ---------- transcript parsing ----------
def parse_claude(attempt_dir: Path):
    tools, final, usage, cost, model, init_tools = [], "", {}, None, None, None
    turns = 0
    for line in (attempt_dir / "transcript.jsonl").read_text().splitlines():
        try:
            d = json.loads(line)
        except Exception:
            continue
        if d.get("type") == "system" and d.get("subtype") == "init":
            init_tools = d.get("tools")
            model = d.get("model")
        if d.get("type") == "assistant":
            turns += 1
            for c in d.get("message", {}).get("content", []):
                if c.get("type") == "tool_use":
                    tools.append(c.get("name"))
        if d.get("type") == "result":
            final = d.get("result") or ""
            usage = d.get("usage", {})
            cost = d.get("total_cost_usd")
            model_usage = d.get("modelUsage")
            usage = {"input": usage.get("input_tokens", 0), "cache_read": usage.get("cache_read_input_tokens", 0),
                     "cache_write": usage.get("cache_creation_input_tokens", 0), "output": usage.get("output_tokens", 0),
                     "num_turns": d.get("num_turns"), "model_usage": model_usage, "is_error": d.get("is_error"),
                     "subtype": d.get("subtype")}
    return {"final_text": final, "agent_tool_calls": tools, "usage": usage, "cost_usd": cost, "model": model,
            "available_tools": init_tools}


def parse_codex(attempt_dir: Path):
    tools, final, usage, errors = [], "", {}, []
    for line in (attempt_dir / "transcript.jsonl").read_text().splitlines():
        try:
            d = json.loads(line)
        except Exception:
            continue
        t = d.get("type")
        it = d.get("item") or {}
        if t == "item.completed":
            ty = it.get("type")
            if ty == "mcp_tool_call":
                tools.append(f"mcp__{it.get('server')}__{it.get('tool')}")
            elif ty == "agent_message":
                final = it.get("text") or final
            elif ty in ("command_execution", "file_change", "web_search", "patch_apply"):
                tools.append(f"BUILTIN:{ty}")
            elif ty == "error":
                errors.append(it.get("message"))
        if t == "turn.completed":
            u = d.get("usage", {})
            for k, v in u.items():
                usage[k] = usage.get(k, 0) + (v or 0)
        if t in ("turn.failed", "error"):
            errors.append(json.dumps(d)[:500])
    lm = attempt_dir / "last_message.txt"
    if lm.exists() and lm.read_text().strip():
        final = lm.read_text()
    return {"final_text": final, "agent_tool_calls": tools, "usage": usage, "cost_usd": None, "model": CODEX_MODEL,
            "errors": errors}
