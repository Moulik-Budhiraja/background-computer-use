// What the engine sends a host app. Points are on the session's agent
// display, top-left origin, in points (the display is `display.width` by
// `display.height`; frames are at a higher pixel density).

export type Point = { x: number; y: number }
export type Rect = { x: number; y: number; width: number; height: number }

// The reply to `recordings`.
export type RecordingsInfo =
  | { recording: false }
  | { recording: true; directory: string; limit_mb: number; retention_days: number }

export type EngineInfo = {
  protocol: number
  version: string
  // Who runs the engine: this app's name for its own `bcu serve`, or
  // "Background Computer Use" when that app runs it.
  owner: string
  pid: number
  permissions: { accessibility: boolean; screen_recording: boolean }
  max_displays: number
  display: { width: number; height: number }
}

export type SessionState = 'idle' | 'working' | 'waiting' | 'paused' | 'user_in_control'

export type AgentWindow = {
  id: number
  app: string
  bundle_id?: string
  pid: number
  kind: 'opened' | 'borrowed' | 'caught'
  // Where it is on the agent display. Absent while it's on the user's screen.
  frame?: Rect
  handed_off: boolean
  handoff_reason?: string
  // The user brought the handed-off window onto their screen.
  with_user: boolean
}

export type Session = {
  // `bcu mcp --session`, or a random ID. A subagent's is its parent's plus "/<agent>".
  id: string
  label: string
  host?: string
  parent?: string
  status: { state: SessionState; text: string }
  // A call is running or just ran.
  active: boolean
  paused: boolean
  user_in_control: boolean
  // Present while the session has an agent display.
  display?: { width: number; height: number }
  windows: AgentWindow[]
  // The agent called `handoff` and is waiting on the user.
  handoff?: { window: number; app: string; reason?: string; with_user: boolean }
  // Where the agent last acted.
  pointer?: Point
  activity: { time: string; text: string; error: boolean }[]
}

export type SessionsEvent = { event: 'sessions'; engine: EngineInfo; sessions: Session[] }

// Just before an agent action lands somewhere: draw its pointer going there.
export type PointerEvent = {
  event: 'pointer'
  session: string
  x: number
  y: number
  kind: 'move' | 'click' | 'drag'
  to?: Point
}

export type FrameEvent = {
  event: 'frame'
  stream: number
  session: string
  seq: number
  mime: 'image/jpeg'
  // Base64. `data:image/jpeg;base64,${data}` works as an image source.
  data: string
  // A frame of the whole display, which it fills exactly.
  display?: { width: number; height: number }
  // A frame of one window (`frames({ window })`).
  window?: number
}

// While the user is in control: the pointer shape the app under it would show.
export type CursorEvent = { event: 'cursor'; session: string; css: string }

export type MenuEntry = {
  title: string
  enabled: boolean
  checked: boolean
  separator: boolean
  children?: MenuEntry[]
}

// While the user is in control, the app opened a menu (a context menu, a
// pop-up button). The engine has closed the real one: show these entries at
// (x, y) and send the pick with `menuPick(session, token, path)`.
export type MenuEvent = { event: 'menu'; session: string; token: number; x: number; y: number; entries: MenuEntry[] }

// While the user is in control, they're moving or resizing a window. The real
// window follows about 100 ms later, so a preview can draw it at `frame` first.
export type DragEvent =
  | {
      event: 'drag'
      session: string
      phase: 'began'
      window: number
      kind: { type: 'move' } | { type: 'resize'; edges: ('left' | 'right' | 'top' | 'bottom')[] }
      frame: Rect
      press: Point
    }
  | { event: 'drag'; session: string; phase: 'ended'; window: number; frame: Rect }

export type EngineEvent = SessionsEvent | PointerEvent | FrameEvent | CursorEvent | MenuEvent | DragEvent

// Take-over input, in DOM terms. x and y are display points.
export type Modifiers = { shiftKey?: boolean; ctrlKey?: boolean; altKey?: boolean; metaKey?: boolean }

export type InputEvent =
  | ({ type: 'mousedown' | 'mouseup'; x: number; y: number; button: number; clicks?: number } & Modifiers)
  // `buttons` as in MouseEvent.buttons: held buttons make it a drag.
  | ({ type: 'mousemove'; x: number; y: number; buttons?: number } & Modifiers)
  // Pixels, as in WheelEvent with deltaMode 0: positive dy scrolls down.
  | ({ type: 'scroll'; x: number; y: number; dx: number; dy: number } & Modifiers)
  // KeyboardEvent.code and .key. cmd+Q is never passed on.
  | ({ type: 'keydown' | 'keyup'; code: string; key?: string; repeat?: boolean } & Modifiers)
