// A host app's side of Background Computer Use: start the engine, give your
// agents its MCP server, and show their screens (preview, take-over,
// handoff) wherever your UI wants them. See docs/embedding.md.
import { spawn, type ChildProcess } from 'node:child_process'
import { EventEmitter } from 'node:events'
import { createConnection, type Socket } from 'node:net'
import { homedir } from 'node:os'
import { join } from 'node:path'
import type {
  CursorEvent,
  DragEvent,
  EngineInfo,
  FrameEvent,
  InputEvent,
  MenuEvent,
  PointerEvent,
  Rect,
  Session,
  SessionsEvent
} from './types.ts'

export type * from './types.ts'

// The protocol this client speaks. `hello` says the engine's.
export const PROTOCOL = 1

// Where the engine listens. One engine runs per Mac, whoever started it.
export function socketPath(home = process.env.BCU_HOME): string {
  return join(home || join(homedir(), 'Library/Application Support/BackgroundComputerUse'), 'bcu.sock')
}

export type EngineStart = {
  // This process started the engine (`process` is it), or another one runs
  // it: the Background Computer Use app (already running, or started now
  // because it's installed and set up), or another host.
  kind: 'ready' | 'running'
  socket: string
  pid?: number
  version?: string
  owner?: string
  process?: ChildProcess
}

export type StartOptions = {
  // The `bcu` binary shipped inside your app.
  bcu: string
  // Your app's name, shown as who runs the engine.
  owner: string
  logDir?: string
  // Run your own engine even when the Background Computer Use app is
  // installed. Then agents that use the app's own `bcu` (Claude Code,
  // Codex) run on your engine too, and nothing shows them.
  ownEngine?: boolean
  env?: NodeJS.ProcessEnv
}

// Start the engine as a child of this process, so macOS counts its
// Accessibility and Screen Recording permissions as your app's. It stops when
// this process exits. If an engine is already running, resolves with
// kind "running" and that engine is the one to use. If the Background
// Computer Use app is installed and has its permissions, starts it (in the
// background) and resolves with kind "running": its engine runs your agents
// and its menu bar leaves them to you. Can take up to 25 s then.
export function startEngine(opts: StartOptions): Promise<EngineStart> {
  const args = ['serve', '--owner', opts.owner]
  if (opts.logDir) args.push('--log-dir', opts.logDir)
  if (opts.ownEngine) args.push('--own-engine')
  const child = spawn(opts.bcu, args, { stdio: ['ignore', 'pipe', 'ignore'], env: opts.env ?? process.env })
  return new Promise((resolve, reject) => {
    let buffer = ''
    const fail = (why: string) => reject(new Error(`bcu serve: ${why}`))
    child.once('error', (e) => fail(e.message))
    child.once('exit', (code) => fail(`exited (${code}) before it was ready`))
    child.stdout!.on('data', (chunk: Buffer) => {
      buffer += chunk.toString('utf8')
      const nl = buffer.indexOf('\n')
      if (nl < 0) return
      child.removeAllListeners('exit')
      child.removeAllListeners('error')
      child.stdout!.removeAllListeners('data')
      child.stdout!.resume()
      let line: { event: string; socket: string; pid?: number; version?: string; owner?: string; error?: string }
      try {
        line = JSON.parse(buffer.slice(0, nl))
      } catch {
        return fail(`unexpected output: ${buffer.slice(0, nl)}`)
      }
      if (line.event === 'ready' || line.event === 'running') {
        const { event, ...rest } = line
        resolve({ kind: event, ...rest, process: event === 'ready' ? child : undefined })
      } else {
        fail(line.error ?? buffer.slice(0, nl))
      }
    })
  })
}

export type McpOptions = {
  bcu: string
  // Your app's ID. Sessions with it are yours to show; the Background
  // Computer Use menu bar leaves them out while you're subscribed.
  host: string
  // Your own ID for the session (say, a helper's), so your UI can match it.
  session?: string
  // The name the session goes by in the UI.
  label?: string
}

