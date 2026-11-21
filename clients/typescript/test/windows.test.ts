// On Windows, with real windows: BCU_WINDOWS_LIVE=1 node --test test/windows.test.ts
// A host's side of the engine end to end: `bcu serve` as a child of this
// process, helper-style agents (`bcu mcp --host --session --label`) working
// in Notepad and Edge while a simulated user types into their own Notepad in
// front, frames, pause, stop, handoff, quitting, and the Background Computer
// Use tray app running the engine instead. Needs the agent screen on (`bcu
// screen on`) and no engine running. It closes Notepad and Edge first.
// BCU_BIN picks bcu.exe (default: the release build next to the tray app,
// windows/target/release), BCU_PROBE bcu-probe.exe (default: next to it).
import assert from 'node:assert/strict'
import { execFileSync, spawn, type ChildProcess } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { after, before, test } from 'node:test'
import { EngineClient, startEngine, type EngineStart, type FrameEvent, type PointerEvent, type Session } from '../src/index.ts'

const live = process.platform === 'win32' && process.env.BCU_WINDOWS_LIVE === '1'
const bcu = process.env.BCU_BIN ?? resolve(import.meta.dirname, '../../../windows/target/release/bcu.exe')
const probe = process.env.BCU_PROBE ?? join(dirname(bcu), 'bcu-probe.exe')
const tray = join(dirname(bcu), 'BackgroundComputerUse.exe')
const dir = mkdtempSync(join(tmpdir(), 'bcu-win-'))
const HOST = 'test-host'
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

let engine: EngineStart | undefined
let host: EngineClient | undefined
const helpers: Mcp[] = []

// One agent's MCP server, as the Agent SDK runs it.
class Mcp {
  private child: ChildProcess
  private buf = ''
  private next = 1
  private pending = new Map<number, (v: any) => void>()

  constructor(args: string[]) {
    this.child = spawn(bcu, ['mcp', ...args], { stdio: ['pipe', 'pipe', 'ignore'], windowsHide: true })
    this.child.stdout!.setEncoding('utf8')
    this.child.stdout!.on('data', (d: string) => {
      this.buf += d
      let nl: number
      while ((nl = this.buf.indexOf('\n')) >= 0) {
        const line = this.buf.slice(0, nl)
        this.buf = this.buf.slice(nl + 1)
        const msg = JSON.parse(line)
        if (msg.id !== undefined) this.pending.get(msg.id)?.(msg)
      }
    })
    helpers.push(this)
  }

  request(method: string, params: Record<string, unknown> = {}): Promise<any> {
    const id = this.next++
    return new Promise((resolve) => {
      this.pending.set(id, resolve)
      this.child.stdin!.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n')
    })
  }

  async init() {
    const r = await this.request('initialize', { protocolVersion: '2025-06-18', clientInfo: { name: 'claude-code' } })
    this.child.stdin!.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n')
    return r.result
  }

  // A tool call: its text, and whether it failed.
  async call(name: string, args: Record<string, unknown> = {}, meta?: Record<string, unknown>): Promise<{ text: string; error: boolean }> {
    const r = await this.request('tools/call', { name, arguments: args, ...(meta ? { _meta: meta } : {}) })
    return { text: r.result.content.find((c: any) => c.type === 'text')?.text ?? '', error: r.result.isError }
  }

  async ok(name: string, args: Record<string, unknown> = {}, meta?: Record<string, unknown>): Promise<string> {
    const r = await this.call(name, args, meta)
    assert.ok(!r.error, `${name} failed: ${r.text}`)
    return r.text
  }

  close() {
    this.child.stdin!.end()
  }
}

function sh(cmd: string, args: string[]): string {
  return execFileSync(cmd, args, { encoding: 'utf8', windowsHide: true }).trim()
}
const ps = (script: string) => sh('powershell.exe', ['-NoProfile', '-Command', script])
// Ask the probe about the user's side of the screen.
const probeRun = (...args: string[]) => sh(probe, args)
// A window's handle ("0x1a2b"), by part of its title.
const find = (title: string) => probeRun('find', title)
// What's in a Notepad window.
const textOf = (hwnd: string) => JSON.parse(/^text \(\d+ chars\): (.*)$/m.exec(probeRun('get-text', hwnd))![1])
// Where a window is ("left,top,right,bottom"), or "gone".
const rect = (hwnd: string | number) =>
  ps(
    `Add-Type -Name W -Namespace B -MemberDefinition '[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h); [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, int[] r);'; ` +
      `$h = [IntPtr][Int64]${Number(hwnd)}; $r = New-Object int[] 4; if ([B.W]::IsWindow($h) -and [B.W]::GetWindowRect($h, $r)) { $r -join ',' } else { 'gone' }`
  )

