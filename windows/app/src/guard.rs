//! Keeps the user's foreground window, keystrokes and cursor theirs.
//!
//! - Foreground restore: apps take the foreground when the agent acts on them
//!   (Chromium and UWP apps do when an element is invoked through UI Automation,
//!   and a new window activates itself). When the new foreground is one of the
//!   agent's windows, or an app the agent is acting on, the user's window is put
//!   back with SwitchToThisWindow, which measured ~1 ms.
//! - Keystroke hold: a key the user presses while an agent window is in front
//!   is held, the user's window is put back, and the key is replayed into it.
//!   Nothing the user types lands in the agent's window.
//! - Cursor fence: the pointer is kept off the agent monitors.
//! - Menus off the user's screen: a window on a hidden screen (Remote
//!   Desktop) opens its menus, dropdowns, dialogs and tooltips on the user's
//!   screen, because Windows keeps them on a display. They're moved over the
//!   agent's window as soon as they show. Measured in Edge: a moved context
//!   menu still draws and takes posted input; the context menu was on the
//!   user's screen for under 5 ms, and the address bar's suggestions and a
//!   <select>'s list weren't seen there at all.
//!
//! The hooks and the foreground watcher run on their own thread with a message
//! loop and do almost nothing in their callbacks, so the user's input is never
//! delayed by the engine (low-level hooks run inline with every key and move).

use std::collections::{HashSet, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use windows::Win32::Foundation::*;
use windows::Win32::System::Threading::{AttachThreadInput, GetCurrentThreadId};
use windows::Win32::UI::Accessibility::{HWINEVENTHOOK, SetWinEventHook};
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::{monitor, offscreen, win};

/// Marks the keys we replay, so the hook lets them through.
const REPLAY_TAG: usize = 0x4243_5552; // "BCUR"
/// After an action ends, activations of that app are still the agent's doing for this long.
const GRACE: Duration = Duration::from_millis(700);

struct State {
    /// The user's foreground window: the last one that wasn't the agent's.
    user_window: HWND,
    /// Windows that belong to agents.
    agent_windows: HashSet<usize>,
    /// Processes being acted on, and until when activations of them count as the agent's.
    acting: Vec<(u32, Option<Instant>)>,
    /// The agent monitors (one box around all of them), in screen pixels, for the cursor fence.
    fence: Option<RECT>,
    held: VecDeque<KBDLLHOOKSTRUCT>,
    /// Last time the user clicked or pressed Alt/Win (what switches windows),
    /// to tell their own switches from the agent's.
    last_user_switch: Option<Instant>,
    events: Vec<String>,
    /// Foreground changes during actions, by the process acted on, for the tool result.
    action_notes: Vec<(u32, String)>,
    /// The agent window last acted on in each process, for menus with no owner.
    targets: Vec<(u32, usize)>,
    /// Where an agent last clicked, for placing the menu it opened.
    last_point: Option<(POINT, Instant)>,
    /// Menus moved off the user's screen, watched in case the app moves them back.
    moved: HashSet<usize>,
}

// HWND isn't Send; the guard only stores it as a value and uses it on its own thread.
unsafe impl Send for State {}

static STATE: OnceLock<Mutex<State>> = OnceLock::new();
/// Set while the user's window is being put back; keys the user presses meanwhile are held.
static RESTORING: AtomicBool = AtomicBool::new(false);
static RESTORE_TX: OnceLock<Mutex<std::sync::mpsc::Sender<String>>> = OnceLock::new();
static START: OnceLock<Instant> = OnceLock::new();

fn state() -> std::sync::MutexGuard<'static, State> {
    STATE
        .get_or_init(|| {
            Mutex::new(State {
                user_window: HWND::default(),
                agent_windows: HashSet::new(),
                acting: Vec::new(),
                fence: None,
                held: VecDeque::new(),
                last_user_switch: None,
                events: Vec::new(),
                action_notes: Vec::new(),
                targets: Vec::new(),
                last_point: None,
                moved: HashSet::new(),
            })
        })
        .lock()
        .unwrap_or_else(|e| e.into_inner())
}

fn stamp() -> String {
    let t = START.get_or_init(Instant::now).elapsed().as_secs_f64();
    format!("{:>9.3}s", t)
}

