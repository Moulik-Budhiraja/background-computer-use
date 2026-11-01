# Benchmarks this eval draws from (as of 1 Nov 2026)

These numbers came from a web survey of leaderboards and model cards on 1 Nov 2026. Most top scores are vendor-reported. Some leaderboards render only with JavaScript and were read through mirrors, which disagree with each other.

| Benchmark | Platform | What we took | State (late 2026) |
|---|---|---|---|
| OSWorld / OSWorld-Verified | Ubuntu VM, 369 tasks | Execution checkers on final file and app state, office, file and multi-app domains, step budgets (15/50/100), infeasible tasks | Saturated: best agents ~85–90%, human 72% |
| OSWorld 2.0 / 2.1 | Linux, 108 long workflows | Partial credit by checkpoint, long multi-app workflows | Open: strict ~44–49%, partial ~78–82% (Opus 5.5 81.8% partial, vendor) |
| macOSWorld | macOS VM, 202 tasks | macOS app mix, per-category breakdown, multi-app is hardest (Claude 8.6%) | Open, no 2026 frontier runs |
| MacArena / MacAgentBench (2026) | macOS | Native macOS file-management and multi-app tasks are where agents fail; 15–50 step budgets | Open (32–74%) |
| WindowsAgentArena / WindowsWorld | Windows | Office-app tasks; WindowsWorld L4 infeasible tasks (agents claim false success) | WAA near human; WindowsWorld open |
| Online-Mind2Web, WebArena(-Verified), VisualWebArena | Web | Easy/medium/hard tiers, forms, filtering and dates as the main error sources, ground-truth answers for info tasks | Mind2Web saturated; WebArena-Verified and VWA open |
| TheAgentCompany | Simulated company | Checkpoint partial credit, popups and dialogs as failure points | Open (~43%) |
| ScreenSpot-Pro | Screenshots | Grounding precision (we measure it indirectly through pixel clicks and drags) | Near saturation (GPT-6 Astra 92.7%) |
| AndroidWorld | Android | Programmatic checks on device state | Saturated |
| OSWorld-MCP / MCPWorld | Linux + MCP tools | GUI agents behind an MCP tool layer; check for UI bypass | Open |

## What the eval borrows

- **Execution checkers, not an LLM judge.** Every task is checked from the final state: saved files parsed with numbers-parser, python-docx, openpyxl, python-pptx, pypdf and textutil; local web-server logs; Finder metadata (tags); or an exact ground-truth answer for information tasks.
- **Partial credit.** Each task has 2–7 sub-goals, and a task passes only when all of them pass.
- **Tiers.** Easy is single-app with about 10 actions, medium needs 10–30 actions or harder mechanics, hard is multi-app, long, or needs drag, file pickers or charts.
- **Hard mechanics on macOS.** Open and save panels (Go to Folder), export dialogs, template and theme choosers, drag in a slide navigator, page thumbnails and web kanban, file-picker upload, downloads, the font panel, find & replace, sorting, formulas and charts.
- **Infeasible tasks.** Following OSWorld and WindowsWorld L4, there are 4 tasks the agent should decline: a missing file with a tempting look-alike, a battery on a Mac mini, a form field that doesn't exist, and an export format that doesn't exist. To stop "always decline" from paying off, claiming INFEASIBLE on a feasible task counts as a failure.
- **Stable public answers.** Web facts that post-date both models' training and won't change: Wikipedia's featured article for 14 Sep 2026, numbers-parser 4.20.0's release date, ruff's first release of Sep 2026. Everything interactive runs on localhost only.
- **Anti-bypass.** OSWorld 2.0 found agents bypass the UI in about 33% of tasks. Here the only tools are BCU's, and every call is logged.
