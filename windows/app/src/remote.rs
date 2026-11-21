//! The user's hands on an agent's screen, from a host app's preview
//! (`take_over` and `input`, host.rs): DOM-style mouse, wheel and key events,
//! posted to the session's window under the point the way the agent's own
//! input is (input.rs), so the user's cursor, focus and foreground never
//! move. Only the session family's windows and their popups take input
//! (`host::shown_windows`), as only they show in its frames.
//!
//! A press on a window's frame moves or resizes it from here (an app given
//! the press would track the real cursor), and the host hears `drag`. A press
//! on a caption button closes or maximizes the window. Menus are windows on
//! the agent screen, so they show in the frames and take clicks: no `menu`
//! events. `cursor` says what pointer the app would show where the user's is.

use std::sync::{Arc, Mutex, mpsc};
use std::time::Duration;

use serde_json::{Map, Value, json};
use windows::Win32::Foundation::{HWND, LPARAM, POINT, RECT, WPARAM};
use windows::Win32::System::Com::{CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx};
use windows::Win32::System::SystemServices::{MK_CONTROL, MK_LBUTTON, MK_MBUTTON, MK_RBUTTON, MK_SHIFT};
use windows::Win32::UI::Accessibility::*;
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::host::{self, Conn};
use crate::{guard, input, monitor, win};

#[derive(Clone, Copy, PartialEq)]
enum Grab {
    Move,
    /// Edges: left, right, top, bottom.
    Resize(bool, bool, bool, bool),
}

struct Drag {
    hwnd: HWND,
    grab: Grab,
    /// The window's rect (with its invisible borders) and the press, when it began.
    start: RECT,
    press: POINT,
}

#[derive(Default)]
struct State {
    /// Where keys go: the window last clicked (a dialog of the family's included).
    key_window: Option<usize>,
    drag: Option<Drag>,
    /// The control a button went down in: the rest of the press goes there,
    /// as the mouse capture a real press would take (posted messages don't).
    pressed: Option<usize>,
    /// A caption button pressed (close, maximize), acted on at release.
    caption: Option<(usize, u32)>,
    /// Wheel pixels not yet sent (a notch is 120 units, about 100 pixels).
    wheel: (f64, f64),
}

pub struct Remote {
    session: String,
    conn: Arc<Conn>,
    state: Mutex<State>,
    cursor: Mutex<Option<mpsc::Sender<POINT>>>,
}

unsafe impl Send for Remote {}
unsafe impl Sync for Remote {}

const HTCAPTION_: u32 = 2;
const HTSYSMENU_: u32 = 3;
const HTMINBUTTON_: u32 = 8;
const HTMAXBUTTON_: u32 = 9;
const HTLEFT_: u32 = 10;
const HTBOTTOMRIGHT_: u32 = 17;
const HTCLOSE_: u32 = 20;

impl Remote {
    pub fn new(session: &str, conn: Arc<Conn>) -> Arc<Remote> {
        let (tx, rx) = mpsc::channel::<POINT>();
        let r = Arc::new(Remote { session: session.to_string(), conn, state: Mutex::new(State::default()), cursor: Mutex::new(Some(tx)) });
        let me = Arc::downgrade(&r);
        std::thread::Builder::new()
            .name("take-over cursor".into())
            .spawn(move || cursor_loop(me, rx))
            .expect("cursor thread");
        r
    }

    /// The user let go, or the host went away.
    pub fn end(&self) {
        self.cursor.lock().unwrap_or_else(|e| e.into_inner()).take();
        let drag = self.state.lock().unwrap_or_else(|e| e.into_inner()).drag.take();
        if let Some(d) = drag {
            self.drag_ended(&d);
        }
    }

    fn screen(&self) -> Result<RECT, String> {
        monitor::of_session(&self.session).map(|m| m.rect).ok_or_else(|| "that session has no display yet".to_string())
    }

