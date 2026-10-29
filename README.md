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

After the first read of a window, `get_window_state` lists only what changed, and an element keeps its number for as long as it exists. Right after an action it waits up to 3 s for the window to settle. `batch` runs a list of actions in one call (say, click the address bar, type a URL, press Return), stops at the first failure, and returns the changes at the end, so the agent makes fewer round trips to the model.

For debugging: `bcu call <tool> '{json}'`, `bcu status`, `bcu tools`.

## How it stays out of your way

- **Its own display.** A 1600×1000 Retina virtual display (3200×2000 pixels, so the live preview stays sharp) touches your screens at one corner. An event tap keeps your cursor off it, and a watcher thread checks the cursor every 4–16 ms and pulls it back from anything that got past the tap (the tap not installed yet or disabled by macOS, displays being rearranged, another app warping the cursor).
- **Background input.** Clicks and keys are posted to one process through SkyLight, stamped with the target window. Accessibility actions (`AXPress`, value writes) are preferred because they need no keyboard focus.
- **Shared apps.** You and the agent can use the same app at once (say, both in Helium). Element clicks and value writes go through accessibility and never touch your window. Keystrokes and pixel clicks go to an app's key window, so the agent makes its window key inside the app for a few milliseconds and hands key straight back to yours. Your keys and clicks during that moment are held and replayed in order. Chromium doesn't repaint your window for a swap that short.
- **Web content.** Chromium and Electron build their full accessibility tree (with press actions on links and buttons) only when an assistive app asks. The agent sets `AXEnhancedUserInterface`, the standard attribute VoiceOver uses, once per app. Popups the agent's window opens, like address-bar suggestions, are listed with its elements so the agent can press them.
- **Focus guard.** Every action samples the front app every millisecond. If an app makes itself frontmost (Chromium does this when it opens a window), your app is put back and any keys you typed in between are held and replayed into it. Each tool result reports any focus change.
- **Crash safety.** The app's windows are tracked on disk, so a crash or restart closes the agent's windows instead of leaving them behind.

## Status

Early, but the core works. Measured on macOS 26.6 against real apps (Helium, TextEdit):

- **Focus test:** a script typed 627 characters into TextEdit on the user's screen while the agent opened Helium windows, navigated with keystrokes, used `cmd+L` and scrolled. All 627 characters landed in TextEdit, twice. Keys typed during Helium's self-activation were held and replayed.
- **Shared Helium:** with a Helium window of the user's in front and a script typing 264 characters into it, the agent navigated its own Helium window (address bar, typed URLs, link presses). All 264 characters landed in the user's window in order, and it stayed key throughout. Filming the user's window every 9–16 ms during the agent's typing showed no changed frame: tab bar, traffic lights, address bar and the text field's focus ring stayed the same.
- **Shared TextEdit:** the same test in TextEdit. A script typed 248 characters into a TextEdit window on the user's screen while the agent typed 105 characters, including a newline and brackets, into its own TextEdit document. Both texts were exact, and the user's window stayed key throughout.
- **Agent tools:** accessibility values, element presses, keystroke typing, `cmd+A` and other menu shortcuts, menu items, scroll, save sheets and logged-in web pages all work in the background.

Known gaps:
- **First window of an app you already use.** The agent's first new window in such an app can show on your screen for about 15–170 ms before it is moved. Later windows open next to the agent's existing one and never appear on your screen.
- **Chromium self-activation.** Chromium browsers make themselves frontmost for 15–60 ms when they open a window. The guard puts your app back and replays your keys, but the menu bar can flicker.
- `SLSProcessAssignToSpace` would open windows on the agent display with zero frames, but it moves every window of the app, yours included, so it's disabled (placement `space-unsafe`).

See [PLAN.md](PLAN.md) for the design.
