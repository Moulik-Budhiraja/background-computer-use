# BCU computer-use eval

Measures how well AI agents finish computer-use tasks on this Mac when Background Computer Use (BCU) is their only way to act. It runs Claude Code and Codex headless, one fresh session per attempt, and checks the final state of files and pages.

See [RESEARCH.md](RESEARCH.md) for the benchmarks the design borrows from.

## Layout

- `bench/tasks.py`: 41 tasks (11 easy, 14 medium, 12 hard, 4 infeasible). Each has a setup, an instruction, a deterministic checker with sub-goals, and a known-good and known-bad end state.
- `bench/fixtures.py`: fixture data and file builders (docx, xlsx, pptx, pdf, rtf, numbers, web data pages).
- `bench/web/`: local test site (forms, wizard, kanban, upload, docs site) served on localhost:8765/8766. Submissions are logged to `~/bcu-eval/web-state/`.
- `bench/mcp_proxy.py`: a stdio proxy between the agent and `bcu mcp`. It logs every tool call (args, latency, errors, screenshots), and when the agent exits it reads `guard_report` and releases any window the agent left open.
- `bench/agents.py`: how each agent is launched with only the BCU MCP server.
- `bench/monitor.py`: side effects during an attempt: the bcu.log slice, new windows on the user's display (sampled at 20 Hz), front-window changes, and the clipboard.
- `bench/run.py`: the runner. `bench/report.py`: aggregation. `bench/validate.py`: checker validation.
- `results/<date>/`: per-attempt JSON, `summary.json`, `failures.json`, `labels.json` (failure taxonomy) and `REPORT.md`.

Fixtures live in `~/bcu-eval/work` and are rebuilt before every attempt. Raw transcripts go to `~/bcu-eval/runs/`.

## Running

```bash
cd evals
uv venv .venv --python 3.11 && uv pip install --python .venv/bin/python -r requirements.txt
.venv/bin/python -m bench.validate            # every checker: good passes, bad and untouched fail
.venv/bin/python -m bench.run --trials 2      # waits until BCU has Accessibility + Screen Recording
.venv/bin/python -m bench.report results/<date>
```

`--tasks E01,H06` runs a subset and `--agents claude` runs one agent. A rerun skips attempts that already have a JSON file.

## Fairness and isolation

Both agents get the same prompt: the eval rules, BCU's server instructions, BCU's skill, then the task.

- **Claude Code:** `claude -p --model claude-opus-5-5 --effort high --tools "" --allowedTools "mcp__bcu__*" --strict-mcp-config --setting-sources "" --disable-slash-commands --no-chrome`. claude.ai connectors are off. The session's init message lists only the 20 BCU tools.
- **Codex:** `codex exec` from the ChatGPT app (codex-cli 0.166.0-alpha.5.1), model `gpt-6-astra` at `high` reasoning effort. It uses a separate `CODEX_HOME` (`~/bcu-eval/codex-home`, with `auth.json` symlinked) so the owner's config isn't used or edited. The shell tool, unified exec, plugins, apps, browser use, computer use, web search, image tools and multi-agent are all disabled. The sandbox is read-only, and BCU's MCP tools are auto-approved.
  - Code mode has to stay on, because Codex routes MCP calls through it. It has no filesystem or process APIs.
  - `apply_patch` is still listed, but the read-only sandbox rejects it. A probe run confirmed that apply_patch, `require('fs')` and shell attempts all fail.
- **Out-of-band check:** every tool call in each transcript is checked to be `mcp__bcu__*`. The proxy log is an independent record of what reached BCU.