    /// One input event from the host.
    pub fn post(&self, ev: &Map<String, Value>) -> Result<(), String> {
        let screen = self.screen()?;
        let kind = ev.get("type").and_then(Value::as_str).unwrap_or("");
        let num = |k: &str| ev.get(k).and_then(Value::as_f64);
        let mods = Mods::from(ev);
        let point = |clamp: bool| -> Result<POINT, String> {
            let (Some(mut x), Some(mut y)) = (num("x"), num("y")) else { return Err(format!("{kind} needs x and y")) };
            let (w, h) = ((screen.right - screen.left) as f64, (screen.bottom - screen.top) as f64);
            if clamp {
                x = x.clamp(0.0, w - 0.01);
                y = y.clamp(0.0, h - 0.01);
            }
            Ok(POINT { x: screen.left + x.floor() as i32, y: screen.top + y.floor() as i32 })
        };
        match kind {
            "mousedown" => self.mouse_down(point(false)?, ev.get("button").and_then(Value::as_i64).unwrap_or(0), ev.get("clicks").and_then(Value::as_i64).unwrap_or(1), mods, &screen),
            "mouseup" => self.mouse_up(point(true)?, ev.get("button").and_then(Value::as_i64).unwrap_or(0), mods, &screen),
            "mousemove" => self.mouse_move(point(ev.get("buttons").and_then(Value::as_i64).unwrap_or(0) != 0)?, ev.get("buttons").and_then(Value::as_i64).unwrap_or(0), mods, &screen),
            "scroll" => self.scroll(point(false)?, num("dx").unwrap_or(0.0), num("dy").unwrap_or(0.0), mods, &screen),
            "keydown" => self.key_down(ev.get("code").and_then(Value::as_str).unwrap_or(""), ev.get("key").and_then(Value::as_str).unwrap_or(""), mods, &screen),
            // A key is pressed whole when it goes down (and again on each repeat).
            "keyup" => Ok(()),
            other => Err(format!("unknown input type {other}")),
        }
    }

    /// The family's window or popup under `p`, top first.
    fn window_at(&self, p: POINT, screen: &RECT) -> Option<HWND> {
        host::shown_windows(&self.session, screen, 0).into_iter().find(|h| {
            let f = win::frame(*h);
            p.x >= f.left && p.x < f.right && p.y >= f.top && p.y < f.bottom
        })
    }

    fn mouse_down(&self, p: POINT, button: i64, clicks: i64, mods: Mods, screen: &RECT) -> Result<(), String> {
        let Some(root) = self.window_at(p, screen) else { return Ok(()) };
        let mut st = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if button == 0 && win::is_app_window(root) {
            match hit_test(root, p) {
                HTCAPTION_ => {
                    let d = Drag { hwnd: root, grab: Grab::Move, start: window_rect(root), press: p };
                    self.drag_began(&d, screen);
                    st.drag = Some(d);
                    st.key_window = Some(root.0 as usize);
                    return Ok(());
                }
                h @ HTLEFT_..=HTBOTTOMRIGHT_ => {
                    let d = Drag { hwnd: root, grab: edges(h), start: window_rect(root), press: p };
                    self.drag_began(&d, screen);
                    st.drag = Some(d);
                    return Ok(());
                }
                h @ (HTCLOSE_ | HTMAXBUTTON_ | HTMINBUTTON_ | HTSYSMENU_) => {
                    st.caption = Some((root.0 as usize, h));
                    return Ok(());
                }
                _ => {}
            }
        }
        let (target, local) = input::target_at(root, p);
        st.pressed = Some(target.0 as usize);
        st.key_window = Some(root.0 as usize);
        drop(st);
        let (down, dbl) = match button {
            2 => (WM_RBUTTONDOWN, WM_RBUTTONDBLCLK),
            1 => (WM_MBUTTONDOWN, WM_MBUTTONDBLCLK),
            _ => (WM_LBUTTONDOWN, WM_LBUTTONDBLCLK),
        };
        let held = mods.keys() | button_mask(button);
        acting(root, || {
            post(target, WM_MOUSEMOVE, mods.keys(), input::point_lparam(local));
            post(target, if clicks == 2 { dbl } else { down }, held, input::point_lparam(local));
        });
        Ok(())
    }

