# Background Computer Use for Windows

The Windows version of the app: agents work in your real, logged-in Windows apps, in windows on a virtual monitor you don't see, while you keep using your PC. It's a separate app from the Mac one (Rust, in this folder). The two share only what agents see: the tool definitions (`../shared/tools.json`) and the skill (`../skills`).

Work in progress. See "Status" below.

## How it works

- **A monitor per agent.** The open-source [Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver) (MIT) adds four 1600x1000 monitors that only exist in software, and each agent session (each `bcu mcp`) gets one to itself, with its own thread, so agents work side by side. The driver reloads every monitor when the count changes, so the count is set once when the app starts, before any agent has a window. The app puts them in a row touching your screens at their bottom-right corner only, and a low-level mouse hook plus an 8 ms watcher keep the pointer off them. Agent windows live there because Windows stops drawing a window that's covered or off-screen, and Chromium then drops its page from UI Automation too.
- **Reading windows.** UI Automation, the API screen readers use. One cross-process call fetches a window's whole tree (`BuildUpdatedCache` with a subtree scope), and elements keep their numbers between reads by their UI Automation runtime id, with the same diff rules as the Mac app.
- **Background input.** Clicks, keys and text are window messages posted straight to the agent's window, so your cursor, keyboard focus and foreground window don't move. For shortcuts, the app shares the target thread's input state for the moment of the key press (`AttachThreadInput`) and marks the modifiers down in it (`SetKeyboardState`), because apps read modifiers with `GetKeyState`.
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

The probe that measured these is `probe/` (`bcu-probe.exe`), with the scripts in `probe/phase0/`.

End to end (`probe/phase0/e2e.ps1`): with a simulated user typing three sentences into Notepad in front, the agent opened Edge on its monitor, typed a URL, clicked, typed into fields, pressed Ctrl+A and Ctrl+L, set a value through UI Automation, scrolled, batched, took a screenshot and closed the window. Edge took the foreground once (on the UI Automation write) and the guard gave it back in 0.3–0.5 ms. All 174 characters landed in Notepad and nothing else did, in two runs out of two. A raw MCP session over `bcu mcp` worked too.

## Status

Built: the MCP server (`bcu.exe mcp`), the pipe between it and the app, the UI Automation listing and diff, posted click/type/key/scroll/drag, set_value, perform_action, batch, screenshots, open_window, borrow_window, release_window, handoff/take_back, the focus guard, a monitor and thread per agent session, the tray icon and its live preview, and a first-run setup (one prompt, then the driver install with Windows' admin prompt, `bcu connect` for Claude Code and Codex, and start at sign-in).

Not yet: taking over an agent's monitor from the expanded view, `press_menu_item`, sound, crash cleanup, testing on a real PC with a real agent. A fifth agent at once shares a monitor with another.

## Install, updates and releases

- **Installer.** `BackgroundComputerUse-Setup-X.Y.Z.exe` (`setup/`) installs for the current user, with no admin prompt, in `%LOCALAPPDATA%\Programs\Background Computer Use`, with a Start menu shortcut and an entry in Settings > Apps. It closes a running copy first, and moves a file that's in use (an agent's `bcu.exe`) aside instead of failing. Uninstalling removes the app but leaves the monitor driver.
- **Updates.** Like the Mac app: the app checks app-hosting's `appcast-windows.xml` an hour apart, downloads a newer installer, checks its Ed25519 signature against the same key the Mac app's Sparkle uses, and installs it once no agent has a window or a call in the last minute. The tray menus have "Check for updates" and, when one is ready, "Restart to update".
- **Releases.** A `vX.Y.Z` tag releases both apps: `apps.json` `builds.windows` runs `build.ps1` on app-hosting's Windows runner, which builds, signs the exes with Artifact Signing, and packs the installer; the workflow signs and publishes it. Pull requests that touch the Windows app build it the same way on GitHub's runner (`.github/workflows/windows.yml`).

## Build

On Windows: `cargo build --release` in this folder (Rust with the MSVC toolchain).

On a Mac, for test loops: `./build-from-mac.sh` cross-compiles with its own rustup and the MSVC libraries fetched by `xwin`, and `./pack-for-vm.sh` uploads a zip of the binaries and probe scripts for a test VM to download.

The binaries link the C runtime statically, so they run on a fresh Windows install.
