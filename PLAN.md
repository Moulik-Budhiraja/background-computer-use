# Background computer use: plan

One computer-use tool that any agent (Claude Code, Codex, custom agents) can call over MCP. It works in **your real, logged-in apps**, but does the work in windows on a separate virtual display you never see. You keep your frontmost app, key window, keystrokes, cursor and Space the whole time.

Agents only reach for computer use when a task can't be done any other way, so the tool doesn't sandbox anything. It uses your apps, your browser profile and your logins. Its one job is to stay out of your way.

## Rules

1. **Never modify the apps.** No code injection, no re-signing, no copies, no relaunching with special flags, no settings changes.
2. **Never depend on app-specific features.** No DevTools protocol, no AppleScript dictionaries, no Electron or Chromium attributes, no per-app code paths. The tool only uses mechanisms macOS provides for every app:
   - the virtual display (CoreGraphics)
   - window geometry and actions through Accessibility (the same API VoiceOver uses)
   - per-process input events (SkyLight)
   - window capture (ScreenCaptureKit)
   - LaunchServices, for launching apps and finding the default browser

   App knowledge lives in the agent, the same way a person figures out an unfamiliar app by looking at it.

## The core idea

Example: an agent needs a browser and your default browser is Helium.

1. The tool opens a **new window of Helium** on the agent's virtual display. It's the same Helium process and profile, so you're logged in everywhere.
2. The agent works only in that window, looking at it through Accessibility and screenshots and acting through Accessibility actions and per-process events. Your own Helium windows are untouched.
3. When the task ends, the agent's window closes.

Every app works the same way. Nothing in that flow is Helium-specific.

## What exists already