    /// Where the rest of a press goes: the control it began in, with `p` in
    /// its client coordinates. Otherwise the control under `p`.
    fn press_target(&self, pressed: Option<usize>, p: POINT, screen: &RECT) -> Option<(HWND, POINT)> {
        if let Some(c) = pressed.map(|c| HWND(c as *mut _)).filter(|h| win::exists(*h)) {
            let mut local = p;
            unsafe {
                let _ = windows::Win32::Graphics::Gdi::ScreenToClient(c, &mut local);
            }
            return Some((c, local));
        }
        self.window_at(p, screen).map(|root| input::target_at(root, p))
    }

    fn mouse_up(&self, p: POINT, button: i64, mods: Mods, screen: &RECT) -> Result<(), String> {
        let mut st = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(d) = st.drag.take() {
            drop(st);
            self.drag_ended(&d);
            return Ok(());
        }
        if let Some((w, h)) = st.caption.take() {
            drop(st);
            let hwnd = HWND(w as *mut _);
            if self.window_at(p, screen) == Some(hwnd) && hit_test(hwnd, p) == h {
                let command = match h {
                    HTCLOSE_ => Some(SC_CLOSE),
                    HTMAXBUTTON_ if win::is_maximized(hwnd) => Some(SC_RESTORE),
                    HTMAXBUTTON_ => Some(SC_MAXIMIZE),
                    // Minimized, it would be gone from the agent's screen.
                    _ => None,
                };
                if let Some(c) = command {
                    acting(hwnd, || post(hwnd, WM_SYSCOMMAND, c as usize, LPARAM(0)));
                }
            }
            return Ok(());
        }
        let pressed = st.pressed.take();
        drop(st);
        let Some((target, local)) = self.press_target(pressed, p, screen) else { return Ok(()) };
        let up = match button {
            2 => WM_RBUTTONUP,
            1 => WM_MBUTTONUP,
            _ => WM_LBUTTONUP,
        };
        acting(target, || {
            post(target, up, mods.keys(), input::point_lparam(local));
            if button == 2 {
                // What DefWindowProc sends after a real right click.
                post(target, WM_CONTEXTMENU, target.0 as usize, input::point_lparam(p));
            }
        });
        Ok(())
    }