function closeApps() {
  ps('Get-Process notepad, msedge, BackgroundComputerUse -ErrorAction SilentlyContinue | Stop-Process -Force; exit 0')
  // Windows 11 Notepad reopens its last session's tabs; start it clean.
  ps(`Remove-Item "$env:LOCALAPPDATA\\Packages\\Microsoft.WindowsNotepad_8wekyb3d8bbwe\\LocalState\\TabState\\*", "$env:LOCALAPPDATA\\Packages\\Microsoft.WindowsNotepad_8wekyb3d8bbwe\\LocalState\\WindowState\\*" -Force -ErrorAction SilentlyContinue; exit 0`)
}

async function until<T>(what: string, f: () => T | undefined | false | Promise<T | undefined | false>, ms = 10_000): Promise<T> {
  const deadline = Date.now() + ms
  for (;;) {
    const v = await f()
    if (v) return v
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`)
    await sleep(100)
  }
}

// The user clicks the desktop, right of their Notepad: nothing of theirs or the agents' is in front.
const clickDesktop = () => probeRun('mouse', '1700', '500', 'left')

let latest: Session[] = []
const session = (id: string) => latest.find((s) => s.id === id)

async function startHost(opts: { ownEngine?: boolean } = { ownEngine: true }) {
  engine = await startEngine({ bcu, owner: 'Test Host', logDir: join(dir, 'logs'), ownEngine: opts.ownEngine })
  host = await EngineClient.connect({ path: engine.socket, waitMs: 5000 })
  host.on('sessions', (s) => (latest = s))
  await host.subscribe({ host: HOST })
}

async function stopHost() {
  host?.close()
  host = undefined
  const p = engine?.process
  if (p && p.exitCode === null) {
    const exited = new Promise((r) => p.once('exit', r))
    p.kill()
    await exited
  }
  engine = undefined
  // The engine itself (not the relay this process started) stops once it has released its windows.
  await until('the engine to stop', () => !pipeUp(), 20_000)
}

function pipeUp(): boolean {
  return ps(`Test-Path "\\\\.\\pipe\\BackgroundComputerUse-$env:USERNAME"`) === 'True'
}

before(() => {
  if (!live) return
  assert.ok(existsSync(bcu), `no ${bcu}`)
  assert.ok(!pipeUp(), 'another engine is running')
  closeApps()
})

after(async () => {
  for (const h of helpers) h.close()
  if (live) await stopHost().catch(() => {})
  if (live) closeApps()
})

test('a host starts the engine; a second start finds it running', { skip: !live }, async () => {
  await startHost()
  assert.equal(engine!.kind, 'ready')
  assert.match(engine!.socket, /^\\\\\.\\pipe\\BackgroundComputerUse-/)
  const second = await startEngine({ bcu, owner: 'Other Host' })
  assert.equal(second.kind, 'running')
  assert.equal(second.owner, 'Test Host')
  assert.equal(second.pid, engine!.pid)
})

test('hello and catalog', { skip: !live }, async () => {
  const { engine: info } = await host!.hello()
  assert.equal(info.protocol, 1)
  assert.equal(info.owner, 'Test Host')
  assert.equal(info.platform, 'windows')
  assert.equal(info.shows_hosts, undefined)
  assert.equal(info.permissions.agent_screen, true, info.agent_screen_problem)
  assert.deepEqual(info.display, { width: 1600, height: 1000 })
  const catalog = await host!.request<{ tools: { name: string }[]; instructions: string }>('catalog')
  assert.ok(catalog.tools.some((t) => t.name === 'open_window'))
  await assert.rejects(host!.request('nope'), /unknown op/)
})

let helper: Mcp
let notepad = 0
let edge = 0

test('a host chooses whether its sessions are recorded, and where', { skip: !live }, async () => {
  await assert.rejects(host!.request('recordings', { directory: join(dir, 'rec') }), /host/)
  await assert.rejects(host!.setRecordings({ host: HOST, directory: 'relative\\dir' }), /absolute/)
  const rec = join(dir, 'recordings')
  const on = await host!.setRecordings({ host: HOST, directory: rec, limitMB: 10, retentionDays: 2 })
  assert.deepEqual(on, { recording: true, directory: rec, limit_mb: 50, retention_days: 2 })
  assert.ok(existsSync(rec), 'the folder is made')
  assert.deepEqual(await host!.setRecordings({ host: HOST, directory: null }), { recording: false })
  await host!.setRecordings({ host: HOST, directory: rec })
})

test('a helper session has the host, ID and label it was started with', { skip: !live }, async () => {
  helper = new Mcp(['--host', HOST, '--session', 'helper-1', '--label', 'Research helper'])
  const init = await helper.init()
  assert.ok(init.instructions.length > 100)
  const other = new Mcp([])
  await other.init()
  await helper.ok('status')
  await other.ok('status')
  const mine = await until('the session', () => session('helper-1'))
  assert.equal(mine.label, 'Research helper')
  assert.equal(mine.host, HOST)
  assert.equal(mine.windows.length, 0)
  assert.ok(!latest.some((s) => s.host !== HOST), "another host's sessions aren't pushed")
  const everyone = await host!.sessions({ all: true })
  assert.ok(everyone.sessions.some((s) => s.label === 'Claude Code'))
  other.close()
})

test('an agent works in Notepad, streamed to the host', { skip: !live }, async () => {
  const frames: FrameEvent[] = []
  const pointers: PointerEvent[] = []
  host!.on('pointer', (p) => pointers.push(p))

  notepad = Number(/Opened window (\d+)/.exec(await helper.ok('open_window', { app: 'notepad' }))![1])
  const withWindow = await until('the window in the session', () => session('helper-1')?.windows.find((w) => w.id === notepad) && session('helper-1'))
  assert.deepEqual(withWindow.display, { width: 1600, height: 1000 })
  const w = withWindow.windows.find((w) => w.id === notepad)!
  assert.match(w.exe ?? '', /notepad\.exe$/i)
  assert.equal(w.kind, 'opened')
  assert.ok(w.frame && w.frame.x >= 0 && w.frame.y >= 0, 'its frame is on the agent screen')

  const stream = await host!.frames('helper-1', { fps: 10, maxWidth: 800 })
  stream.on('frame', (f) => frames.push(f))
  await until('a frame', () => frames.length > 0)
  assert.equal(frames[0].mime, 'image/jpeg')
  assert.ok(frames[0].data.startsWith('/9j/'), 'a JPEG')
  assert.deepEqual(frames[0].display, { width: 1600, height: 1000 })

  await helper.ok('click', { window_id: notepad, x: 300, y: 300 })
  await helper.ok('type_text', { window_id: notepad, text: 'typed by the agent' })
  assert.match(await helper.ok('get_window_state', { window_id: notepad, screenshot: false, full: true }), /typed by the agent/)
  assert.ok(pointers.some((p) => p.session === 'helper-1' && p.kind === 'click' && p.x >= 0 && p.x < 1600), 'the click was pointed at')
  await until('more frames', () => frames.length > 3)
  const s = session('helper-1')!
  assert.ok(s.activity.some((a) => a.text.startsWith('type_text (')), 'the activity has the calls')
  stream.stop()

  // Closing it, it asks about saving: the agent answers.
  const asked = await helper.call('release_window', { window_id: notepad })
  if (asked.error) {
    const dialog = await helper.ok('get_window_state', { window_id: notepad, screenshot: false })
    const dontSave = /\[(\d+)\] Button "Don.t save"/.exec(dialog)
    assert.ok(dontSave, `release_window: ${asked.text}\n${dialog.slice(0, 1500)}`)
    await helper.ok('click', { window_id: notepad, element: Number(dontSave[1]) })
    await helper.ok('release_window', { window_id: notepad })
  }
  await until('no windows', () => session('helper-1')?.windows.length === 0)
})

test('an agent works in Edge while the user types into Notepad in front', { skip: !live }, async () => {
  // The user's window: Notepad on a file of their own, in front. (Windows 11
  // runs every Notepad window in one process; while the user is in one, an
  // agent's click in another takes the foreground from them, with or
  // without a host. The agent's Notepad is closed by now.)
  const userFile = join(dir, 'user.txt')
  writeFileSync(userFile, '')
  spawn('notepad.exe', [userFile], { detached: true, stdio: 'ignore' }).unref()
  const userNp = await until('the user\'s Notepad', () => {
    try {
      return find('user.txt') || false
    } catch {
      return false
    }
  })
  probeRun('move', userNp, '200', '150', '1000', '700')
  // In front, as the user would put it: a click on it (the first may only close the Start menu).
  await until('the user\'s Notepad in front', () => {
    probeRun('mouse', '600', '450', 'left')
    try {
      probeRun('type-into', userNp, 'user: ', '10')
      return true
    } catch {
      return false
    }
  })

  // The agent opens Edge and loads a page, then works in it while the user types.
  edge = Number(/Opened window (\d+)/.exec(await helper.ok('open_window', { app: 'msedge' }))![1])
  const page = 'file:///' + join(dir, 'page.html').replace(/\\/g, '/')
  writeFileSync(join(dir, 'page.html'), '<title>Host test</title><input aria-label="Probe input"><button onclick="this.textContent=+this.textContent+1">0</button>')
  const blank = await helper.ok('get_window_state', { window_id: edge, screenshot: false })
  const bar = /\[(\d+)\] Edit "Address and search bar/.exec(blank)![1]
  await helper.ok('click', { window_id: edge, element: Number(bar) })
  await helper.ok('type_text', { window_id: edge, text: page + '\n' })
  const state = await helper.ok('get_window_state', { window_id: edge, screenshot: false })
  assert.match(state, /Probe input/)
  const input = /\[(\d+)\] Edit "Probe input/.exec(state)![1]
  const button = /\[(\d+)\] Button "0"/.exec(state)![1]

  const sentence = 'The quick brown fox jumps over the lazy dog 0123456789. '
  const typer = spawn(probe, ['type-into', userNp, sentence.repeat(3), '8'], { stdio: ['ignore', 'ignore', 'pipe'], windowsHide: true })
  let typerError = ''
  typer.stderr!.on('data', (d) => (typerError += d))
  const typed = new Promise((r) => typer.once('exit', r))
  await sleep(300)
  await helper.ok('click', { window_id: edge, element: Number(button) })
  await helper.ok('click', { window_id: edge, element: Number(button) })
  // A click, then the text. (type_text with an element presses Ctrl+End
  // first, which can cost the user a key: the engine's, with or without a host.)
  await helper.ok('click', { window_id: edge, element: Number(input) })
  await helper.ok('type_text', { window_id: edge, text: 'typed by the agent' })
  await helper.ok('scroll', { window_id: edge, dy: 3 })
  assert.equal(await typed, 0, `the user's typing: ${typerError}`)
  await sleep(300)
  const report = await helper.ok('guard_report')
  assert.equal(textOf(userNp), 'user: ' + sentence.repeat(3), `the user's Notepad has only what they typed. Guard: ${report.slice(-2000)}`)
  assert.match(await helper.ok('get_window_state', { window_id: edge, screenshot: false }), /typed by the agent/)
  assert.equal(session('helper-1')!.windows.length, 1)
})

