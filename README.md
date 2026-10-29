# Background Computer Use

Computer use for macOS agents that never takes your focus. Agents work in your real, logged-in apps, in windows on a private virtual display you don't see, while you keep using your Mac. A menu bar app shows what the agent is doing, with a live view you can expand.

No app is modified and nothing is app-specific. It only uses what macOS provides for every app: a virtual display (`CGVirtualDisplay`), Accessibility, per-process input events (SkyLight), and direct window capture.

## Install

```bash
scripts/build-app.sh --install
```

This builds `Background Computer Use.app`, signs it with your Developer ID (or ad hoc), copies it to /Applications and starts it. Grant Accessibility and Screen Recording when it asks, then quit and reopen it once.

## Connect an agent

Claude Code:

```bash
claude mcp add --scope user background-computer-use -- "/Applications/Background Computer Use.app/Contents/MacOS/bcu" mcp
```

Codex (`~/.codex/config.toml`):

```toml
[mcp_servers.background-computer-use]
command = "/Applications/Background Computer Use.app/Contents/MacOS/bcu"
args = ["mcp"]
```

The MCP server's instructions tell the agent how to work: open a window of the app (or the default browser) on its display, read it with `get_window_state`, act on numbered elements, release windows at the end, and hand off to you when it needs you.

For debugging: `bcu call <tool> '{json}'`, `bcu status`, `bcu tools`.

## How it stays out of your way

- **Its own display.** A 1600×1000 virtual display touches your screens at one corner. An event tap keeps your cursor off it.
- **Background input.** Clicks and keys are posted to one process through SkyLight, stamped with the target window. Accessibility actions (`AXPress`, value writes) are preferred because they need no keyboard focus.
- **Key window restore.** Keystrokes go to an app's key window, so the agent makes its window key inside that app without activating it, then gives key back. If you are using that same app, keyboard steps wait until you leave it.
- **Focus guard.** Every action samples the front app every millisecond. If an app makes itself frontmost (Chromium does this when it opens a window), your app is put back and any keys you typed in between are held and replayed into it. Each tool result reports any focus change.
- **Crash safety.** The app's windows are tracked on disk, so a crash or restart closes the agent's windows instead of leaving them behind.

## Status

Early, but the core works. Measured on macOS 26.6 against real apps (Helium, TextEdit):

- **Focus test:** a script typed 627 characters into TextEdit on the user's screen while the agent opened Helium windows, navigated with keystrokes, used `cmd+L` and scrolled. All 627 characters landed in TextEdit, twice. Keys typed during Helium's self-activation were held and replayed.
- **Agent tools:** accessibility values, element presses, keystroke typing, `cmd+A` and other menu shortcuts, menu items, scroll, save sheets and logged-in web pages all work in the background.

Known gaps:
- **First window of an app you already use.** The agent's first new window in such an app can show on your screen for about 15–170 ms before it is moved. Later windows open next to the agent's existing one and never appear on your screen.
- **Chromium self-activation.** Chromium browsers make themselves frontmost for 15–60 ms when they open a window. The guard puts your app back and replays your keys, but the menu bar can flicker.
- `SLSProcessAssignToSpace` would open windows on the agent display with zero frames, but it moves every window of the app, yours included, so it's disabled (placement `space-unsafe`).

See [PLAN.md](PLAN.md) for the design.
