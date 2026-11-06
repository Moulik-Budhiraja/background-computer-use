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
- **Sessions belong to a host.** `bcu mcp --host <id>` tags its session. While a host is subscribed with that ID, the menu bar app leaves those sessions out of its popover, previews, handoff notifications and pause/stop controls, so they show up in only one place. If the host isn't subscribed, the menu bar app shows them like any other session.
- **Permissions are the host's.** macOS attributes a child process's Accessibility, Screen Recording and audio capture to the app that launched it. The host asks for these permissions under its own name, and `hello` reports whether it has them.

## Shipping it

1. Build with `swift build -c release --arch arm64` and copy `.build/release/bcu` into the host's bundle (for electron-builder, `extraResources`; keep it out of `app.asar`). Sign it with the host's Developer ID and hardened runtime, like the rest of the host.
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

// Handoff:
await engine.openHandoff(session.id)   // the window comes onto the user's screen
await engine.handBack(session.id)      // the user is done; the agent resumes
```

`npm test` in that folder runs the protocol tests against a real `bcu serve` in a scratch directory (`BCU_HOME`), so they don't touch an engine you have running. `BCU_LIVE=1 node --test test/live.test.ts` also opens a Calculator window on a test display, streams it, takes over and types into it, then closes it.

## Protocol

The engine reads and writes one JSON object per line on the socket (mode 0600, so only the user's processes can connect). Tool calls (`{"id","tool","args"}`) are what `bcu mcp` sends. A host sends `{"id": 1, "op": "<op>", …}` and gets a single reply with the same `id` and `"ok": true`, or `"ok": false` with `"error"`. Pushed events carry `"event"` and no `id`. Points are display-local, on the session's agent display, with a top-left origin, in points. Frames are at the display's pixel density, twice that. Every type is in [`clients/typescript/src/types.ts`](../clients/typescript/src/types.ts).

| op | params | reply / effect |
|---|---|---|
| `hello` | | `engine`: protocol, version, owner, pid, permissions, max displays, display size |
| `catalog` | | the engine's `tools` and MCP `instructions` (`bcu mcp` uses these, so a host's `bcu` and an engine of another version agree) |
| `subscribe` | `host` or `all: true` | pushes `sessions` (now, then on every change, at most every 50 ms) and `pointer` for those sessions. With `host`, the menu bar app leaves those sessions to this client until it disconnects. |
| `unsubscribe` | | |
| `sessions` | `host` or `all` | the same list, once |
| `pause` | `session`, `paused` | the agent's next action fails with "Paused by the user" |
| `stop` | `session` | releases every window of the session |
| `take_over` | `session`, `on` | the user drives the display through `input`; the agent's actions (not its reads) are refused. Ends when the client disconnects. |
| `input` | `session`, `events: [InputEvent]` | DOM-style mouse, wheel and key events, posted to the window under the point (see `types.ts`). cmd+Q is dropped. |
| `menu_pick` | `session`, `token`, `path` | picks an item from a `menu` event |
| `open_handoff` | `session`, `area?` | brings the handed-off window onto the user's screen, in front, in `area` (global points, top-left origin, the same as Electron's `screen`), or by default the screen under the pointer |
| `hand_back` | `session` | handed-off windows go back to the agent display and the session resumes |
| `frames` | `session`, `fps`, `max_width`, `quality`, `window?`, `exclude?` | `stream` ID, then `frame` events: JPEG, the whole display or one window. Use a connection of its own. A frame is skipped while the client is two behind. |
| `frames_update` | `stream`, the same options | |
| `frames_stop` | `stream` | |
| `yield` | | the engine stops once its agents are idle (the menu bar app sends this) |

Events: `sessions`, `pointer`, `frame`, and while this client has a session taken over, `cursor` (the CSS cursor the app under the pointer would show), `menu` (an app menu the engine closed, to show and pick from) and `drag` (a window being moved or resized, which the real window follows about 100 ms later).

`HostServer.protocolVersion` goes up when a change would break an existing client.

## In process (Swift)

A Swift host can link the `BCUCore` library product instead. The menu bar app does: it owns a `Hub` and its UI uses `Engine`, `FrameStream` and `RemoteControl` directly. Take the `EngineLock` first and don't start a `Hub` without it, for the reasons above.

## Windows

The Windows app (`windows/`) is a single binary that doesn't have this split yet. The engine modules (`engine.rs`, `sessions.rs`, `guard.rs` and the rest) would move into a library crate, with `bcu serve` and the same socket protocol over its named pipe.