// The MCP server config for one agent (Claude Agent SDK `mcpServers`).
export function mcpServer(opts: McpOptions): { type: 'stdio'; command: string; args: string[] } {
  const args = ['mcp', '--host', opts.host]
  if (opts.session) args.push('--session', opts.session)
  if (opts.label) args.push('--label', opts.label)
  return { type: 'stdio', command: opts.bcu, args }
}

type Events = {
  sessions: [sessions: Session[], engine: EngineInfo]
  pointer: [PointerEvent]
  frame: [FrameEvent]
  cursor: [CursorEvent]
  menu: [MenuEvent]
  drag: [DragEvent]
  // The engine went away (it quit, or handed over to another one). Call
  // startEngine again and connect to the engine it reports.
  close: []
}

type Pending = { resolve: (v: any) => void; reject: (e: Error) => void }

// One connection to the engine.
export class EngineClient extends EventEmitter<Events> {
  private buffer = ''
  private nextId = 1
  private pending = new Map<number, Pending>()
  private closed = false
  private streams = new Set<FrameStream>()
  private readonly socket: Socket
  readonly path: string

  private constructor(socket: Socket, path: string) {
    super()
    this.socket = socket
    this.path = path
    socket.setEncoding('utf8')
    socket.on('data', (chunk: string) => this.read(chunk))
    socket.on('close', () => this.finish())
    socket.on('error', () => this.finish())
  }

  // Connect, retrying for up to `waitMs` while the engine starts.
  static async connect(opts: { path?: string; waitMs?: number } = {}): Promise<EngineClient> {
    const path = opts.path ?? socketPath()
    const deadline = Date.now() + (opts.waitMs ?? 0)
    for (;;) {
      try {
        const socket = await new Promise<Socket>((resolve, reject) => {
          const s = createConnection(path)
          s.once('connect', () => resolve(s))
          s.once('error', reject)
        })
        return new EngineClient(socket, path)
      } catch (e) {
        if (Date.now() >= deadline) throw e
        await new Promise((r) => setTimeout(r, 200))
      }
    }
  }

  get isClosed(): boolean {
    return this.closed
  }

  close(): void {
    this.socket.destroy()
    this.finish()
  }