/// Start the hook thread. Call once.
pub fn start() {
    START.get_or_init(Instant::now);
    {
        let fg = win::foreground();
        state().user_window = fg;
        offscreen::set_user_window(fg);
    }
    let (tx, rx) = std::sync::mpsc::channel::<String>();
    let _ = RESTORE_TX.set(Mutex::new(tx));
    std::thread::Builder::new()
        .name("guard-restore".into())
        .spawn(move || {
            for reason in rx {
                restore(&reason);
            }
        })
        .expect("guard restore thread");
    std::thread::Builder::new()
        .name("guard".into())
        .spawn(|| unsafe {
            let _ = SetWindowsHookExW(WH_KEYBOARD_LL, Some(keyboard_hook), None, 0);
            let _ = SetWindowsHookExW(WH_MOUSE_LL, Some(mouse_hook), None, 0);
            let _ = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, None, Some(on_foreground), 0, 0, WINEVENT_OUTOFCONTEXT);
            let mut msg = MSG::default();
            while GetMessageW(&mut msg, None, 0, 0).as_bool() {
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        })
        .expect("guard thread");
    // Menus of agent windows on hidden screens, and agent windows that show
    // up on the user's screen (offscreen::watch). Its own thread, so the
    // keyboard and mouse hooks never wait on it.
    std::thread::Builder::new()
        .name("menu-watch".into())
        .spawn(|| unsafe {
            let flags = WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS;
            let _ = SetWinEventHook(EVENT_OBJECT_CREATE, EVENT_OBJECT_CREATE, None, Some(on_menu_event), 0, 0, flags);
            let _ = SetWinEventHook(EVENT_OBJECT_SHOW, EVENT_OBJECT_SHOW, None, Some(on_menu_event), 0, 0, flags);
            let _ = SetWinEventHook(EVENT_OBJECT_LOCATIONCHANGE, EVENT_OBJECT_LOCATIONCHANGE, None, Some(on_menu_event), 0, 0, flags);
            let mut msg = MSG::default();
            while GetMessageW(&mut msg, None, 0, 0).as_bool() {
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        })
        .expect("menu watch thread");
    // The fence's backstop: anything that put the cursor on the agent monitor
    // without a mouse event (another app warping it, monitors rearranged).
    std::thread::Builder::new()
        .name("cursor-watch".into())
        .spawn(|| loop {
            std::thread::sleep(Duration::from_millis(8));
            let fence = state().fence;
            if let Some(f) = fence {
                let mut p = POINT::default();
                unsafe {
                    if GetCursorPos(&mut p).is_ok() && inside(&f, p) {
                        let q = outside(&f, p);
                        let _ = SetCursorPos(q.x, q.y);
                    }
                }
            }
        })
        .expect("cursor watch thread");
}

pub fn set_fence(rect: Option<RECT>) {
    state().fence = rect;
}

/// An agent's window, living on `area` (its monitor or hidden screen) as
/// its `index`-th window: kept there from now on (see offscreen.rs).
pub fn add_agent_window(hwnd: HWND, area: RECT, index: usize) {
    state().agent_windows.insert(hwnd.0 as usize);
    offscreen::keep(hwnd, area, index);
}

pub fn remove_agent_window(hwnd: HWND) {
    state().agent_windows.remove(&(hwnd.0 as usize));
    offscreen::forget(hwnd);
}

/// Whether any agent has this window.
pub fn is_agent_window(hwnd: HWND) -> bool {
    state().agent_windows.contains(&(hwnd.0 as usize))
}

/// The agent is acting on this window: menus its app opens without an owner are its.
pub fn note_target(hwnd: HWND) {
    let pid = win::pid_tid(hwnd).0;
    let mut s = state();
    s.targets.retain(|(p, _)| *p != pid);
    s.targets.push((pid, hwnd.0 as usize));
}

/// Where an agent clicked, in screen pixels.
pub fn note_point(p: POINT) {
    state().last_point = Some((p, Instant::now()));
    offscreen::set_last_point(p.x, p.y);
}

/// The agent is about to act on `pid`. Activations of it count as the agent's until `end_action` + a grace period.
pub fn begin_action(pid: u32) {
    let mut s = state();
    s.acting.retain(|(p, until)| *p != pid && until.is_none_or(|u| u > Instant::now()));
    s.acting.push((pid, None));
    s.action_notes.retain(|(p, _)| *p != pid);
}

/// Returns what happened to the user's foreground during the action, if anything.
pub fn end_action(pid: u32) -> Option<String> {
    let mut s = state();
    for entry in s.acting.iter_mut().filter(|(p, _)| *p == pid) {
        entry.1 = Some(Instant::now() + GRACE);
    }
    let (mine, rest): (Vec<_>, Vec<_>) = std::mem::take(&mut s.action_notes).into_iter().partition(|(p, _)| *p == pid);
    s.action_notes = rest;
    if mine.is_empty() { None } else { Some(mine.into_iter().map(|(_, n)| n).collect::<Vec<_>>().join("; ")) }
}

/// Put the user's window back in front (from any thread). Keys the user
/// presses until it's back are held and then replayed into it.
pub fn give_back(reason: &str) {
    request_restore(reason);
}

fn request_restore(reason: &str) {
    if !RESTORING.swap(true, Ordering::AcqRel)
        && let Some(tx) = RESTORE_TX.get()
    {
        let _ = tx.lock().unwrap_or_else(|e| e.into_inner()).send(reason.to_string());
    }
}

pub fn report() -> String {
    let s = state();
    if s.events.is_empty() {
        "No focus-guard events.".into()
    } else {
        s.events.join("\n")
    }
}

fn agent_caused(s: &State, hwnd: HWND) -> bool {
    if s.agent_windows.contains(&(hwnd.0 as usize)) {
        return true;
    }
    let pid = win::pid_tid(hwnd).0;
    let now = Instant::now();
    let user_recent = s.last_user_switch.is_some_and(|t| now.duration_since(t) < Duration::from_millis(300));
    s.acting.iter().any(|(p, until)| *p == pid && until.is_none_or(|u| u > now)) && !user_recent
}

fn wait_for_foreground(hwnd: HWND, ms: u64) -> bool {
    let t = Instant::now();
    while t.elapsed() < Duration::from_millis(ms) {
        if win::foreground() == hwnd {
            return true;
        }
        std::thread::sleep(Duration::from_micros(500));
    }
    win::foreground() == hwnd
}

/// Put the user's window back in front, then replay the keys held meanwhile.
/// Runs on the restore thread, so the hooks keep answering (and holding keys)
/// while it waits for Windows to switch.
fn restore(reason: &str) {
    let (user, agent) = {
        let s = state();
        (s.user_window, win::foreground())
    };
    let needed = agent != user && agent_caused(&state(), agent);
    let t = Instant::now();
    let mut ok = !needed;
    if needed && !user.0.is_null() && win::exists(user) {
        for _ in 0..3 {
            unsafe {
                SwitchToThisWindow(user, true);
            }
            if wait_for_foreground(user, 40) {
                ok = true;
                break;
            }
            // Join the current foreground thread's input queue for the call.
            let (_, fg_tid) = win::pid_tid(win::foreground());
            unsafe {
                let me = GetCurrentThreadId();
                let attached = AttachThreadInput(me, fg_tid, true).as_bool();
                let _ = SetForegroundWindow(user);
                if attached {
                    let _ = AttachThreadInput(me, fg_tid, false);
                }
            }
            if wait_for_foreground(user, 40) {
                ok = true;
                break;
            }
        }
    }
    if needed {
        let note = format!(
            "{} took the foreground ({reason}); {} in {:.1} ms",
            describe(agent),
            if ok { "gave it back to the user's window" } else { "COULD NOT give it back" },
            t.elapsed().as_secs_f64() * 1000.0
        );
        let mut s = state();
        s.events.push(format!("{} {note}", stamp()));
        if s.events.len() > 200 {
            s.events.remove(0);
        }
        s.action_notes.push((win::pid_tid(agent).0, note));
    }
    replay_held();
}

fn describe(hwnd: HWND) -> String {
    let pid = win::pid_tid(hwnd).0;
    format!("{} \"{}\"", win::app_name(pid), win::title(hwnd).chars().take(60).collect::<String>())
}

/// Replay held keys into whatever is in front now (the user's window), in
/// order. Keys the user presses during a replay are held too and replayed
/// after it; once nothing is left, holding stops.
fn replay_held() {
    let mut total = 0;
    loop {
        let held: Vec<KBDLLHOOKSTRUCT> = {
            let mut s = state();
            if s.held.is_empty() {
                RESTORING.store(false, Ordering::Release);
                if total > 0 {
                    s.events.push(format!("{} replayed {total} held key event(s) into the user's window", stamp()));
                }
                return;
            }
            s.held.drain(..).collect()
        };
        total += held.len();
        let inputs: Vec<INPUT> = held.iter().map(replay_input).collect();
        unsafe {
            SendInput(&inputs, size_of::<INPUT>() as i32);
        }
    }
}

fn replay_input(k: &KBDLLHOOKSTRUCT) -> INPUT {
    let mut flags = KEYBD_EVENT_FLAGS(0);
    if k.flags.0 & LLKHF_UP.0 != 0 {
        flags |= KEYEVENTF_KEYUP;
    }
    if k.flags.0 & LLKHF_EXTENDED.0 != 0 {
        flags |= KEYEVENTF_EXTENDEDKEY;
    }
    // A Unicode character (VK_PACKET) carries the character in its scan code.
    let unicode = k.vkCode == VK_PACKET.0 as u32;
    if unicode {
        flags |= KEYEVENTF_UNICODE;
    }
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: if unicode { VIRTUAL_KEY(0) } else { VIRTUAL_KEY(k.vkCode as u16) },
                wScan: k.scanCode as u16,
                dwFlags: flags,
                time: 0,
                dwExtraInfo: REPLAY_TAG,
            },
        },
    }
}