    fn mouse_move(&self, p: POINT, buttons: i64, mods: Mods, screen: &RECT) -> Result<(), String> {
        let mut st = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(d) = &st.drag {
            let r = dragged(d, p, screen);
            unsafe {
                let _ = SetWindowPos(d.hwnd, None, r.left, r.top, r.right - r.left, r.bottom - r.top, SWP_NOZORDER | SWP_NOACTIVATE);
            }
            return Ok(());
        }
        // No button held: any press is over (its release may never have come).
        let pressed = if buttons == 0 { None } else { st.pressed };
        if buttons == 0 {
            st.pressed = None;
        }
        drop(st);
        if let Some(tx) = self.cursor.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
            let _ = tx.send(p);
        }
        let Some((target, local)) = self.press_target(pressed, p, screen) else { return Ok(()) };
        let mut held = mods.keys();
        if buttons & 1 != 0 {
            held |= MK_LBUTTON.0 as usize;
        }
        if buttons & 2 != 0 {
            held |= MK_RBUTTON.0 as usize;
        }
        if buttons & 4 != 0 {
            held |= MK_MBUTTON.0 as usize;
        }
        post(target, WM_MOUSEMOVE, held, input::point_lparam(local));
        Ok(())
    }

    fn scroll(&self, p: POINT, dx: f64, dy: f64, mods: Mods, screen: &RECT) -> Result<(), String> {
        let Some(root) = self.window_at(p, screen) else { return Ok(()) };
        let (ux, uy) = {
            let mut st = self.state.lock().unwrap_or_else(|e| e.into_inner());
            // DOM pixels down/right to wheel units up/right: 120 a notch, about 100 pixels.
            st.wheel.0 += dx * 1.2;
            st.wheel.1 += -dy * 1.2;
            let take = |v: &mut f64| {
                let whole = v.trunc();
                *v -= whole;
                whole as i32
            };
            (take(&mut st.wheel.0), take(&mut st.wheel.1))
        };
        let (target, _) = input::target_at(root, p);
        let lp = input::point_lparam(p);
        for (units, msg) in [(uy, WM_MOUSEWHEEL), (ux, WM_MOUSEHWHEEL)] {
            if units != 0 {
                post(target, msg, mods.keys() | ((units as i16 as u16 as usize) << 16), lp);
            }
        }
        Ok(())
    }

    fn key_down(&self, code: &str, key: &str, mods: Mods, screen: &RECT) -> Result<(), String> {
        let Some(vk) = vk_for(code, key) else { return Err(format!("unknown key code {code}")) };
        if is_modifier(vk) {
            return Ok(());
        }
        // Shortcuts that would quit the whole app, the user's windows with it.
        if mods.ctrl && vk == VK_Q {
            return Ok(());
        }
        let st = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let wanted = st.key_window.map(|w| HWND(w as *mut _));
        drop(st);
        let shown = host::shown_windows(&self.session, screen, 0);
        // The window last clicked while it's still the family's (a dialog
        // counts), else the family's topmost window.
        let Some(window) = wanted.filter(|w| shown.contains(w)).or_else(|| shown.into_iter().find(|h| win::is_app_window(*h))) else {
            return Ok(());
        };
        let text: Vec<char> = key.chars().collect();
        let printable = text.len() == 1 && !text[0].is_control();
        acting(window, || {
            if mods.ctrl || mods.alt || mods.meta {
                let mut held = Vec::new();
                if mods.ctrl || mods.meta {
                    held.push(VK_CONTROL);
                }
                if mods.shift {
                    held.push(VK_SHIFT);
                }
                if mods.alt {
                    held.push(VK_MENU);
                }
                let _ = input::press_key(window, vk, &held);
            } else if printable {
                let _ = input::type_text(window, key);
            } else if vk == VK_RETURN {
                let _ = input::type_text(window, "\n");
            } else if vk == VK_TAB && !mods.shift {
                let _ = input::type_text(window, "\t");
            } else {
                let held: Vec<VIRTUAL_KEY> = if mods.shift { vec![VK_SHIFT] } else { Vec::new() };
                let _ = input::press_key(window, vk, &held);
            }
        });
        Ok(())
    }

    fn drag_began(&self, d: &Drag, screen: &RECT) {
        let f = win::frame(d.hwnd);
        let kind = match d.grab {
            Grab::Move => json!({"type": "move"}),
            Grab::Resize(l, r, t, b) => {
                let names: Vec<&str> = [(l, "left"), (r, "right"), (t, "top"), (b, "bottom")].iter().filter(|(on, _)| *on).map(|(_, n)| *n).collect();
                json!({"type": "resize", "edges": names})
            }
        };
        self.conn.send(&json!({
            "event": "drag", "session": self.session, "phase": "began", "window": win::id(d.hwnd), "kind": kind,
            "frame": local_rect(&f, screen), "press": {"x": d.press.x - screen.left, "y": d.press.y - screen.top},
        }));
    }

    fn drag_ended(&self, d: &Drag) {
        let Ok(screen) = self.screen() else { return };
        let f = win::frame(d.hwnd);
        self.conn.send(&json!({"event": "drag", "session": self.session, "phase": "ended", "window": win::id(d.hwnd), "frame": local_rect(&f, &screen)}));
    }
}

fn local_rect(r: &RECT, screen: &RECT) -> Value {
    json!({"x": r.left - screen.left, "y": r.top - screen.top, "width": r.right - r.left, "height": r.bottom - r.top})
}

