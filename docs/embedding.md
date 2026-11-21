# Running computer use inside another app

Another Mac app (a "host", like Proactive Agent) can give its own agents background computer use and show their screens in its own UI. The host decides where the preview goes, where take-over happens and how a handoff reaches the user. The engine is the same one the menu bar app runs: the virtual displays, background input, focus guard and window management. The host doesn't need the Background Computer Use app installed.

## How it fits together

```
host app (Electron, say)
├── bcu serve           the engine, a child process of the host
│     └── socket        ~/Library/Application Support/BackgroundComputerUse/bcu.sock
├── host UI             talks to the socket: sessions, frames, take-over, handoff
└── agents (Agent SDK)
      └── bcu mcp --host <id> --session <id> --label <name>   one per agent
```

- **One engine per Mac.** Two engines would fight: two focus guards putting different apps in front, two cursor fences, two sets of displays. The engine holds a lock (`engine.lock`, next to the socket) for as long as it runs. When `bcu serve` finds another engine running, either the Background Computer Use app's or another host's, it says so and exits, and the host uses that engine through the same socket. If the app is installed but not running, `bcu serve` starts it in the background and uses its engine, as long as the app has its permissions and speaks the same protocol (it records both in `app.json`, next to the lock). Otherwise the agents that use the app's own `bcu`, such as Claude Code's, would end up on the host's engine, where nothing shows them. `--own-engine` skips this. If the Background Computer Use app starts while a host's engine runs, it asks that engine to step aside (`yield`). The engine stops once no agent of its own has a window open or has made a call in the last 3 seconds. The app takes over from there, and the agents' `bcu mcp` connect to it on their next call.
- **Sessions belong to a host.** `bcu mcp --host <id>` tags its session. The menu bar app shows a host's sessions like its own, so a Mac has one menu bar icon for every agent: they count toward the icon's state, get a tile in the popover with the host app's icon beside their label, and its pause, stop and expanded view (take-over included) work on them. `hello` says `shows_hosts: true` when the menu bar app runs the engine, so the host can leave out a menu bar icon of its own; a host's own `bcu serve` doesn't say it. While the host is subscribed with that ID, the menu bar app leaves those sessions' handoff notifications to it, and when the user stops one from the menu bar app the host gets a `stopped` event. The menu bar app's history doesn't have them: see recordings, below.
- **Recordings are the host's.** The engine can record each agent display, as the menu bar app's history does. A host's sessions are recorded only after it asks with `recordings`, into a folder it picks, and it keeps that folder's size and age in check the same way. The menu bar app records only its own sessions, into its own folder. Neither sees the other's.
- **Permissions are the host's.** macOS attributes a child process's Accessibility, Screen Recording and audio capture to the app that launched it. The host asks for these permissions under its own name, and `hello` reports whether it has them.
- **Only signed apps connect.** The engine checks the code signature of every process that connects to the socket (see [Who can connect](#who-can-connect)), so a script or another program can't use the permissions the user gave the engine's app. A host's own processes and its `bcu` pass as long as they're signed with its Developer ID and the `bcu` is in its bundle.

## Shipping it

1. Build with `swift build -c release --arch arm64` and copy `.build/release/bcu` into the host's bundle, at `Contents/Resources/bcu`, `Contents/Resources/<folder>/bcu`, `Contents/MacOS/bcu` or `Contents/Helpers/bcu` (for electron-builder, `extraResources`; keep it out of `app.asar`). Sign it with the host's Developer ID and hardened runtime, like the rest of the host. The engine lets the host's processes in because that `bcu` is there, signed by the same team as them.
2. Add `NSAudioCaptureUsageDescription` to the host's Info.plist. The engine keeps sound from apps only agents use off the speakers with a Core Audio process tap.
3. Ask the user for Accessibility (`systemPreferences.isTrustedAccessibilityClient(true)` in Electron) and Screen Recording.
4. When the host launches, start the engine: `bcu serve --owner "<Host name>" [--log-dir <dir>]`. Its first line on stdout is either `{"event":"ready",…}` (this process is the engine) or `{"event":"running","owner":…}` (another engine runs it, maybe the app it just started, and this process exits). Starting the app can take up to 25 s. Either way, connect to `socket` from that line. When the connection closes, the engine went away (the user quit the app, say): run `bcu serve` again. An engine of the host's own stops when the host exits, and it releases its windows first. SIGTERM does the same.
5. Give each agent its MCP server: `bcu mcp --host <host id> --session <your id for it> --label "<name in your UI>"`. `--session` lets the UI match a session to the agent (say, a helper's ID). A subagent's session is `<session>/<agent>`. If the engine isn't up yet, `bcu mcp` waits up to 15 s for it. A `bcu` inside another app never launches the Background Computer Use app.

The skill (`skills/background-computer-use/SKILL.md`) is the longer guide for agents. A host can put it in its agents' prompts or skills, and `bcu docs` prints everything an agent is told.

## The TypeScript client

[`clients/typescript`](../clients/typescript) is a dependency-free client for Node and Electron. It needs Node 22.18 or later to run the `.ts` files directly, or a bundler such as electron-vite.

```ts
import { EngineClient, mcpServer, startEngine } from '@background-computer-use/client'

const bcu = join(process.resourcesPath, 'bcu')
const started = await startEngine({ bcu, owner: 'Proactive Agent' })
const engine = await EngineClient.connect({ path: started.socket, waitMs: 5000 })
await engine.subscribe({ host: 'proactive-agent' })
engine.on('sessions', (sessions) => { /* status, windows, handoff, display */ })
engine.on('pointer', (p) => { /* where the agent is about to act */ })
engine.on('close', () => { /* engine went away: startEngine again */ })

// In the Agent SDK options for a helper:
mcpServers: { 'computer-use': mcpServer({ bcu, host: 'proactive-agent', session: helper.id, label: helper.title }) }

// A preview (send frames to the renderer as data URLs):
const frames = await engine.frames(session.id, { fps: 15, maxWidth: 1600 })
frames.on('frame', (f) => show(`data:${f.mime};base64,${f.data}`))

// Take-over, from DOM events on the preview (see the `./dom` export):
await engine.takeOver(session.id)
await engine.input(session.id, mouseInput(event, previewElement, session.display))
await engine.takeOver(session.id, false)

// Recording (off until you ask; the folder is yours to show and to clean up):
await engine.setRecordings({ host: 'proactive-agent', directory: join(app.getPath('userData'), 'recordings') })

// Handoff:
await engine.openHandoff(session.id)   // the window comes onto the user's screen
await engine.handBack(session.id)      // the user is done; the agent resumes
```

`npm test` in that folder runs the protocol tests against a real `bcu serve` in a scratch directory (`BCU_HOME`), so they don't touch an engine you have running. `BCU_LIVE=1 node --test test/live.test.ts` also opens a Calculator window on a test display, streams it, takes over and types into it, then closes it.

## Protocol

The engine reads and writes one JSON object per line on the socket (mode 0600, so only the user's processes can connect, and only those [it lets in](#who-can-connect)). Tool calls (`{"id","tool","args"}`) are what `bcu mcp` sends. A host sends `{"id": 1, "op": "<op>", …}` and gets a single reply with the same `id` and `"ok": true`, or `"ok": false` with `"error"`. Pushed events carry `"event"` and no `id`. Points are display-local, on the session's agent display, with a top-left origin, in points. Frames are at the display's pixel density, twice that. Every type is in [`clients/typescript/src/types.ts`](../clients/typescript/src/types.ts).

| op | params | reply / effect |
|---|---|---|
| `hello` | | `engine`: protocol, version, owner, pid, permissions, max displays, display size, and `shows_hosts: true` when the menu bar app runs it |
| `catalog` | | the engine's `tools` and MCP `instructions` (`bcu mcp` uses these, so a host's `bcu` and an engine of another version agree) |
| `subscribe` | `host` or `all: true` | pushes `sessions` (now, then on every change, at most every 50 ms) and `pointer` for those sessions. With `host`, the menu bar app leaves those sessions' handoff notifications to this client, and tells it when the user stops one, until it disconnects. |
| `unsubscribe` | | |
| `recordings` | `host`, `directory` (absolute; leave it out to stop), `limit_mb` (300, at least 50), `retention_days` (7) | records the host's sessions into `directory`, one folder per agent display (the layout is in `Sources/BCUCore/Recorder.swift`). Off until a host asks. Lasts until the engine stops, so send it again after connecting to a new engine. |
| `sessions` | `host` or `all` | the same list, once |
| `pause` | `session`, `paused` | the agent's next action fails with "Paused by the user" |
| `stop` | `session` | releases every window of the session |
| `rename` | `session`, `label` | the session goes by `label` from now on, in the menu bar and the run being recorded |
| `take_over` | `session`, `on` | the user drives the display through `input`; the agent's actions (not its reads) are refused. Ends when the client disconnects. With several clients (or the menu bar viewer) in control, the agent gets the display back once all of them have let go. |
| `input` | `session`, `events: [InputEvent]` | DOM-style mouse, wheel and key events, posted to the window under the point (see `types.ts`). cmd+Q is dropped. |
| `menu_pick` | `session`, `token`, `path` | picks an item from a `menu` event |
| `open_handoff` | `session`, `area?` | brings the handed-off window onto the user's screen, in front, in `area` (global points, top-left origin, the same as Electron's `screen`), or by default the screen under the pointer |
| `hand_back` | `session` | handed-off windows go back to the agent display and the session resumes |
| `frames` | `session`, `fps`, `max_width`, `quality`, `window?`, `exclude?` | `stream` ID, then `frame` events: JPEG, the whole display or one window. Use a connection of its own. A frame is skipped while the client is two behind. |
| `frames_update` | `stream`, the same options | |
| `frames_stop` | `stream` | |
| `yield` | | the engine stops once its agents are idle (the menu bar app sends this) |

Events: `rejected` (the first and only line to a client the engine [won't let in](#who-can-connect), with `ok: false` and `error` saying why; then it closes the connection), `sessions`, `pointer`, `frame`, `stopped` (`{"event":"stopped","session":…}`: the user stopped that session from the menu bar app and its windows are released; a client's own `stop` isn't echoed), and while this client has a session taken over, `cursor` (the CSS cursor the app under the pointer would show), `menu` (an app menu the engine closed, to show and pick from) and `drag` (a window being moved or resized, which the real window follows about 100 ms later).

`HostServer.protocolVersion` goes up when a change would break an existing client.

## Who can connect

When a process connects, the engine reads its code signature through the socket's audit token (`PeerCheck.swift`) and lets it in if one of these holds:

- It's signed by the same Developer ID team as the engine. That covers the menu bar app's own `bcu` (what Claude Code and Codex run), and, when the engine is a host's `bcu serve`, the host's own processes.
- It's the same binary as the engine (the same code directory hash): a `bcu mcp` or `bcu call` next to its `bcu serve`.
- The engine is an ad hoc build with no team (a development build), and the process is inside the engine's own app bundle, or its folder for a bare `bcu`.
- It's signed by another team, the outermost app bundle it's in is signed by that same team with its seal intact, and that app ships a `bcu`, at one of the places in step 1 of [Shipping it](#shipping-it), signed by the same team. The process has to be the code in that bundle as it is on disk. This is how a host's UI and its agents' `bcu mcp` use the menu bar app's engine, and how the menu bar app asks a host's engine to `yield`.
- `bcu serve --trust-client <team ID or path>` names it (`trustClients` in `startEngine`). A path can be a program, an app or a folder. An app's main executable (Electron's `process.execPath`) stands for its app. This is for development: an Electron host run with `electron .` is Electron's binary, signed by Electron's team, so its engine has to be started with `trustClients: [process.execPath]`. The protocol tests do the same for `node`.
- The menu bar app's `trustClients` setting names it: `defaults write dev.moulik.BackgroundComputerUse trustClients -array-add <team ID or path>`. This is for developing a host on a Mac where the menu bar app runs the engine, which is every Mac that has the app open: a host's own `bcu serve` steps aside for it there, so `--trust-client` never applies. The app reads the setting each time it would refuse a client, so it needs no restart. Any program running as the user can write this setting, just as it can run the app's `bcu call`, so the setting adds no new way in.

A team only counts when a certificate issued by Apple vouches for it. Everything else, including Apple's own programs (`python3`, `nc`, `osascript`) and programs from other developers that don't ship `bcu`, gets one `rejected` line and the connection closes.

A client let in under another team's app sees and drives only what its team started. `sessions` and `subscribe` list only those sessions, and the session ops (`pause`, `take_over`, `frames` and the rest) treat any other session as missing. A session belongs to the team whose client made its first tool call, and a host ID belongs to the first team that names it in `subscribe`, `recordings` or a tool call, the engine's own team included. Tool calls from another team for that session or host ID are refused, and so are calls that name a window of another team's session. A subagent's first call claims its parent session too. A tool call from another team has to name its session (`_session`, which `bcu mcp --session` sets): the default session that `bcu call` uses is the engine's own. A `frames` stream shows only windows of the session it's for. The engine's own team sees everything, as before.

Hosts on Electron should turn off the `RunAsNode` and `EnableNodeCliInspectArguments` fuses (`@electron/fuses`), so nobody can run their own script as the host's signed binary. The same goes for any interpreter a host ships signed with its team.

## In process (Swift)

A Swift host can link the `BCUCore` library product instead. The menu bar app does: it owns a `Hub` and its UI uses `Engine`, `FrameStream` and `RemoteControl` directly. Take the `EngineLock` first and don't start a `Hub` without it, for the reasons above.

## Windows

The Windows engine speaks the same protocol over a named pipe, and a host runs it the same way: `bcu serve` as a child process, `bcu mcp --host --session --label` for each agent, and the TypeScript client for the rest. `bcu.exe` is the engine as well as its command line (the engine is a library, `windows/app/src/lib.rs`, that the tray app runs too).

```
host app (Electron, say)
├── bcu serve            a relay: the engine runs as `bcu serve-engine`, its own process
│     └── pipe           \\.\pipe\BackgroundComputerUse-<user>
├── host UI              talks to the pipe: sessions, frames, stop, handoff
└── agents
      └── bcu mcp --host <id> --session <id> --label <name>
```

### Shipping it

1. Build with `cargo build --release` in `windows/` and ship `bcu.exe`, `bcu_hook.dll` and `install-monitor.ps1` together in one folder of the host (for electron-builder, `extraResources`, outside `app.asar`). The engine loads `bcu_hook.dll` into the apps agents open windows in, from next to `bcu.exe`.
2. Agents work on a virtual monitor, from the Virtual Display Driver. `hello` says whether it's on (`permissions.agent_screen`) and, when it isn't, why (`agent_screen_problem`, which is also what agents are told). `bcu screen on` turns it on, installing the driver the first time (Windows asks for admin once, which needs `install-monitor.ps1` next to `bcu.exe`); `bcu screen` (status) and `bcu screen off` are the rest. Each prints one JSON line: `{"on", "driver_installed", "problem"?, "message"?}`. A PC where the Background Computer Use app is set up already has it. Windows asks for nothing like Accessibility or Screen Recording, so those two are always `true`.
3. When the host launches, `bcu serve --owner "<Host name>" [--log-dir <dir>]`, as on the Mac (`startEngine` hides its console window). The engine stops, releasing its agents' windows first (it closes the ones they opened and puts borrowed ones back), when the host exits or crashes, when the host kills the process it started (Node's `kill()`, whatever the signal), when the host writes `quit` on its stdin or closes it, and on Ctrl+C. Node starts children in a job that kills them all when it exits, which would end the engine before it could release anything, so the process the host starts is a relay that runs the engine outside that job and waits for it; the engine watches the relay and the host.
4. Give each agent `bcu mcp --host <host id> --session <your id for it> --label "<name>"`. A subagent's session is `<session>/<agent>`, for Claude Code's subagents and Codex's threads, as on the Mac, and a call a subagent makes on its parent's window (or the other way round) goes to the session that has it. A `bcu` inside a host never starts the Background Computer Use app; with no engine up, it waits up to 15 s for one.

### One engine per user

The pipe is per user, and creating it is what makes a process the engine. When `bcu serve` finds an engine on it (the tray app's, or another host's), it says `running` and exits. When the tray app is installed and set up (its onboarding done, the driver installed) but not running, `bcu serve` starts it and uses its engine, as on the Mac, unless `--own-engine`; the app records where it is and which protocol it speaks in `%APPDATA%\BackgroundComputerUse\app.json`. When the tray app starts while a host's engine runs, it asks that engine to `yield`, and starts its own once the host's has stopped, which it does once its agents have no windows and made no call in the last 3 seconds. The tray app shows a host's sessions with its own (`hello` says `shows_hosts`), and when the user stops one from it the host gets `stopped`.

### Who can connect

The pipe lets in the signed-in user's processes and SYSTEM, and no remote clients. There's no code signature check like the Mac's, so every process of the user can connect, a host's included; `--trust-client` is accepted and changes nothing, and every client sees every session it asks for.

### What's different from the Mac

- `socket` is the pipe's name. `socketPath()` in the TypeScript client gives it on Windows.
- Agents share one agent screen, 1600x1000 at 100% (`max_displays` is 1), so points are pixels and a frame is at most 1600 wide. A session has a `display` from its first window until a minute after its last one closes.
- A frame is a copy of the agent screen. When a window of a session outside the stream's session family (itself, its parent, its subagents) is on the screen too, the frame is drawn from the family's own windows and their menus instead, so it doesn't show other agents' work. A frame that shows nothing new is sent at most once a second.
- A window has `exe`, the app's executable's full path, where the Mac has `bundle_id`. `kind` is `opened` or `borrowed`.
- `handoff` puts the window on the user's screen at once, so `with_user` is the same as `handed_off`. `open_handoff` brings it to the front, inside `area` when given (screen pixels). `hand_back` takes it back unless it's the window in front, the way the agent's own `take_back` does.
- `hello` has `platform: "windows"`, and `permissions.agent_screen` and `agent_screen_problem` as above.
- Recordings (`recordings`, same arguments and reply) are in the Mac's layout without the video: each run's frames stay JPEGs in `staging/`, with no `chunks.jsonl` or `chunk-*.mp4`. They're 1600x1000, the picture a preview of the session shows. A frame's `b` is the exe of the app in front where the Mac's is its bundle ID. Captures wait while the user is typing or clicking, 2 s at most: copying the screen goes through the compositor, and on a weak GPU that can hold up their input. The size limit deletes the oldest frames first, and whole runs once nothing of them is left.
- Not built yet: `take_over`, `input`, `menu_pick` and their events (`cursor`, `menu`, `drag`), and the `navigate` and `press_menu_item` tools. Requests for them get `unknown op`.