unsafe extern "system" fn on_foreground(_: HWINEVENTHOOK, _: u32, hwnd: HWND, _: i32, _: i32, _: u32, _: u32) {
    if hwnd.0.is_null() || RESTORING.load(Ordering::Acquire) {
        return;
    }
    // Events arrive a little late; only the window in front now matters.
    let hwnd = {
        let now = win::foreground();
        if now.0.is_null() { hwnd } else { now }
    };
    let caused = {
        let mut s = state();
        let caused = agent_caused(&s, hwnd);
        if !caused && win::pid_tid(hwnd).0 != std::process::id() {
            s.user_window = hwnd;
            offscreen::set_user_window(hwnd);
        }
        caused
    };
    if caused {
        request_restore("foreground change");
    }
}

unsafe extern "system" fn keyboard_hook(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code == HC_ACTION as i32 {
        let k = unsafe { *(lparam.0 as *const KBDLLHOOKSTRUCT) };
        // Anything we didn't replay ourselves is the user's, injected or not
        // (remote desktop tools and on-screen keyboards inject keys too).
        if k.dwExtraInfo != REPLAY_TAG {
            let fg = win::foreground();
            let mut s = state();
            if matches!(VIRTUAL_KEY(k.vkCode as u16), VK_MENU | VK_LMENU | VK_RMENU | VK_LWIN | VK_RWIN) {
                s.last_user_switch = Some(Instant::now());
            }
            // An agent window is in front, or the user's is being put back:
            // hold the key and replay it once the user's window is in front.
            let restoring = RESTORING.load(Ordering::Acquire);
            if restoring || (fg != s.user_window && agent_caused(&s, fg)) {
                s.held.push_back(k);
                drop(s);
                if !restoring {
                    request_restore("the user was typing");
                }
                return LRESULT(1);
            }
        }
    }
    unsafe { CallNextHookEx(None, code, wparam, lparam) }
}

