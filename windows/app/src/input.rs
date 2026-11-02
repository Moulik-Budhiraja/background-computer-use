//! Background input: window messages posted straight to the agent's window.
//! Nothing goes through the system input queue, so the user's cursor, keyboard
//! focus and foreground window are untouched (measured in Phase 0: posted
//! clicks, characters and shortcuts reach a background Chromium window, and the
//! foreground never moves).
//!
//! Shortcuts need one extra step: apps read modifier keys with GetKeyState,
//! which reflects the thread's own input state, not the posted messages. So for
//! the length of a shortcut we share the target thread's input state
//! (AttachThreadInput) and mark the modifiers down in it (SetKeyboardState).

use std::time::{Duration, Instant};

use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Gdi::{ClientToScreen, ScreenToClient};
use windows::Win32::System::SystemServices::{MK_LBUTTON, MK_RBUTTON};
use windows::Win32::System::Threading::{AttachThreadInput, GetCurrentThreadId};
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::win;

#[derive(Clone, Copy, PartialEq)]
pub enum Button {
    Left,
    Right,
}

/// The deepest visible child under a screen point, and the point in its client coordinates.
fn target_at(root: HWND, screen: POINT) -> (HWND, POINT) {
    let mut target = root;
    loop {
        let mut local = screen;
        unsafe {
            let _ = ScreenToClient(target, &mut local);
            let child = ChildWindowFromPointEx(target, local, CWP_SKIPINVISIBLE | CWP_SKIPTRANSPARENT | CWP_SKIPDISABLED);
            if child.0.is_null() || child == target {
                return (target, local);
            }
            target = child;
        }
    }
}

fn point_lparam(p: POINT) -> LPARAM {
    LPARAM((((p.y as u32 & 0xffff) << 16) | (p.x as u32 & 0xffff)) as i32 as isize)
}

fn post(hwnd: HWND, msg: u32, w: usize, l: LPARAM) -> Result<(), String> {
    unsafe { PostMessageW(Some(hwnd), msg, WPARAM(w), l).map_err(|e| format!("couldn't post input to the window: {e}")) }
}

/// Wait until the window's thread has worked through the messages just posted:
/// each answered WM_NULL means the thread came back to its message loop once.
fn drain(hwnd: HWND, posted: usize) {
    let deadline = Instant::now() + Duration::from_millis(250);
    for _ in 0..posted + 2 {
        if Instant::now() > deadline {
            break;
        }
        let mut result = 0usize;
        unsafe {
            let _ = SendMessageTimeoutW(hwnd, WM_NULL, WPARAM(0), LPARAM(0), SMTO_ABORTIFHUNG, 100, Some(&mut result));
        }
    }
}

/// Click at a screen point inside `root` (the agent's window).
pub fn click(root: HWND, screen: POINT, button: Button, count: u32) -> Result<(), String> {
    let (target, p) = target_at(root, screen);
    let lp = point_lparam(p);
    let (down, up, dbl, mk) = match button {
        Button::Left => (WM_LBUTTONDOWN, WM_LBUTTONUP, WM_LBUTTONDBLCLK, MK_LBUTTON.0 as usize),
        Button::Right => (WM_RBUTTONDOWN, WM_RBUTTONUP, WM_RBUTTONDBLCLK, MK_RBUTTON.0 as usize),
    };
    post(target, WM_MOUSEMOVE, 0, lp)?;
    for i in 0..count.max(1) {
        // The second press of a double click arrives as a double-click message.
        post(target, if i == 1 { dbl } else { down }, mk, lp)?;
        post(target, up, 0, lp)?;
    }
    if button == Button::Right {
        // What DefWindowProc would send after a real right click.
        let mut s = p;
        unsafe {
            let _ = ClientToScreen(target, &mut s);
        }
        post(target, WM_CONTEXTMENU, target.0 as usize, point_lparam(s))?;
    }
    drain(target, 4);
    Ok(())
}

