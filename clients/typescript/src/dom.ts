// For a renderer: turn DOM events on a preview into take-over input. No
// Node imports, so it runs in a browser context.
import type { InputEvent, Point } from './types.ts'

type Size = { width: number; height: number }

// The display point under a client point, for a preview element that shows
// the display scaled to fit (CSS object-fit: contain, centered). Null outside
// the picture; `clamp` keeps drags and releases inside it.
export function displayPoint(
  clientX: number,
  clientY: number,
  element: { getBoundingClientRect(): { left: number; top: number; width: number; height: number } },
  display: Size,
  clamp = false
): Point | null {
  const r = element.getBoundingClientRect()
  const s = Math.min(r.width / display.width, r.height / display.height)
  if (!(s > 0)) return null
  const w = display.width * s
  const h = display.height * s
  let fx = (clientX - r.left - (r.width - w) / 2) / w
  let fy = (clientY - r.top - (r.height - h) / 2) / h
  if (clamp) {
    fx = Math.min(Math.max(fx, 0), 0.9999)
    fy = Math.min(Math.max(fy, 0), 0.9999)
  } else if (fx < 0 || fx >= 1 || fy < 0 || fy >= 1) {
    return null
  }
  return { x: fx * display.width, y: fy * display.height }
}

type Mods = { shiftKey: boolean; ctrlKey: boolean; altKey: boolean; metaKey: boolean }
const mods = (e: Mods) => ({ shiftKey: e.shiftKey, ctrlKey: e.ctrlKey, altKey: e.altKey, metaKey: e.metaKey })

type MouseLike = Mods & { type: string; clientX: number; clientY: number; button: number; buttons: number; detail: number }
type WheelLike = MouseLike & { deltaX: number; deltaY: number; deltaMode: number }
type KeyLike = Mods & { type: string; code: string; key: string; repeat: boolean }

// A mousedown, mouseup, mousemove or wheel event on the preview, or null
// when it's outside the picture. Call preventDefault on the event yourself.
export function mouseInput(
  e: MouseLike | WheelLike,
  element: Parameters<typeof displayPoint>[2],
  display: Size
): InputEvent | null {
  const dragging = e.type === 'mouseup' || (e.type === 'mousemove' && e.buttons !== 0)
  const p = displayPoint(e.clientX, e.clientY, element, display, dragging)
  if (!p) return null
  switch (e.type) {
    case 'mousedown':
    case 'mouseup':
      return { type: e.type, ...p, button: e.button, clicks: Math.max(1, e.detail), ...mods(e) }
    case 'mousemove':
      return { type: 'mousemove', ...p, buttons: e.buttons, ...mods(e) }
    case 'wheel': {
      const w = e as WheelLike
      // Lines and pages to pixels, roughly as browsers do.
      const unit = w.deltaMode === 1 ? 16 : w.deltaMode === 2 ? display.height : 1
      return { type: 'scroll', ...p, dx: w.deltaX * unit, dy: w.deltaY * unit, ...mods(e) }
    }
    default:
      return null
  }
}

// A keydown or keyup event while the preview has focus.
export function keyInput(e: KeyLike): InputEvent | null {
  if (e.type !== 'keydown' && e.type !== 'keyup') return null
  if (!e.code) return null
  return { type: e.type, code: e.code, key: e.key, repeat: e.repeat, ...mods(e) }
}
