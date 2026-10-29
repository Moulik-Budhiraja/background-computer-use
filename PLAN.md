# Background computer use: plan

One computer-use tool that any agent (Claude Code, Codex, custom agents) can call over MCP. It works in **your real, logged-in apps**, but does the work in windows on a separate virtual display you never see. You keep your frontmost app, key window, keystrokes, cursor and Space the whole time.

Agents only reach for computer use when a task can't be done any other way, so the tool doesn't sandbox anything. It uses your apps, your browser profile and your logins. Its one job is to stay out of your way.

**Rule: never modify the apps.** No code injection, no re-signing, no copies, no relaunching with special flags. Everything works from outside, through public or system-level interfaces:
- the virtual display
- SkyLight per-process events
- Accessibility
- Apple Events
- the browser's own DevTools protocol

The only app-side change allowed is a user-visible setting, set once, such as the browser's remote-debugging toggle.

## The core idea

Example: an agent needs a browser and your default browser is Helium.

1. The tool opens a **new Helium window** directly on the agent's virtual display. It's the same Helium process and profile, so you're logged in everywhere.
2. The agent works only in that window. Your own Helium windows are untouched, and you can keep using them at the same time.
3. When the task ends, the agent's window closes.

Native apps work the same way: open a new window of the app on the agent display, or briefly move a window there, then drive it.

## What exists already