test('a subagent gets its own session, and can use its parent\'s windows', { skip: !live }, async () => {
  // Codex tells threads apart by threadId: the first one seen is the main agent's.
  await helper.ok('status', {}, { threadId: 'main-thread' })
  const read = await helper.ok('get_window_state', { window_id: edge, screenshot: false }, { threadId: 'sub-thread' })
  assert.ok(read.length > 0)
  const sub = await until('the subagent\'s session', () => session('helper-1/sub-thread'))
  assert.equal(sub.parent, 'helper-1')
  assert.equal(sub.host, HOST)
  // The window stays its parent's.
  assert.equal(sub.windows.length, 0)
  // A batch that names the window only in its actions goes there too.
  await helper.ok('batch', { actions: [{ tool: 'scroll', window_id: edge, dy: 1 }], state: false }, { threadId: 'sub-thread' })
  // Paused, the subagent can't act on it, though its parent isn't paused.
  await host!.pause('helper-1/sub-thread', true)
  const refused = await helper.call('click', { window_id: edge, x: 5, y: 5 }, { threadId: 'sub-thread' })
  assert.ok(refused.error && /Paused/.test(refused.text), refused.text)
  await host!.pause('helper-1/sub-thread', false)
})

test('pause, rename and handoff', { skip: !live }, async () => {
  await host!.pause('helper-1', true)
  await until('paused', () => session('helper-1')?.status.state === 'paused')
  const refused = await helper.call('click', { window_id: edge, x: 10, y: 10 })
  assert.ok(refused.error && /Paused/.test(refused.text))
  await host!.pause('helper-1', false)

  await host!.rename('helper-1', 'Get Google Approval')
  await until('renamed', () => session('helper-1')?.label === 'Get Google Approval')
  await assert.rejects(host!.rename('helper-1', ' '), /label/)
  await assert.rejects(host!.pause('missing'), /no session/)

  await assert.rejects(host!.openHandoff('helper-1'), /handed a window off/)
  await helper.ok('handoff', { window_id: edge, reason: 'Sign in for me' })
  const waiting = await until('the handoff', () => session('helper-1')?.handoff && session('helper-1'))
  assert.equal(waiting.status.state, 'waiting')
  assert.equal(waiting.handoff!.window, edge)
  assert.equal(waiting.handoff!.reason, 'Sign in for me')
  await host!.openHandoff('helper-1')
  // The user is done, and says so in the host's window: something else is in front now.
  clickDesktop()
  await host!.handBack('helper-1')
  await until('handed back', () => !session('helper-1')?.handoff)
  assert.ok(session('helper-1')!.windows.find((w) => w.id === edge)!.frame, 'back on the agent screen')
})