  // One request. Rejects with the engine's error.
  request<T = Record<string, unknown>>(op: string, params: Record<string, unknown> = {}): Promise<T> {
    if (this.closed) return Promise.reject(new Error('not connected to the engine'))
    const id = this.nextId++
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve, reject })
      this.socket.write(JSON.stringify({ id, op, ...params }) + '\n')
    })
  }

  hello(): Promise<{ engine: EngineInfo }> {
    return this.request('hello')
  }

  // Push `sessions` (now and on every change) and `pointer` events for your
  // host's sessions, or with `all`, everyone's. Subscribing with your host ID
  // also tells the Background Computer Use menu bar to leave them to you.
  subscribe(opts: { host: string } | { all: true }): Promise<void> {
    return this.request('subscribe', opts).then(() => undefined)
  }

  unsubscribe(): Promise<void> {
    return this.request('unsubscribe').then(() => undefined)
  }

  sessions(opts: { host?: string; all?: boolean } = {}): Promise<{ engine: EngineInfo; sessions: Session[] }> {
    return this.request('sessions', opts)
  }

  pause(session: string, paused = true): Promise<void> {
    return this.request('pause', { session, paused }).then(() => undefined)
  }

  // Release every window the session has and clear what it's waiting on.
  stop(session: string): Promise<void> {
    return this.request('stop', { session }).then(() => undefined)
  }

  // The user drives the agent's display from your preview (send `input`);
  // the agent's actions are refused until you call it with `false`. Ends on
  // its own when this connection closes.
  takeOver(session: string, on = true): Promise<void> {
    return this.request('take_over', { session, on }).then(() => undefined)
  }

  input(session: string, events: InputEvent | InputEvent[]): Promise<void> {
    return this.request('input', { session, events: Array.isArray(events) ? events : [events] }).then(() => undefined)
  }

  // The pick from a `menu` event: the path of indexes down to the item.
  menuPick(session: string, token: number, path: number[]): Promise<void> {
    return this.request('menu_pick', { session, token, path }).then(() => undefined)
  }

  // Bring the window the agent handed off onto the user's screen, in front.
  // `area` is where (global points, top-left origin, like Electron's
  // `screen` API); by default the screen under the pointer.
  openHandoff(session: string, area?: Rect): Promise<void> {
    return this.request('open_handoff', { session, ...(area ? { area } : {}) }).then(() => undefined)
  }

  // The user is done: handed-off windows go back to the agent display and it resumes.
  handBack(session: string): Promise<void> {
    return this.request('hand_back', { session }).then(() => undefined)
  }

  // Live JPEG frames of a session's display (or one window), on a
  // connection of their own so big frames don't hold up events.
  async frames(
    session: string,
    opts: { fps?: number; maxWidth?: number; quality?: number; window?: number; exclude?: number } = {}
  ): Promise<FrameStream> {
    const conn = await EngineClient.connect({ path: this.path })
    const { stream } = await conn.request<{ stream: number }>('frames', {
      session,
      fps: opts.fps,
      max_width: opts.maxWidth,
      quality: opts.quality,
      window: opts.window,
      exclude: opts.exclude
    })
    const s = new FrameStream(conn, stream, () => this.streams.delete(s))
    this.streams.add(s)
    return s
  }

  private read(chunk: string): void {
    this.buffer += chunk
    let nl: number
    while ((nl = this.buffer.indexOf('\n')) >= 0) {
      const line = this.buffer.slice(0, nl)
      this.buffer = this.buffer.slice(nl + 1)
      if (!line) continue
      let msg: any
      try {
        msg = JSON.parse(line)
      } catch {
        continue
      }
      if (msg.event) {
        if (msg.event === 'sessions') {
          const e = msg as SessionsEvent
          this.emit('sessions', e.sessions, e.engine)
        } else {
          this.emit(msg.event, msg)
        }
        continue
      }
      const p = this.pending.get(msg.id)
      if (!p) continue
      this.pending.delete(msg.id)
      if (msg.ok) {
        const { id: _id, ok: _ok, ...rest } = msg
        p.resolve(rest)
      } else {
        p.reject(new Error(msg.error ?? 'engine error'))
      }
    }
  }

  private finish(): void {
    if (this.closed) return
    this.closed = true
    for (const p of this.pending.values()) p.reject(new Error('the engine closed the connection'))
    this.pending.clear()
    for (const s of this.streams) s.stop()
    this.emit('close')
  }
}

// One `frames` stream. Emits `frame`; stop it when the preview goes away.
export class FrameStream extends EventEmitter<{ frame: [FrameEvent]; close: [] }> {
  private readonly conn: EngineClient
  private readonly onStop: () => void
  readonly id: number

  constructor(conn: EngineClient, id: number, onStop: () => void) {
    super()
    this.conn = conn
    this.id = id
    this.onStop = onStop
    conn.on('frame', (f) => this.emit('frame', f))
    conn.on('close', () => {
      this.onStop()
      this.emit('close')
    })
  }

  // Change what it shows: one window (0 for the whole display), a window to
  // leave out (one being dragged), the rate or size.
  update(opts: { fps?: number; maxWidth?: number; quality?: number; window?: number; exclude?: number }): Promise<void> {
    return this.conn
      .request('frames_update', {
        stream: this.id,
        fps: opts.fps,
        max_width: opts.maxWidth,
        quality: opts.quality,
        window: opts.window,
        exclude: opts.exclude
      })
      .then(() => undefined)
  }

  stop(): void {
    this.conn.close()
  }
}