- **Virtual display.** `CGVirtualDisplay` (private CoreGraphics API) creates a real display that only exists in software. An earlier prototype of this project placed it touching your screens at a single corner and kept the cursor off it with an event tap. It ran Electron, SwiftUI and Chromium apps with no focus change. That code (display, cursor fence, focus watcher) gets folded into this repo.
- **Background input: [cua-driver](https://github.com/trycua/cua/tree/main/libs/cua-driver)** (MIT, Rust). See also [Inside macOS window internals](https://cua.ai/blog/inside-macos-window-internals) and [the no-foreground contract](https://cua.ai/docs/explanation/the-no-foreground-contract).
  - Clicks go through SkyLight `SLEventPostToPid`, stamped with the target pid and window ids.
  - Keys go through `SLEventPostToPid` with an authentication message attached.
  - A focus-only event record makes a window key inside its app without raising it or activating the app.
  - It tries AX actions before pixels.
  - Screenshots use ScreenCaptureKit per-window capture.
  - cua-driver also has app-specific paths (CDP for browsers, Electron's inspector, Apple Events). We vendor it and use only the generic paths.
- **Codex computer use** runs on your real displays with per-process events and after-the-fact focus correction. **Claude computer use** is foreground by design. Neither uses a separate display.

## The hard problems

All of these come from one fact: the agent's window and yours can belong to the same app process, and macOS gives each app **one key window** and the system **one frontmost app**.

### 1. Keystrokes go to the app's key window

macOS delivers a keyboard event to whichever window is key in that app, even when the event is posted straight to the process. There's no generic way to aim keys at a window that isn't key. So:
- **Accessibility actions first.** `AXPress`, value writes, `AXConfirm`, increment/decrement and menu-item presses don't need key status. Most clicks and most text entry can be done this way, in any app.
- **Keystrokes only when it's safe.** If you're not in the target app, the agent makes its window key in that app, sends the keys, then **restores the app's previous key window**. You never notice because the app isn't in front.
- **If you are in the target app,** keystroke steps wait until you leave it (per-app turn-taking). AX-only steps carry on.

### 2. Restoring each app's window order

Making the agent's window key also makes it that app's "last active" window. Without a fix:
- `cmd+tab` back to Helium would land you on the invisible window.
- Links opened from other apps would open there.

So the tool snapshots each touched app's key and main window before acting and restores them afterward, using the same focus-only record. The focus test checks this.

### 3. Activation

Some actions make an app activate itself (bring itself frontmost): opening a window, showing a sheet, opening a menu. Without injection this can't be blocked, so it has to be made harmless:
- **Keystroke hold.** The guard watches your keyboard with an event tap. If an app activates within a short window after an agent action on that app, the guard holds your keystrokes, re-activates your app, and replays them. Nothing you type lands in the agent's window, even for one frame.
- **Separate Spaces.** With "Displays have separate Spaces" on, an app activating on the agent display doesn't switch your Space or move your windows.
- **Measure what macOS does.** macOS 14+ made activation cooperative for apps that use the new `activate()` API, so many apps may not steal focus at all. The spike measures this per app instead of assuming it.

### 4. Opening a new window on the agent display without a flash

Generic ways to open a window: AX-press the app's "New Window" menu item (found by its `cmd+N` shortcut, `AXMenuItemCmdChar`), or launch through LaunchServices with `activates = false`. Where the window appears is up to the app:
- **AppKit and most apps** open new windows on the screen of the app's current key window. If the agent first makes one of its own windows key in that app (problem 1's dance), the new window should open on the agent display.
- **The first window**, when the agent has none in that app yet, may appear on your screen and then get moved by AX. The spike measures how many frames that takes. If it's visible, the fallback is to borrow an existing window you aren't using as the seed.
- **Single-window apps:** borrow the window (AX move to the agent display), work, move it back. If you're using the app, AX-only or wait.

### 5. Leftovers

- The agent's windows show in the app's Window menu and in `cmd+``.
- If you quit the app mid-task, state restoration may reopen the agent's window on your screen.
- The guard closes agent windows when a task ends and moves any agent window that lands on your screens back.

## Browsers

There's no browser support in the tool beyond knowing which browser is the default (the LaunchServices `https` handler). It's included in the tool's instructions so agents use your browser instead of guessing. Agents drive the browser like any other app: new window, then the address field, page content and buttons through Accessibility. Chromium, WebKit and Firefox all expose web content to Accessibility. That's what VoiceOver uses.

Generic gaps cua documents for web content in the background:
- right-click on Chromium content becomes a left-click
- some scroll and drag cases are dropped
- hover can't be produced

These get tested on the virtual display, where nothing is occluded. Some may simply work there.

## Architecture

```
 Claude Code / Codex / other agents
              │ MCP (stdio) or CLI
              ▼
        bgcu (MCP server)
              │ unix socket
              ▼
        bgcud (daemon, signed .app, one per login session)
        ├─ display:  CGVirtualDisplay, corner placement, cursor fence, reconfig handling
        ├─ windows:  open / borrow / return / close windows on the agent display (AX)
        ├─ focus:    per-app key/main window snapshot and restore, per-app turn-taking
        ├─ guard:    keystroke hold, frontmost/cursor/new-window watchdog, kill switch
        └─ input:    cua-driver generic paths: AX actions, SkyLight per-pid events, SCK capture
```

- **bgcud is a menu bar app** (no Dock icon), signed with a Developer ID, so Accessibility and Screen Recording grants survive rebuilds. Both are granted once at setup. No Automation grants, since nothing uses Apple Events.

### Menu bar app

- **Icon states.**
  - Idle.
  - Working: animated, with a count when several agents are active.
  - Waiting on you: a keystroke step is waiting because you're in that app, or the agent asked for a handoff.
  - Paused: you paused it, or the guard tripped.
- **Click the icon** to open a popover with:
  - **A live video preview** of the agent display: a ScreenCaptureKit stream of that display at roughly 10–15 fps, scaled to fit. The stream runs only while the popover is open.
  - **What it's doing:** which agent, which app and window, and the last few actions.
  - **Controls:** pause/resume, stop (closes or returns its windows), and take over, which moves the window onto your screen and pauses the agent until you hand it back.
  - **Guard events**, if any fired this session.
- **Global hotkey** for pause/stop, so you never need to find the icon in a hurry.
- **Setup and settings:** permission onboarding, launch at login, display size, preview frame rate.
- **Display lifetime.** The display exists while the daemon runs. If it disappears, macOS moves its windows onto your screen, so the daemon returns or closes agent windows on exit, and a watchdog does it after a crash.
- **MCP tools**, all scoped to agent-display windows:
  - `open_window(app)`: a new window, or a borrowed one for single-window apps
  - `release(window)`: close or return a window
  - `get_window_state`: AX tree + screenshot
  - Input: `click`, `set_value`, `type_text`, `press_key`, `hotkey`, `scroll`, `drag`, `press_menu_item`
  - `screenshot_workspace`
  - `handoff(window)`: moves a window onto your screen when you need to take over, for example a 2FA prompt
  - `guard_report`
  - `default_browser`

## The focus contract, made testable

An automated test types a known string into TextEdit on your display, nonstop, while the agent works in several apps. Each test fails on:
- a dropped or misrouted keystroke
- any change of frontmost app, key window or focused element on your side
- `cmd+tab` back to a touched app landing anywhere but your window
- any movement of the real cursor
- any new window appearing on your displays, even for one frame (checked by a ScreenCaptureKit recording of your display)
- a sound, a TCC prompt or a Space switch

The same watchdog runs in production. A violation pauses the agent and logs the action that caused it.

## Phases

**0. Spike (2–3 days).** Before building anything:
1. Bring up the virtual display and the TextEdit typing test.
2. Measure, for Helium, Notes, Finder, Messages, an Electron app and a SwiftUI app:
   - Does opening a new window activate the app?
   - Where does the window appear, and does the "key window on the agent display first" trick put it there?
   - How many frames is it visible on your screen if it has to be moved?
3. With you typing in your own Helium window, have the agent fill a web form in its window using only AX actions. Then repeat it with keystrokes, using the turn-taking and keystroke hold. Pass means zero stolen keystrokes, your window stays key, and `cmd+tab` returns to it.
4. Check background `cmd+a`, scroll, right-click and `<select>` on the virtual display.

Everything after this depends on the results.

**1. Menu bar app + MCP.** bgcud as a menu bar app with display, windows, focus and guard, plus the icon states and the live preview popover. bgcu exposes the tools. Vendor cua-driver as a pinned submodule, with app-specific paths disabled. Signed build and a setup flow for permissions.

**2. Hardening.** Keystroke hold, window-order restore, leftover cleanup, display reconfiguration (plugging and unplugging monitors), sleep/wake, and recovery after a crash.

**3. Agents.** Register as an MCP server for Claude Code and Codex. Add a short skill telling agents:
- use the default browser
- prefer AX actions
- expect keystroke steps to wait while you're in that app
- never use foreground