test('stop releases a session\'s windows', { skip: !live }, async () => {
  // A Notepad window and Edge: the host stops the session.
  notepad = Number(/Opened window (\d+)/.exec(await helper.ok('open_window', { app: 'notepad' }))![1])
  await until('two windows', () => session('helper-1')?.windows.length === 2)
  await host!.stop('helper-1')
  await until('no windows', () => session('helper-1')?.windows.length === 0).catch((e) => {
    throw new Error(`${e.message}: ${JSON.stringify(session('helper-1')?.windows)}`)
  })
  const gone = await helper.call('get_window_state', { window_id: edge })
  assert.ok(gone.error)
})

test('a frame leaves out other sessions\' windows on the shared agent screen', { skip: !live }, async () => {
  // Another app's agent has a window on the agent screen.
  const other = new Mcp(['--host', 'other-host', '--session', 'other-1'])
  await other.init()
  const theirs = Number(/Opened window (\d+)/.exec(await other.ok('open_window', { app: 'notepad' }))![1])
  const mine = Number(/Opened window (\d+)/.exec(await helper.ok('open_window', { app: 'msedge' }))![1])
  const frames: FrameEvent[] = []
  const stream = await host!.frames('helper-1', { fps: 5 })
  stream.on('frame', (f) => frames.push(f))
  await until('frames', () => frames.length >= 2)
  // Drawn from the session's own windows: look at it in the test's folder.
  writeFileSync(join(dir, 'composed.jpg'), Buffer.from(frames.at(-1)!.data, 'base64'))
  console.log(`composed frame: ${join(dir, 'composed.jpg')}`)
  assert.deepEqual(frames.at(-1)!.display, { width: 1600, height: 1000 })
  stream.stop()
  await other.ok('release_window', { window_id: theirs })
  await helper.ok('release_window', { window_id: mine })
  other.close()
})