/// Post, as the user's input: an activation it causes is given back like one the agent caused.
fn acting(hwnd: HWND, f: impl FnOnce()) {
    let pid = win::pid_tid(hwnd).0;
    guard::begin_action(pid);
    f();
    let _ = guard::end_action(pid);
}

fn post(hwnd: HWND, msg: u32, w: usize, l: LPARAM) {
    unsafe {
        let _ = PostMessageW(Some(hwnd), msg, WPARAM(w), l);
    }
}

fn button_mask(button: i64) -> usize {
    (match button {
        2 => MK_RBUTTON,
        1 => MK_MBUTTON,
        _ => MK_LBUTTON,
    })
    .0 as usize
}

fn window_rect(hwnd: HWND) -> RECT {
    let mut r = RECT::default();
    unsafe {
        let _ = GetWindowRect(hwnd, &mut r);
    }
    r
}

/// What part of the window is at `p` (WM_NCHITTEST), asked of the app.
fn hit_test(hwnd: HWND, p: POINT) -> u32 {
    let mut result = 0usize;
    unsafe {
        let _ = SendMessageTimeoutW(hwnd, WM_NCHITTEST, WPARAM(0), input::point_lparam(p), SMTO_ABORTIFHUNG, 100, Some(&mut result));
    }
    result as u32
}

fn edges(hit: u32) -> Grab {
    // HTLEFT 10, HTRIGHT 11, HTTOP 12, HTTOPLEFT 13, HTTOPRIGHT 14, HTBOTTOM 15, HTBOTTOMLEFT 16, HTBOTTOMRIGHT 17.
    match hit {
        10 => Grab::Resize(true, false, false, false),
        11 => Grab::Resize(false, true, false, false),
        12 => Grab::Resize(false, false, true, false),
        13 => Grab::Resize(true, false, true, false),
        14 => Grab::Resize(false, true, true, false),
        15 => Grab::Resize(false, false, false, true),
        16 => Grab::Resize(true, false, false, true),
        _ => Grab::Resize(false, true, false, true),
    }
}

/// Where a dragged window goes for the pointer at `p`: moved or resized by
/// as much as the pointer moved, and kept on the agent screen.
fn dragged(d: &Drag, p: POINT, screen: &RECT) -> RECT {
    let (dx, dy) = (p.x - d.press.x, p.y - d.press.y);
    let s = d.start;
    let mut r = match d.grab {
        Grab::Move => RECT { left: s.left + dx, top: s.top + dy, right: s.right + dx, bottom: s.bottom + dy },
        Grab::Resize(l, rt, t, b) => {
            const MIN_W: i32 = 240;
            const MIN_H: i32 = 160;
            let mut r = s;
            if l {
                r.left = (s.left + dx).min(s.right - MIN_W);
            }
            if rt {
                r.right = (s.right + dx).max(s.left + MIN_W);
            }
            if t {
                r.top = (s.top + dy).min(s.bottom - MIN_H);
            }
            if b {
                r.bottom = (s.bottom + dy).max(s.top + MIN_H);
            }
            r
        }
    };
    // The title bar stays on the agent screen, so the window can be grabbed again.
    if d.grab == Grab::Move {
        let (w, h) = (r.right - r.left, r.bottom - r.top);
        let x = r.left.clamp(screen.left - w + 80, screen.right - 80);
        let y = r.top.clamp(screen.top, screen.bottom - 40);
        r = RECT { left: x, top: y, right: x + w, bottom: y + h };
    }
    r
}

#[derive(Clone, Copy, Default)]
struct Mods {
    shift: bool,
    ctrl: bool,
    alt: bool,
    meta: bool,
}