- **Virtual display.** `CGVirtualDisplay` (private CoreGraphics API) creates a real display that only exists in software. An earlier prototype of this project placed it touching your screens at a single corner and kept the cursor off it with an event tap. It ran Electron, SwiftUI and Chromium apps with no focus change. That code (display, cursor fence, focus watcher) gets folded into this repo.
- **Background input: [cua-driver](https://github.com/trycua/cua/tree/main/libs/cua-driver)** (MIT, Rust). See also [Inside macOS window internals](https://cua.ai/blog/inside-macos-window-internals) and [the no-foreground contract](https://cua.ai/docs/explanation/the-no-foreground-contract).
  - Clicks go through SkyLight `SLEventPostToPid`, stamped with the target pid and window ids, with a primer click so Chromium accepts them.
  - Keys go through `SLEventPostToPid` with an authentication message attached.
  - It tries AX actions before pixels.
  - Reactive guards undo self-activation and menu focus theft.
  - Screenshots use ScreenCaptureKit per-window capture.
- **Codex computer use** runs on your real displays with per-process events and after-the-fact focus correction. **Claude computer use** is foreground by design. Neither uses a separate display.

## The hard problems in this design

The prototype stopped activation by injecting a library into copies of apps. We don't do that here, so every protection has to come from outside the app.

1. **Opening a window without it flashing on your screen or activating the app.** Chromium's normal "new window" path shows the window on the current screen and activates the app. Candidates, in order of preference:
   - **CDP** `Target.createTarget({newWindow: true, background: true, left, top, width, height})`. This creates the window at agent-display coordinates before it's shown, and possibly without activating the app. It needs remote debugging on your real profile. Chromium 144+ offers this with the `chrome://inspect/#remote-debugging` toggle; Helium runs Chromium 154. cua-driver's `browser_prepare` already automates the toggle.
   - **AppleScript** `make new window with properties {bounds: …}`. It works in every Chromium browser and in Safari, but the window probably shows first and moves after, and activation is likely.
   - **Make the agent display that app's "current screen" first.** AppKit puts new windows on the screen of the app's key window. If the agent already owns a window of that app on the agent display, new windows may open there.
   - **Last resort:** let the window appear, move it immediately with AX, and restore your frontmost app. This flashes, so it's acceptable only if nothing else works.
2. **Sharing one app process with you.** The agent's Helium window and yours share one process, so they share one "key window":
   - If the agent makes its window key while you're typing in Helium, your keystrokes go to the agent's window. cua-driver's pixel-click path does make the window key, so **browser input has to go through CDP**. CDP input goes straight into the page's renderer and never changes which window is key.
   - Native apps you're actively using get AX-only actions (`AXPress`, value writes), which don't need key status. Otherwise the agent waits until you've left that app.
3. **Chromium's "last active window".** Links you open from other apps, `cmd+N` and restored sessions all go to the browser's last active window. That must never be the agent's window, or your link opens somewhere invisible. Using only CDP input and never making the window key should keep it that way. Verify it.
4. **Leftovers.**
   - The agent's window shows in the app's Window menu and in `cmd+``.
   - If you quit Helium mid-task, session restore may bring the agent's window back onto your screen.
   - Fix by closing agent windows the moment a task ends, and by watching for reopened windows that land on your screens.
5. **Single-window apps** (Messages, Spotify, Calculator). There's no new window to open:
   - If you aren't using the app, move its window to the agent display while working and move it back afterward.
   - If you are using it, work in place with AX only, or wait.

## Browser-agnostic

- The tool reads your default browser from LaunchServices (the `https` handler) and tells the agent to use it. Agents don't hardcode a browser.
- **Chromium family** (Helium, Chrome, Arc, Brave, Edge, Dia): CDP route, full support.
- **Safari:** no CDP. Use AppleScript for windows and tabs (`do JavaScript` needs the Develop menu setting), AX for input, cua pixel input as fallback.
- **Firefox:** WebDriver BiDi needs a launch flag, so it's limited to AX/pixel until then.

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
        ├─ windows:  open/move windows onto the agent display, close on task end
        ├─ browser:  default-browser detection, CDP sessions into the real profile
        ├─ guard:    frontmost/key-window/cursor/new-window watchdog, kill switch
        └─ input:    cua-driver (vendored), AX first, pixel fallback
```

- **bgcud** is signed with a Developer ID, so Accessibility, Screen Recording and Automation (Apple Events) grants survive rebuilds. All grants are requested once at setup.
- **Display lifetime.** The display exists while the daemon runs. If the daemon dies, macOS moves the agent's windows onto your screen. The daemon closes them on clean exit, and a small watchdog closes them on a crash.
- **MCP tools.** cua-driver's tools, scoped to agent-display windows: `get_window_state`, `click`, `type_text`, `set_value`, `press_key`, `hotkey`, `scroll`, `drag`, `invoke_menu`. Plus:
  - `browser_open(url)`: a new window in your default browser on the agent display. Returns a CDP-backed handle.
  - `browser_*`: navigate, click, type, evaluate, screenshot through CDP.
  - `app_open(app)`: a new window, or borrows the existing one.
  - `release`: close or return windows.
  - `workspace_screenshot`
  - `handoff(window)`: moves a window onto your screen when you want to take over, for example a 2FA prompt.
  - `guard_report`

## The focus contract, made testable

An automated test types a known string into TextEdit on your display, nonstop, while the agent works in Helium and a native app. Each test fails on:
- a dropped or misrouted keystroke
- any change of frontmost app, key window or focused element on your side
- any movement of the real cursor
- any new window appearing on your displays, even for one frame
- a sound, a TCC prompt or a Space switch

The same watchdog runs in production. A violation pauses the agent and logs the action that caused it.

## Phases

**0. Spike: Helium, end to end (2–3 days).** Before building anything:
1. Bring up the virtual display and the TextEdit typing test.
2. Try each window-opening method above on your running Helium. Record which ones create a window on the agent display with zero flash and no activation.
3. With you typing in your own Helium window, have the agent fill a form in its window through CDP. Pass means zero stolen keystrokes and your window stays key and last-active.
4. Repeat with Notes (multi-window) and Messages (single-window), using cua-driver AX actions.

Everything after this depends on the results.

**1. Daemon + MCP.** bgcud with the display, guard and window manager. bgcu exposes the MCP tools. Vendor cua-driver as a pinned submodule. Signed build and a setup flow for permissions.

**2. Browser.** Default-browser detection, the remote-debugging toggle, CDP windows, and cleanup when tasks end. Chromium family first, then Safari.

**3. Native apps.** New-window or borrow-and-return per app, AX-first input, and handling for the case where you're using the app at the same time.

**4. Agents.** Register as an MCP server for Claude Code and Codex. Add a short skill telling agents the order: CDP for the web, AX, then pixel, never foreground, and use the default browser.

**5. Viewer (optional).** A small live view of the agent display (ScreenCaptureKit stream) for watching and taking over.