test('when the host quits, the engine gives the windows back first', { skip: !live }, async () => {
  const userNp = find('user.txt')
  const before = rect(userNp)
  // Not while it's in front, where the user is using it.
  clickDesktop()
  await helper.ok('borrow_window', { window_id: Number(userNp) })
  const opened = Number(/Opened window (\d+)/.exec(await helper.ok('open_window', { app: 'msedge' }))![1])
  assert.notEqual(rect(userNp), before, 'borrowed onto the agent screen')
  // What Node's kill() does on Windows: ends the process at once.
  await stopHost()
  await sleep(500)
  assert.equal(rect(userNp), before, 'the borrowed window is back where it was')
  await until('the window it opened to close', () => rect(opened) === 'gone')
})

test('the helper\'s work is recorded, in the Mac\'s layout', { skip: !live }, async () => {
  const rec = join(dir, 'recordings')
  const runs = readdirSync(rec).filter((d) => existsSync(join(rec, d, 'meta.json')))
  const mine = runs.map((d) => ({ d, meta: JSON.parse(readFileSync(join(rec, d, 'meta.json'), 'utf8')) })).filter((r) => r.meta.session === 'helper-1')
  assert.equal(mine.length, 1, `one run for helper-1: ${runs.join(', ')}`)
  const { d, meta } = mine[0]
  assert.match(d, /^\d{8}-\d{6}-\d{3}-helper-1-[0-9a-f]{8}$/)
  assert.equal(meta.label, 'Get Google Approval', 'renamed while recording')
  assert.deepEqual([meta.w, meta.h], [1600, 1000])
  assert.ok(meta.end > meta.start, 'ended when the engine stopped')
  const lines = (f: string) => readFileSync(join(rec, d, f), 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l))
  const frames = lines('frames.jsonl')
  const staged = new Set(readdirSync(join(rec, d, 'staging')))
  assert.ok(frames.length >= 3, `frames: ${frames.length}`)
  assert.ok(frames.every((f) => staged.has(`${Math.trunc(f.t)}.jpg`)), 'every frame has its JPEG')
  assert.ok(frames.some((f) => /notepad\.exe$/i.test(f.b ?? '')) && frames.some((f) => /msedge\.exe$/i.test(f.b ?? '')), 'frames say which app was in front')
  const events = lines('events.jsonl')
  assert.ok(events.some((e) => e.x?.startsWith('open_window (')), 'the activity')
  assert.ok(events.some((e) => e.x?.startsWith('release_window')), 'closing a window, which the history reads')
  assert.ok(events.some((e) => Array.isArray(e.p) && e.c === true), 'where clicks landed')
})