impl Mods {
    /// `modifiers` as a list (["shift", "meta"]) or the DOM booleans.
    fn from(ev: &Map<String, Value>) -> Mods {
        if let Some(list) = ev.get("modifiers").and_then(Value::as_array) {
            let has = |n: &[&str]| list.iter().any(|m| m.as_str().is_some_and(|m| n.contains(&m)));
            return Mods { shift: has(&["shift"]), ctrl: has(&["ctrl", "control"]), alt: has(&["alt", "option"]), meta: has(&["meta", "cmd", "command", "win"]) };
        }
        let b = |k: &str| ev.get(k).and_then(Value::as_bool).unwrap_or(false);
        Mods { shift: b("shiftKey"), ctrl: b("ctrlKey"), alt: b("altKey"), meta: b("metaKey") }
    }

    /// The MK_ flags a mouse message carries.
    fn keys(&self) -> usize {
        let mut k = 0;
        if self.shift {
            k |= MK_SHIFT.0 as usize;
        }
        if self.ctrl {
            k |= MK_CONTROL.0 as usize;
        }
        k
    }
}

fn is_modifier(vk: VIRTUAL_KEY) -> bool {
    matches!(vk, VK_SHIFT | VK_LSHIFT | VK_RSHIFT | VK_CONTROL | VK_LCONTROL | VK_RCONTROL | VK_MENU | VK_LMENU | VK_RMENU | VK_LWIN | VK_RWIN | VK_CAPITAL | VK_NUMLOCK)
}

/// DOM `KeyboardEvent.code` (the physical key) to a virtual key, or by `key`
/// on this keyboard layout.
pub fn vk_for(code: &str, key: &str) -> Option<VIRTUAL_KEY> {
    let named = match code {
        "Enter" | "NumpadEnter" => VK_RETURN,
        "Tab" => VK_TAB,
        "Space" => VK_SPACE,
        "Backspace" => VK_BACK,
        "Escape" => VK_ESCAPE,
        "Delete" => VK_DELETE,
        "Insert" => VK_INSERT,
        "Home" => VK_HOME,
        "End" => VK_END,
        "PageUp" => VK_PRIOR,
        "PageDown" => VK_NEXT,
        "ArrowLeft" => VK_LEFT,
        "ArrowRight" => VK_RIGHT,
        "ArrowUp" => VK_UP,
        "ArrowDown" => VK_DOWN,
        "ShiftLeft" | "ShiftRight" => VK_SHIFT,
        "ControlLeft" | "ControlRight" => VK_CONTROL,
        "AltLeft" | "AltRight" => VK_MENU,
        "MetaLeft" | "MetaRight" => VK_LWIN,
        "CapsLock" => VK_CAPITAL,
        "NumLock" => VK_NUMLOCK,
        "ContextMenu" => VK_APPS,
        "NumpadMultiply" => VK_MULTIPLY,
        "NumpadAdd" => VK_ADD,
        "NumpadSubtract" => VK_SUBTRACT,
        "NumpadDecimal" => VK_DECIMAL,
        "NumpadDivide" => VK_DIVIDE,
        _ => VIRTUAL_KEY(0),
    };
    if named.0 != 0 {
        return Some(named);
    }
    if let Some(c) = code.strip_prefix("Key").filter(|c| c.len() == 1) {
        return Some(VIRTUAL_KEY(c.as_bytes()[0].to_ascii_uppercase() as u16));
    }
    if let Some(d) = code.strip_prefix("Digit").filter(|d| d.len() == 1) {
        return Some(VIRTUAL_KEY(d.as_bytes()[0] as u16));
    }
    if let Some(d) = code.strip_prefix("Numpad").and_then(|d| d.parse::<u16>().ok()).filter(|d| *d <= 9) {
        return Some(VIRTUAL_KEY(VK_NUMPAD0.0 + d));
    }
    if let Some(n) = code.strip_prefix('F').and_then(|n| n.parse::<u16>().ok()).filter(|n| (1..=24).contains(n)) {
        return Some(VIRTUAL_KEY(VK_F1.0 + n - 1));
    }
    // Punctuation: by the character it types here.
    let mut chars = key.chars();
    if let (Some(c), None) = (chars.next(), chars.next()) {
        let scan = unsafe { VkKeyScanW(c as u16) };
        if scan != -1 {
            return Some(VIRTUAL_KEY((scan & 0xff) as u16));
        }
    }
    None
}