/// Press at `from`, move in steps, release at `to` (screen points).
pub fn drag(root: HWND, from: POINT, to: POINT) -> Result<(), String> {
    let (target, p0) = target_at(root, from);
    let offset = POINT { x: p0.x - from.x, y: p0.y - from.y };
    post(target, WM_MOUSEMOVE, 0, point_lparam(p0))?;
    post(target, WM_LBUTTONDOWN, MK_LBUTTON.0 as usize, point_lparam(p0))?;
    drain(target, 2);
    let steps = 12;
    for i in 1..=steps {
        let x = from.x + (to.x - from.x) * i / steps + offset.x;
        let y = from.y + (to.y - from.y) * i / steps + offset.y;
        post(target, WM_MOUSEMOVE, MK_LBUTTON.0 as usize, point_lparam(POINT { x, y }))?;
        std::thread::sleep(Duration::from_millis(12));
    }
    let end = POINT { x: to.x + offset.x, y: to.y + offset.y };
    post(target, WM_LBUTTONUP, 0, point_lparam(end))?;
    drain(target, steps as usize + 2);
    Ok(())
}

/// Scroll at a screen point. Positive `dy` scrolls down, in lines.
pub fn scroll(root: HWND, screen: POINT, dx: i32, dy: i32) -> Result<(), String> {
    let (target, _) = target_at(root, screen);
    // Wheel messages carry screen coordinates.
    let lp = point_lparam(screen);
    const WHEEL: i32 = 120;
    for _ in 0..dy.unsigned_abs() {
        let delta = if dy > 0 { -WHEEL } else { WHEEL };
        post(target, WM_MOUSEWHEEL, (delta as u16 as usize) << 16, lp)?;
    }
    for _ in 0..dx.unsigned_abs() {
        let delta = if dx > 0 { WHEEL } else { -WHEEL };
        post(target, WM_MOUSEHWHEEL, (delta as u16 as usize) << 16, lp)?;
    }
    drain(target, (dx.unsigned_abs() + dy.unsigned_abs()) as usize);
    Ok(())
}

/// The child with keyboard focus in the window's thread, or the window itself.
pub fn focus_target(hwnd: HWND) -> HWND {
    let (_, tid) = win::pid_tid(hwnd);
    let mut info = GUITHREADINFO { cbSize: size_of::<GUITHREADINFO>() as u32, ..Default::default() };
    unsafe {
        if GetGUIThreadInfo(tid, &mut info).is_ok() && !info.hwndFocus.0.is_null() {
            // Only if that focus is inside the agent's window, not another window of the app.
            if info.hwndFocus == hwnd || IsChild(hwnd, info.hwndFocus).as_bool() {
                return info.hwndFocus;
            }
        }
    }
    hwnd
}

fn key_lparam(vk: VIRTUAL_KEY, up: bool, alt: bool) -> LPARAM {
    let scan = unsafe { MapVirtualKeyW(vk.0 as u32, MAPVK_VK_TO_VSC) };
    let extended = matches!(vk, VK_UP | VK_DOWN | VK_LEFT | VK_RIGHT | VK_HOME | VK_END | VK_PRIOR | VK_NEXT | VK_DELETE | VK_INSERT);
    let mut l: u32 = 1 | (scan << 16);
    if extended {
        l |= 1 << 24;
    }
    if alt {
        l |= 1 << 29;
    }
    if up {
        l |= (1 << 30) | (1 << 31);
    }
    LPARAM(l as i32 as isize)
}

/// Type text into the focused element of the agent's window. `\n` presses Enter, `\t` Tab.
pub fn type_text(hwnd: HWND, text: &str) -> Result<(), String> {
    let target = focus_target(hwnd);
    let mut posted = 0;
    for c in text.chars() {
        match c {
            '\n' | '\r' => {
                key_messages(target, VK_RETURN, false)?;
                posted += 3;
            }
            '\t' => {
                key_messages(target, VK_TAB, false)?;
                posted += 3;
            }
            _ => {
                let mut buf = [0u16; 2];
                for unit in c.encode_utf16(&mut buf) {
                    post(target, WM_CHAR, *unit as usize, LPARAM(1))?;
                    posted += 1;
                }
            }
        }
        // Let the app keep up with long text.
        if posted % 64 == 0 {
            drain(target, 64);
        }
    }
    drain(target, posted.min(64));
    Ok(())
}

/// WM_KEYDOWN, the WM_CHAR TranslateMessage would make for Enter/Tab, WM_KEYUP.
fn key_messages(target: HWND, vk: VIRTUAL_KEY, alt: bool) -> Result<(), String> {
    let (down, up) = if alt { (WM_SYSKEYDOWN, WM_SYSKEYUP) } else { (WM_KEYDOWN, WM_KEYUP) };
    post(target, down, vk.0 as usize, key_lparam(vk, false, alt))?;
    let ch = match vk {
        VK_RETURN => Some('\r'),
        VK_TAB => Some('\t'),
        _ => None,
    };
    if let (Some(ch), false) = (ch, alt) {
        post(target, WM_CHAR, ch as usize, LPARAM(1))?;
    }
    post(target, up, vk.0 as usize, key_lparam(vk, true, alt))
}