unsafe extern "system" fn mouse_hook(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code == HC_ACTION as i32 {
        let m = unsafe { *(lparam.0 as *const MSLLHOOKSTRUCT) };
        if m.dwExtraInfo != REPLAY_TAG {
            let mut s = state();
            if matches!(wparam.0 as u32, WM_LBUTTONDOWN | WM_RBUTTONDOWN | WM_MBUTTONDOWN) {
                s.last_user_switch = Some(Instant::now());
            }
            // Keep the pointer off the agent monitor: drop the move; it stays where it was.
            if wparam.0 as u32 == WM_MOUSEMOVE
                && let Some(f) = s.fence
                && inside(&f, m.pt)
            {
                return LRESULT(1);
            }
        }
    }
    unsafe { CallNextHookEx(None, code, wparam, lparam) }
}

unsafe extern "system" fn on_menu_event(_: HWINEVENTHOOK, event: u32, hwnd: HWND, object: i32, _: i32, _: u32, _: u32) {
    // Only windows themselves (location changes also come for the caret and cursor).
    if hwnd.0.is_null() || object != OBJID_WINDOW.0 {
        return;
    }
    if event == EVENT_OBJECT_CREATE {
        offscreen::watch(event, hwnd);
        return;
    }
    // Agent windows, and new windows of an app an agent is opening, that
    // showed up on the user's screen.
    if unsafe { GetAncestor(hwnd, GA_ROOT) } == hwnd && offscreen::watch(event, hwnd) {
        return;
    }
    // Location changes come for every window that moves; only follow the menus already moved.
    if event == EVENT_OBJECT_LOCATIONCHANGE && !state().moved.contains(&(hwnd.0 as usize)) {
        return;
    }
    move_menu(hwnd);
}