// ---------- the pointer the app would show ----------

fn cursor_loop(remote: std::sync::Weak<Remote>, rx: mpsc::Receiver<POINT>) {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
    }
    let auto: Option<IUIAutomation> = unsafe { CoCreateInstance(&CUIAutomation8, None, CLSCTX_INPROC_SERVER).ok() };
    let mut last = String::new();
    while let Ok(mut p) = rx.recv() {
        // Only the latest point matters.
        while let Ok(newer) = rx.try_recv() {
            p = newer;
        }
        let Some(r) = remote.upgrade() else { return };
        let Ok(screen) = r.screen() else { continue };
        let css = r.window_at(p, &screen).map(|w| css_at(auto.as_ref(), w, p)).unwrap_or("default");
        if css != last {
            last = css.to_string();
            r.conn.send(&json!({"event": "cursor", "session": r.session, "css": css}));
        }
        drop(r);
        std::thread::sleep(Duration::from_millis(60));
    }
}

/// The CSS cursor for `p` over `hwnd`: a resize arrow on its frame, a text
/// beam over text fields, a hand over links.
fn css_at(auto: Option<&IUIAutomation>, hwnd: HWND, p: POINT) -> &'static str {
    match hit_test(hwnd, p) {
        10 | 11 => return "ew-resize",
        12 | 15 => return "ns-resize",
        13 | 17 => return "nwse-resize",
        14 | 16 => return "nesw-resize",
        1 => {}
        _ => return "default",
    }
    let Some(auto) = auto else { return "default" };
    unsafe {
        let Ok(e) = auto.ElementFromPoint(p) else { return "default" };
        let kind = e.CurrentControlType().unwrap_or_default();
        if kind == UIA_EditControlTypeId {
            return "text";
        }
        if kind == UIA_HyperlinkControlTypeId {
            return "pointer";
        }
        // Text inside a link.
        if kind == UIA_TextControlTypeId
            && let Ok(walker) = auto.ControlViewWalker()
            && let Ok(parent) = walker.GetParentElement(&e)
            && parent.CurrentControlType().unwrap_or_default() == UIA_HyperlinkControlTypeId
        {
            return "pointer";
        }
    }
    "default"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_by_code() {
        assert_eq!(vk_for("KeyA", "a"), Some(VIRTUAL_KEY(b'A' as u16)));
        assert_eq!(vk_for("Digit7", "7"), Some(VIRTUAL_KEY(b'7' as u16)));
        assert_eq!(vk_for("Enter", "Enter"), Some(VK_RETURN));
        assert_eq!(vk_for("F12", "F12"), Some(VK_F12));
        assert_eq!(vk_for("Numpad3", "3"), Some(VK_NUMPAD3));
        assert_eq!(vk_for("Unidentified", ""), None);
    }

    #[test]
    fn drags_keep_the_title_bar_on_the_screen() {
        let screen = RECT { left: 1920, top: 1080, right: 3520, bottom: 2080 };
        let d = Drag { hwnd: HWND(std::ptr::null_mut()), grab: Grab::Move, start: RECT { left: 2000, top: 1100, right: 2800, bottom: 1700 }, press: POINT { x: 2100, y: 1110 } };
        let r = dragged(&d, POINT { x: 2150, y: 1160 }, &screen);
        assert_eq!((r.left, r.top, r.right - r.left), (2050, 1150, 800));
        let up = dragged(&d, POINT { x: 2100, y: 500 }, &screen);
        assert_eq!(up.top, 1080, "not above the screen");
        let d = Drag { grab: Grab::Resize(false, true, false, true), ..d };
        let r = dragged(&d, POINT { x: 1000, y: 0 }, &screen);
        assert_eq!((r.right - r.left, r.bottom - r.top), (240, 160), "no smaller than the least size");
    }
}