pub fn key_for(name: &str) -> Result<VIRTUAL_KEY, String> {
    let k = name.to_lowercase();
    Ok(match k.as_str() {
        "return" | "enter" => VK_RETURN,
        "tab" => VK_TAB,
        "space" => VK_SPACE,
        "escape" | "esc" => VK_ESCAPE,
        "delete" | "backspace" => VK_BACK,
        "forward_delete" => VK_DELETE,
        "up" => VK_UP,
        "down" => VK_DOWN,
        "left" => VK_LEFT,
        "right" => VK_RIGHT,
        "home" => VK_HOME,
        "end" => VK_END,
        "page_up" => VK_PRIOR,
        "page_down" => VK_NEXT,
        "insert" => VK_INSERT,
        _ if k.chars().count() == 1 => {
            let c = k.chars().next().unwrap();
            if c.is_ascii_alphanumeric() {
                VIRTUAL_KEY(c.to_ascii_uppercase() as u16)
            } else {
                let scan = unsafe { VkKeyScanW(c as u16) };
                if scan == -1 {
                    return Err(format!("no key for {c:?} on this keyboard layout"));
                }
                VIRTUAL_KEY((scan & 0xff) as u16)
            }
        }
        _ if k.starts_with('f') && k[1..].parse::<u16>().is_ok_and(|n| (1..=24).contains(&n)) => {
            VIRTUAL_KEY(VK_F1.0 + k[1..].parse::<u16>().unwrap() - 1)
        }
        _ => return Err(format!("unknown key {name}")),
    })
}

pub fn modifier_for(name: &str) -> Result<VIRTUAL_KEY, String> {
    Ok(match name.to_lowercase().as_str() {
        // An agent used to a Mac may say cmd; on Windows that's Ctrl.
        "ctrl" | "control" | "cmd" | "command" => VK_CONTROL,
        "shift" => VK_SHIFT,
        "alt" | "option" => VK_MENU,
        "win" | "windows" | "meta" | "super" => VK_LWIN,
        other => return Err(format!("unknown modifier {other}. Use ctrl, shift, alt or win.")),
    })
}

/// Press a key with modifiers in the agent's window.
pub fn press_key(hwnd: HWND, key: VIRTUAL_KEY, modifiers: &[VIRTUAL_KEY]) -> Result<(), String> {
    let target = focus_target(hwnd);
    let alt = modifiers.contains(&VK_MENU);
    let (_, target_tid) = win::pid_tid(target);
    let my_tid = unsafe { GetCurrentThreadId() };
    let attached = !modifiers.is_empty() && unsafe { AttachThreadInput(my_tid, target_tid, true) }.as_bool();
    let mut saved = [0u8; 256];
    if attached {
        unsafe {
            let _ = GetKeyboardState(&mut saved);
            let mut state = saved;
            for m in modifiers {
                state[m.0 as usize] |= 0x80;
                let side = match *m {
                    VK_CONTROL => VK_LCONTROL,
                    VK_SHIFT => VK_LSHIFT,
                    VK_MENU => VK_LMENU,
                    other => other,
                };
                state[side.0 as usize] |= 0x80;
            }
            let _ = SetKeyboardState(&state);
        }
    }
    let result = (|| {
        let (down, up) = if alt { (WM_SYSKEYDOWN, WM_SYSKEYUP) } else { (WM_KEYDOWN, WM_KEYUP) };
        for m in modifiers {
            post(target, down, m.0 as usize, key_lparam(*m, false, alt))?;
        }
        post(target, down, key.0 as usize, key_lparam(key, false, alt))?;
        post(target, up, key.0 as usize, key_lparam(key, true, alt))?;
        for m in modifiers.iter().rev() {
            post(target, up, m.0 as usize, key_lparam(*m, true, alt))?;
        }
        Ok(())
    })();
    drain(target, modifiers.len() * 2 + 2);
    if attached {
        unsafe {
            let _ = SetKeyboardState(&saved);
            let _ = AttachThreadInput(my_tid, target_tid, false);
        }
    }
    result
}