test('the tray app takes over from a host\'s engine once its agents are done', { skip: !live }, async () => {
  await startHost()
  // The tray app, set up as after its onboarding.
  mkdirSync(join(process.env.APPDATA!, 'BackgroundComputerUse'), { recursive: true })
  writeFileSync(join(process.env.APPDATA!, 'BackgroundComputerUse', 'onboarded'), '')
  const exited = new Promise((r) => engine!.process!.once('exit', r))
  spawn(tray, [], { detached: true, stdio: 'ignore' }).unref()
  await exited
  const c = await until('the tray app\'s engine', async () => {
    try {
      const c = await EngineClient.connect({ path: engine!.socket })
      const { engine: info } = await c.hello()
      if (info.shows_hosts) return c
      c.close()
    } catch {}
    return false
  }, 30_000)
  const { engine: info } = await c.hello()
  assert.equal(info.owner, 'Background Computer Use')
  c.close()
  engine = undefined
})

test('with the tray app running, a host uses its engine', { skip: !live }, async () => {
  const started = await startEngine({ bcu, owner: 'Test Host' })
  assert.equal(started.kind, 'running')
  assert.equal(started.owner, 'Background Computer Use')
  const c = await EngineClient.connect({ path: started.socket })
  const seen: Session[][] = []
  c.on('sessions', (s) => seen.push(s))
  await c.subscribe({ host: HOST })
  const h = new Mcp(['--host', HOST, '--session', 'helper-2', '--label', 'Tray helper'])
  await h.init()
  await h.ok('status')
  await until('its session', () => seen.at(-1)?.find((s) => s.id === 'helper-2'))
  c.close()
  h.close()
  ps('Get-Process BackgroundComputerUse -ErrorAction SilentlyContinue | Stop-Process -Force; exit 0')
  await until('the tray app to stop', () => !pipeUp())
})

test('with the tray app installed and set up, serve starts it', { skip: !live }, async () => {
  assert.ok(existsSync(join(process.env.APPDATA!, 'BackgroundComputerUse', 'app.json')), 'the tray app wrote its record')
  const record = JSON.parse(readFileSync(join(process.env.APPDATA!, 'BackgroundComputerUse', 'app.json'), 'utf8'))
  assert.equal(record.protocol, 1)
  const started = await startEngine({ bcu, owner: 'Test Host' })
  assert.equal(started.kind, 'running')
  assert.equal(started.owner, 'Background Computer Use')
  ps('Get-Process BackgroundComputerUse -ErrorAction SilentlyContinue | Stop-Process -Force; exit 0')
  await until('the tray app to stop', () => !pipeUp())
})
