# Background Computer Use for Windows

The Windows version of the app: agents work in your real, logged-in Windows apps, in windows on a virtual monitor you don't see, while you keep using your PC. It's a separate app from the Mac one (Rust, in this folder). The two share only what agents see: the tool definitions (`../shared/tools.json`) and the skill (`../skills`).

Work in progress. See "Status" below.

## How it works

- **The agent screen.** Agents work on a 1600x1000 monitor that only exists in software, from the open-source [Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver) (MIT). Windows draw on it like on any monitor, so browsers need nothing special, and you never see it. There's one, at 30 Hz, drawn on the graphics adapter of your main screen, and agent sessions share it (each `bcu mcp` with its own thread, and its own windows). It touches your screens only at the bottom-right corner of the right-most one, and a low-level mouse hook plus an 8 ms watcher keep the pointer off it.
- **Turning it on, safely.** Setup installs the driver (Windows asks for admin once), then measures how long the compositor takes per frame before and after turning the screen on, and turns it back off if Windows slowed down. Before 0.1.22, setup added four of these at 60 Hz, on whichever GPU the driver picked: on an older Zenbook laptop that made every window update slowly, while the pointer still moved. 0.1.22 sets those up again as one, with the same check. "Agent screen" in the tray's menu turns it off and on.
- **Without it, agents can't open windows.** Over Remote Desktop (which can't show it), before it's set up, when Windows didn't start its driver, after it turned itself off because Windows slowed down, or when you turned it off, `status` and `open_window` tell the agent why, and the tray's preview says it's off. (0.1.22 builds briefly put agents' windows far off every display instead. Chromium browsers stop drawing such windows unless started with a switch, so the user's browser had to restart, and moving a window there that opened maximized crashed Helium. That's gone.)
- **Reading windows.** UI Automation, the API screen readers use. One cross-process call fetches a window's whole tree (`BuildUpdatedCache` with a subtree scope), and elements keep their numbers between reads by their UI Automation runtime id, with the same diff rules as the Mac app.
- **Background input.** Clicks, keys and text are window messages posted straight to the agent's window, so your cursor, keyboard focus and foreground window don't move. For shortcuts, the app shares the target thread's input state for the moment of the key press (`AttachThreadInput`) and marks the modifiers down in it (`SetKeyboardState`), because apps read modifiers with `GetKeyState`.
- **New windows never show on your screen.** An app creates and shows a window on its own UI thread, and only takes a move from another process once that thread gets back to its messages, after the window is on screen: moved from outside, a new Notepad window was on your screen for 16-33 ms and a new Edge window, maximized over the whole screen, for 38 ms. So `bcu_hook.dll` (`hook/`) is loaded into the processes an agent opens windows in, with an in-context WinEvent hook (`SetWinEventHook` with `WINEVENT_INCONTEXT`, the way screen readers watch apps). Its callback runs on the app's thread as the app creates, positions and shows the window, so the window is on the agent's screen before it's ever shown. While the agent has windows in a process, the same hook puts them back if the app moves them onto your screen, keeps their popups (menus, dropdowns, bubbles) off your screen, and gives the foreground back from inside the app when a new window activates itself. A window that opens maximized isn't restored from inside the app while it's showing it (that crashed Chromium: Helium 143, which reopens maximized, closed at once): it's moved as it is, and the app is asked to restore it once it's done, as a click on Restore would. Only processes the agent opens or has windows in get the DLL, never every app. The app learns what to move from a table in shared memory (`Local\BackgroundComputerUse-windows`). A process the shell starts through a broker (packaged apps like Notepad) is hooked at its first helper window, ~100 ms before its main one. For apps the DLL can't load into (UWP, elevated), the same moves are made from outside, right as the window shows.
- **Focus guard.** Some apps take the foreground when the agent acts on them: Chromium and UWP apps do when an element is invoked through UI Automation, and new windows activate themselves. The guard watches the foreground and gives it straight back to your window with `SwitchToThisWindow` (about 1 ms). A key you press while an agent window is in front is held and replayed into your window.
- **Screenshots.** `PrintWindow` with `PW_RENDERFULLCONTENT`, which reads the window's own surface from the compositor: no capture border, and it works for windows no one can see.
- **Tray.** The Mac's menu bar icon (a display outline, with a cursor while an agent works, a dot when one needs you, bars when paused), and the Mac's popover: a live preview of each agent's monitor with its name, apps and the agent's pointer, pause and stop for all of them, a banner when an agent hands you a window, and a click on a preview to expand it. Previews are copies of the agent monitors' screen area, 10–20 times a second, only while the popover or the expanded view is open.

## Measured (Windows 11 26300, Hyper-V VM, Edge as the agent's browser, Notepad as yours)

| Question | Result |
| --- | --- |
| Posted clicks, characters and keys to a background Chromium window | Work. The page sees `mousedown`/`click`, typed text and keys, and the foreground never moves. |
| Shortcuts (Ctrl+A, Ctrl+L, Shift+Right) | Work once the target thread's key state has the modifiers down. Ctrl+L focuses Edge's address bar. |
| Posted input to a UWP app (Calculator) | Characters work; clicks don't. Its buttons are pressed through UI Automation instead. |
| UI Automation Invoke / SetValue | Work in the background, but Chromium and UWP apps take the foreground (0 ms after the call). |
| Giving the foreground back | `SwitchToThisWindow` 1.2 ms, UI Automation `SetFocus` on your element 1.3 ms, `AttachThreadInput` + `SetForegroundWindow` 9 ms. Plain `SetForegroundWindow` fails, and the ALT-key trick works but leaves your app's menu bar focused. |
| A window covered by another, or off every monitor | Stops drawing, and Chromium removes its web content from UI Automation. |
| The same window on the virtual monitor | Keeps drawing, readable through UI Automation, captured cleanly. |
| Monitor placement | Windows allows the virtual monitor to touch the primary at a single corner. Gaps are snapped closed. |
| A new window of a running app | Opens next to that app's last active window (so on the agent monitor once an agent window is there), and takes the foreground. |
| Time a new window was on your screen, over Remote Desktop (Windows 11 26300, Chrome 156, Notepad) | Before `bcu_hook.dll`: Notepad 33 ms, Edge 38 ms maximized, Chrome 72 ms. With it: 0 ms for Notepad, a fresh Chrome and a second Chrome window (already off-screen when Windows first showed them), and no foreground change. Chrome's bubbles went from 3-7 ms on your screen to none. |

The probe that measured these is `probe/` (`bcu-probe.exe`), with the scripts in `probe/phase0/`.

End to end (`probe/phase0/e2e.ps1`): with a simulated user typing three sentences into Notepad in front, the agent opened Edge on its monitor, typed a URL, clicked, typed into fields, pressed Ctrl+A and Ctrl+L, set a value through UI Automation, scrolled, batched, took a screenshot and closed the window. Edge took the foreground once (on the UI Automation write) and the guard gave it back in 0.3–0.5 ms. All 174 characters landed in Notepad and nothing else did, in two runs out of two. A raw MCP session over `bcu mcp` worked too.

## Over Remote Desktop

A Remote Desktop session only has Remote Desktop's own displays. The agent screen belongs to the computer's own session, so agents can't open windows from a remote session; they're told so.

- **Disconnecting.** Over Remote Desktop, the app offers a task, "Background Computer Use keep drawing", that runs as SYSTEM when a session disconnects. If the app runs in that session and nobody is signed in at the computer, it moves the session onto the computer's display with `tscon`, where the agent screen is. The app locks the session when it arrives there (a console connect within 30 s of a remote disconnect). Measured: the session was moved 3.1 s after the disconnect and locked, and screenshots stayed live. Between `tscon` and the lock, the session is unlocked on the computer's display; that moment wasn't measured. The task's script is in `%ProgramFiles%\Background Computer Use`, where only admins can change it.
- **Reconnecting.** Windows moves the agent's windows onto the remote session's screen; the app puts them back on the agent screen once it's there again.

## Setup

The first launch opens a setup window, like the Mac app's onboarding: what the app does, setting up the agent screen (Windows asks for admin once; the step says what happened, or why it's off), connecting Claude Code and Codex (`bcu connect`), and opening at sign-in. "Set up…" in the tray's menu opens it again. If the agent screen's driver isn't installed (a PC set up with a 0.1.22 test build, say), the window opens at that step when the app starts.

