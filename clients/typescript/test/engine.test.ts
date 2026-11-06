// Runs a real `bcu serve` in its own state directory (BCU_HOME), so it
// doesn't touch the engine you may have running. Build first: `swift build`.
// BCU_BIN picks another binary.
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { createConnection } from 'node:net'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { after, before, test } from 'node:test'
import { EngineClient, mcpServer, socketPath, startEngine, type EngineStart, type Session } from '../src/index.ts'
import { displayPoint, keyInput, mouseInput } from '../src/dom.ts'

const bcu = process.env.BCU_BIN ?? resolve(import.meta.dirname, '../../../.build/debug/bcu')
// Short: a unix socket path has to fit in 104 bytes.
const home = mkdtempSync(join(tmpdir(), 'bcu-'))
const env = { ...process.env, BCU_HOME: home }
const path = socketPath(home)
let engine: EngineStart

before(async () => {
  engine = await startEngine({ bcu, owner: 'Test Host', logDir: join(home, 'logs'), env })
})

after(() => {
  engine?.process?.kill('SIGTERM')
  rmSync(home, { recursive: true, force: true })
})

// What `bcu mcp` sends for one tool call.
function toolCall(tool: string, args: Record<string, unknown>): Promise<any> {
  return new Promise((resolve, reject) => {
    const s = createConnection(path)
    let buf = ''
    s.setEncoding('utf8')
    s.on('connect', () => s.write(JSON.stringify({ id: 1, tool, args }) + '\n'))
    s.on('data', (d: string) => {
      buf += d
      if (buf.includes('\n')) {
        s.destroy()
        resolve(JSON.parse(buf.slice(0, buf.indexOf('\n'))))
      }
    })
    s.on('error', reject)
  })
}

test('the first start is the engine; a second finds it running', async () => {
  assert.equal(engine.kind, 'ready')
  assert.equal(engine.socket, path)
  const second = await startEngine({ bcu, owner: 'Other Host', env })
  assert.equal(second.kind, 'running')
  assert.equal(second.owner, 'Test Host')
  assert.equal(second.pid, engine.pid)
})

test('hello and catalog', async () => {
  const c = await EngineClient.connect({ path })
  const { engine: info } = await c.hello()
  assert.equal(info.protocol, 1)
  assert.equal(info.owner, 'Test Host')
  assert.equal(typeof info.permissions.accessibility, 'boolean')
  const catalog = await c.request<{ tools: { name: string }[]; instructions: string }>('catalog')
  assert.ok(catalog.tools.some((t) => t.name === 'open_window'))
  assert.ok(catalog.instructions.length > 100)
  await assert.rejects(c.request('nope'), /unknown op/)
  c.close()
})

test('a host sees its own sessions, with their host, ID and label', async () => {
  const c = await EngineClient.connect({ path })
  const seen: Session[][] = []
  c.on('sessions', (s) => seen.push(s))
  await c.subscribe({ host: 'test-host' })

  await toolCall('status', { _session: 'helper-1', _host: 'test-host', _label: 'Research helper', _client: 'claude-code' })
  await toolCall('status', { _session: 'someone-else', _client: 'codex' })

  const deadline = Date.now() + 3000
  while (!seen.at(-1)?.some((s) => s.id === 'helper-1') && Date.now() < deadline) await new Promise((r) => setTimeout(r, 50))
  const latest = seen.at(-1)!
  const mine = latest.find((s) => s.id === 'helper-1')
  assert.ok(mine, 'the session shows up')
  assert.equal(mine.label, 'Research helper')
  assert.equal(mine.host, 'test-host')
  assert.equal(mine.windows.length, 0)
  assert.equal(mine.display, undefined)
  assert.ok(!latest.some((s) => s.id === 'someone-else'), "another host's session isn't pushed")

  const everyone = await c.sessions({ all: true })
  assert.ok(everyone.sessions.some((s) => s.id === 'someone-else'))
  assert.equal(everyone.sessions.find((s) => s.id === 'someone-else')!.label, 'Codex')

  await c.pause('helper-1', true)
  const paused = await c.sessions({ host: 'test-host' })
  assert.equal(paused.sessions[0].status.state, 'paused')
  await c.pause('helper-1', false)

  // Take-over needs a display, and input needs take-over.
  await assert.rejects(c.takeOver('helper-1'), /no display/)
  await assert.rejects(c.input('helper-1', { type: 'mousemove', x: 1, y: 1 }), /take over/)
  await assert.rejects(c.openHandoff('helper-1'), /handed a window off/)
  await assert.rejects(c.pause('missing'), /no session/)
  c.close()
})

test('frames stream opens for a session without a display', async () => {
  const c = await EngineClient.connect({ path })
  const frames = await c.frames('helper-1', { fps: 5 })
  assert.equal(typeof frames.id, 'number')
  await frames.update({ fps: 10 })
  frames.stop()
  c.close()
})

test('mcpServer config', () => {
  assert.deepEqual(mcpServer({ bcu: '/x/bcu', host: 'pa', session: 'h1', label: 'Helper' }), {
    type: 'stdio',
    command: '/x/bcu',
    args: ['mcp', '--host', 'pa', '--session', 'h1', '--label', 'Helper']
  })
})

test('DOM events map to display points', () => {
  // A 1000x1000 element showing a 1600x1000 display: 1000x625, letterboxed.
  const el = { getBoundingClientRect: () => ({ left: 0, top: 0, width: 1000, height: 1000 }) }
  const display = { width: 1600, height: 1000 }
  assert.deepEqual(displayPoint(500, 500, el, display), { x: 800, y: 500 })
  assert.equal(displayPoint(500, 100, el, display), null)
  assert.deepEqual(displayPoint(500, 100, el, display, true), { x: 800, y: 0 })
  const mods = { shiftKey: false, ctrlKey: false, altKey: false, metaKey: true }
  const down = mouseInput({ type: 'mousedown', clientX: 0, clientY: 187.5, button: 2, buttons: 2, detail: 1, ...mods }, el, display)
  assert.deepEqual(down, { type: 'mousedown', x: 0, y: 0, button: 2, clicks: 1, ...mods })
  const wheel = mouseInput(
    { type: 'wheel', clientX: 500, clientY: 500, button: 0, buttons: 0, detail: 0, deltaX: 0, deltaY: 3, deltaMode: 1, ...mods },
    el,
    display
  )
  assert.deepEqual(wheel, { type: 'scroll', x: 800, y: 500, dx: 0, dy: 48, ...mods })
  assert.deepEqual(keyInput({ type: 'keydown', code: 'KeyA', key: 'a', repeat: false, ...mods }), {
    type: 'keydown',
    code: 'KeyA',
    key: 'a',
    repeat: false,
    ...mods
  })
})

test('an engine asked to yield stops once its agents are idle', async () => {
  const c = await EngineClient.connect({ path })
  const closed = new Promise<void>((r) => c.once('close', () => r()))
  await c.request('yield')
  const exited = new Promise<number | null>((r) => engine.process!.once('exit', (code) => r(code)))
  assert.equal(await exited, 0)
  await closed
  // The lock went with it: the next start is the engine again.
  engine = await startEngine({ bcu, owner: 'Test Host', env })
  assert.equal(engine.kind, 'ready')
})