/// The agent window a menu belongs to, if it's an agent's: its owner, or with
/// no owner, the window the agent is acting on in that app.
fn menu_owner(s: &State, menu: HWND) -> Option<HWND> {
    let owner = unsafe { GetAncestor(menu, GA_ROOTOWNER) };
    if owner != menu && !owner.0.is_null() {
        return s.agent_windows.contains(&(owner.0 as usize)).then_some(owner);
    }
    let pid = win::pid_tid(menu).0;
    let now = Instant::now();
    let user_recent = s.last_user_switch.is_some_and(|t| now.duration_since(t) < Duration::from_millis(300));
    let acting = s.acting.iter().any(|(p, until)| *p == pid && until.is_none_or(|u| u > now));
    let target = s.targets.iter().find(|(p, _)| *p == pid).map(|(_, h)| HWND(*h as *mut _))?;
    (acting && !user_recent && s.agent_windows.contains(&(target.0 as usize))).then_some(target)
}

/// If `menu` is an agent's menu on a display while its window is on a hidden
/// screen, move it over the window: at the agent's last click if that's in
/// the window, else near its top-left corner.
fn move_menu(menu: HWND) {
    unsafe {
        if GetAncestor(menu, GA_ROOT) != menu || !win::is_visible(menu) || win::is_app_window(menu) {
            return;
        }
    }
    let mut r = RECT::default();
    unsafe {
        let _ = GetWindowRect(menu, &mut r);
    }
    if !monitor::on_screen(&r) {
        return;
    }
    let (owner, last_point) = {
        let s = state();
        if s.agent_windows.contains(&(menu.0 as usize)) {
            return;
        }
        (menu_owner(&s, menu), s.last_point)
    };
    let Some(owner) = owner else { return };
    let f = win::frame(owner);
    if monitor::on_screen(&f) {
        return;
    }
    let (w, h) = (r.right - r.left, r.bottom - r.top);
    let p = match last_point {
        Some((p, t)) if t.elapsed() < Duration::from_secs(5) && inside(&f, p) => p,
        _ => POINT { x: f.left + 40, y: f.top + 80 },
    };
    let x = p.x.min(f.right - w).max(f.left);
    let y = p.y.min(f.bottom - h).max(f.top);
    unsafe {
        let _ = SetWindowPos(menu, None, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    }
    let mut s = state();
    s.moved.retain(|h| win::exists(HWND(*h as *mut _)));
    s.moved.insert(menu.0 as usize);
}

fn inside(r: &RECT, p: POINT) -> bool {
    p.x >= r.left && p.x < r.right && p.y >= r.top && p.y < r.bottom
}

/// The nearest point just outside `r`.
fn outside(r: &RECT, p: POINT) -> POINT {
    let candidates = [
        (p.x - r.left + 1, POINT { x: r.left - 1, y: p.y }),
        (r.right - p.x, POINT { x: r.right, y: p.y }),
        (p.y - r.top + 1, POINT { x: p.x, y: r.top - 1 }),
        (r.bottom - p.y, POINT { x: p.x, y: r.bottom }),
    ];
    candidates.into_iter().min_by_key(|(d, _)| *d).map(|(_, q)| q).unwrap_or(p)
}