## Status

Built: keeping new windows off the user's screen from inside the app (`bcu_hook.dll`), the MCP server (`bcu.exe mcp`), the pipe between it and the app, running the engine inside another app (`bcu serve`, the host protocol, its frames, recordings and take-over: see [docs/embedding.md](../docs/embedding.md#windows)), `navigate`, `press_menu_item`, the UI Automation listing and diff, posted click/type/key/scroll/drag, set_value, perform_action, batch, screenshots, open_window, borrow_window, release_window, handoff/take_back, the focus guard, the agent screen (shared, a thread per agent session), the tray icon and its live preview, and the first-run setup window.

Not yet: taking over an agent's monitor from the tray's expanded view, sound, crash cleanup, testing on a real PC with a real agent. Agents share one agent screen, so their windows can cover each other.

## Install, updates and releases

- **Installer.** `BackgroundComputerUse-Setup-X.Y.Z.exe` (`setup/`) installs for the current user, with no admin prompt, in `%LOCALAPPDATA%\Programs\Background Computer Use`, with a Start menu shortcut and an entry in Settings > Apps. It closes a running copy first, and moves a file that's in use (an agent's `bcu.exe`) aside instead of failing. Uninstalling removes the app and its settings, and, with Windows' admin prompt, the monitor driver, the certificates older versions trusted to install it, and the keep-drawing task (`install-monitor.ps1 -Remove`).
- **Updates.** Like the Mac app: the app checks app-hosting's `appcast-windows.xml` an hour apart, downloads a newer installer, checks its Ed25519 signature against the same key the Mac app's Sparkle uses, and installs it once no agent has a window or a call in the last minute. The tray menus have "Check for updates" and, when one is ready, "Restart to update".
- **Releases.** A `vX.Y.Z` tag releases both apps: `apps.json` `builds.windows` runs `build.ps1` on app-hosting's Windows runner, which builds, signs the exes with Artifact Signing, and packs the installer; the workflow signs and publishes it. Pull requests that touch the Windows app build it the same way on GitHub's runner (`.github/workflows/windows.yml`).

## Build

On Windows: `cargo build --release` in this folder (Rust with the MSVC toolchain). The engine is a library (`app/src/lib.rs`) that both the tray app and `bcu.exe` (for `bcu serve`) are built on.

`BCU_WINDOWS_LIVE=1 node --test test/windows.test.ts` in `clients/typescript` tests a host's side end to end on a PC or VM with the agent screen on and no engine running: `bcu serve`, helper agents in Notepad and Edge while a simulated user types in front, frames, recordings, take-over, `navigate` and `press_menu_item`, stop, pause, handoff, quitting, and the tray app running the engine.

On a Mac, for test loops: `./build-from-mac.sh` cross-compiles with its own rustup and the MSVC libraries fetched by `xwin`, and `./pack-for-vm.sh` uploads a zip of the binaries and probe scripts for a test VM to download.

The binaries link the C runtime statically, so they run on a fresh Windows install.
