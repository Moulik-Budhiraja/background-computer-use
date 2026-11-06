//! bcu_hook.dll: keeps agent windows off the user's screen from inside the
//! app that shows them.
//!
//! An app creates and shows a window on its own UI thread, and a move from
//! another process only lands once that thread gets back to its messages,
//! after the window is on screen. Measured over Remote Desktop: a new Notepad
//! window was on the user's screen for 16 ms even when the move was queued
//! before it showed, and a new Edge window, maximized over the whole screen,
//! for 38 ms. So the tray app loads this DLL into the app with an in-context
//! WinEvent hook (`SetWinEventHook` with `WINEVENT_INCONTEXT`, the way screen
//! readers watch apps), only into the processes it opens windows in. The
//! callback runs on the app's own thread while it creates, shows or moves the
//! window, so the window is moved before anything is drawn.
//!
//! What to move comes from shared memory the tray app writes (`Shared`):
//! - opens: while the agent opens a window of an app, new windows that app
//!   creates go to that agent's screen;
//! - kept windows: the agents' windows, put back whenever the app moves them
//!   onto one of the user's screens;
//! - their popups (menus, dropdowns, bubbles): on a hidden screen the app
//!   puts them on a display, so they go back over their window, where the
//!   app first placed them.
//!
//! This code runs inside the user's apps, so it never panics out (every
//! callback is wrapped in `catch_unwind`) and does nothing when it isn't sure.
//!
//! The same file is also the tray app's library for the layout and for
//! `place`, which it uses from outside when the DLL can't be loaded (a UWP
//! app, an elevated one).

use std::cell::UnsafeCell;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU32, AtomicU64, AtomicUsize, Ordering, fence};

use windows::Win32::Foundation::{CloseHandle, HWND, LPARAM, RECT};
use windows::Win32::Graphics::Gdi::{EnumDisplayMonitors, HDC, HMONITOR};
use windows::Win32::System::LibraryLoader::GetModuleFileNameW;
use windows::Win32::System::Memory::{FILE_MAP_READ, MapViewOfFile, OpenFileMappingW};
use windows::Win32::System::SystemInformation::GetTickCount64;
use windows::Win32::System::Threading::GetCurrentProcessId;
use windows::Win32::UI::Accessibility::HWINEVENTHOOK;
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::{BOOL, PCWSTR, w};

/// The shared memory's name. "Local\" is per Windows session, like the app.
pub const MAPPING: PCWSTR = w!("Local\\BackgroundComputerUse-windows");
/// The callback's exported name, for GetProcAddress.
pub const CALLBACK: &[u8] = b"bcu_win_event\0";

pub const MAX_OPENS: usize = 8;
pub const MAX_KEPT: usize = 64;
pub const MAX_AREAS: usize = 8;
pub const EXE_LEN: usize = 260;

/// An app the agent is opening a window of. One entry per process to watch
/// (`pid`), or with `pid` 0, every process of the program `exe`.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Open {
    /// Which open_window this is (several entries can share it). 0 = unused.
    pub id: u32,
    pub pid: u32,
    /// GetTickCount64 deadline; the open is over after it.
    pub until: u64,
    /// The program: its lowercase full path, or only its file name when
    /// that's all that's known ("notepad.exe"). NUL-padded. Helium and
    /// Chrome are both chrome.exe, so the path matters.
    pub exe: [u16; EXE_LEN],
    /// The agent's screen.
    pub area: RECT,
    /// Which of the agent's windows this is, for the cascade.
    pub index: u32,
    pub _pad: u32,
}

/// An agent's window and where it lives.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Kept {
    /// 0 = unused.
    pub hwnd: u64,
    pub area: RECT,
    pub index: u32,
    pub _pad: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct Table {
    /// The user's foreground window, to give back when a new agent window takes it.
    pub user_window: u64,
    pub opens: [Open; MAX_OPENS],
    pub kept: [Kept; MAX_KEPT],
    /// The agent screens that are real monitors (none on hidden screens):
    /// every other monitor is the user's.
    pub areas: [RECT; MAX_AREAS],
    pub area_count: u32,
    pub _pad: u32,
    /// Where an agent last clicked, and when (GetTickCount64), for placing
    /// the popup it opened.
    pub last_point: (i32, i32),
    pub last_point_at: u64,
}

/// The shared memory: a table behind a sequence lock. Only the tray app
/// writes (under its own lock); the DLL copies the table and retries if a
/// write happened meanwhile.
#[repr(C)]
pub struct Shared {
    seq: AtomicU32,
    _pad: u32,
    table: UnsafeCell<Table>,
}

unsafe impl Sync for Shared {}

impl Shared {
    pub const SIZE: usize = size_of::<Shared>();

    pub fn read(&self) -> Option<Table> {
        for _ in 0..100 {
            let before = self.seq.load(Ordering::Acquire);
            if before & 1 == 0 {
                let t = unsafe { std::ptr::read_volatile(self.table.get()) };
                fence(Ordering::Acquire);
                if self.seq.load(Ordering::Relaxed) == before {
                    return Some(t);
                }
            }
            std::hint::spin_loop();
        }
        None
    }

    /// The writer's side. Callers serialize writes themselves.
    pub fn write(&self, f: impl FnOnce(&mut Table)) {
        let s = self.seq.load(Ordering::Relaxed);
        self.seq.store(s.wrapping_add(1), Ordering::Relaxed);
        fence(Ordering::Release);
        let mut t = unsafe { std::ptr::read_volatile(self.table.get()) };
        f(&mut t);
        unsafe { std::ptr::write_volatile(self.table.get(), t) };
        self.seq.store(s.wrapping_add(2), Ordering::Release);
    }
}

impl Table {
    /// The open, if any, that new windows of this process belong to.
    pub fn open_for(&self, pid: u32, exe: &[u16; EXE_LEN], now: u64) -> Option<Open> {
        self.opens
            .iter()
            .find(|o| o.id != 0 && o.until > now && (o.pid == pid || (o.pid == 0 && exe_matches(&o.exe, exe))))
            .copied()
    }

    pub fn open_active(&self, id: u32, now: u64) -> bool {
        id != 0 && self.opens.iter().any(|o| o.id == id && o.until > now)
    }

    pub fn kept(&self, hwnd: HWND) -> Option<Kept> {
        let h = hwnd.0 as usize as u64;
        self.kept.iter().find(|k| k.hwnd != 0 && k.hwnd == h).copied()
    }

    pub fn agent_areas(&self) -> &[RECT] {
        &self.areas[..(self.area_count as usize).min(MAX_AREAS)]
    }
}

/// A program's path (or file name) in lowercase, NUL-padded, for `Open::exe`.
pub fn exe_key(path: &[u16]) -> [u16; EXE_LEN] {
    let mut out = [0u16; EXE_LEN];
    for (o, c) in out.iter_mut().zip(path.iter().take_while(|c| **c != 0)) {
        *o = if (b'A' as u16..=b'Z' as u16).contains(c) { c + 32 } else { *c };
    }
    out
}

/// Whether the process running `have` (a full path key) is the program
/// `want` names: the same path, or the same file name when `want` is only one.
pub fn exe_matches(want: &[u16; EXE_LEN], have: &[u16; EXE_LEN]) -> bool {
    let len = |k: &[u16; EXE_LEN]| k.iter().position(|c| *c == 0).unwrap_or(EXE_LEN);
    let (want, have) = (&want[..len(want)], &have[..len(have)]);
    if want.is_empty() {
        return false;
    }
    if want.contains(&(b'\\' as u16)) {
        return want == have;
    }
    let name = have.iter().rposition(|c| *c == b'\\' as u16).map_or(have, |i| &have[i + 1..]);
    name == want
}

// ---------- placing windows (shared with the tray app) ----------

/// Where the n-th agent window goes on its screen, keeping its size if it fits.
pub fn slot(area: RECT, index: u32, w: i32, h: i32) -> (i32, i32, i32, i32) {
    let aw = area.right - area.left;
    let ah = area.bottom - area.top;
    let w = w.clamp(400, (aw - 40).max(400));
    let h = h.clamp(300, (ah - 40).max(300));
    let step = (index % 6) as i32 * 30;
    let x = (area.left + 20 + step).min(area.right - w);
    let y = (area.top + 20 + step).min(area.bottom - h);
    (x, y, w, h)
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum From {
    /// On the window's own thread (the DLL): immediate.
    Inside,
    /// From another thread that may wait for the window's thread.
    Outside,
    /// From another thread that must not wait (the tray app's event hooks).
    OutsideAsync,
}

/// Move `hwnd` to its slot on `area`. A maximized window is restored into
/// the slot without being activated, except from `OutsideAsync`, where that
/// would wait on the app; it's then moved as it is.
pub fn place(hwnd: HWND, area: RECT, index: u32, from: From) {
    unsafe {
        let mut wp = WINDOWPLACEMENT { length: size_of::<WINDOWPLACEMENT>() as u32, ..Default::default() };
        let _ = GetWindowPlacement(hwnd, &mut wp);
        let zoomed = IsZoomed(hwnd).as_bool();
        let mut r = RECT::default();
        if zoomed {
            r = wp.rcNormalPosition;
        } else {
            let _ = GetWindowRect(hwnd, &mut r);
        }
        let (x, y, w, h) = slot(area, index, r.right - r.left, r.bottom - r.top);
        if zoomed && from != From::OutsideAsync {
            wp.showCmd = SW_SHOWNOACTIVATE.0 as u32;
            wp.flags = WINDOWPLACEMENT_FLAGS(0);
            wp.rcNormalPosition = RECT { left: x, top: y, right: x + w, bottom: y + h };
            let _ = SetWindowPlacement(hwnd, &wp);
        }
        let mut flags = SWP_NOZORDER | SWP_NOACTIVATE;
        if from == From::OutsideAsync {
            flags |= SWP_ASYNCWINDOWPOS;
        }
        let _ = SetWindowPos(hwnd, None, x, y, w, h, flags);
    }
}

/// Whether any part of `r` is on a monitor that isn't one of `agent_areas`.
pub fn on_user_screen(r: &RECT, agent_areas: &[RECT]) -> bool {
    struct Ctx<'a> {
        r: RECT,
        areas: &'a [RECT],
        hit: bool,
    }
    unsafe extern "system" fn each(_: HMONITOR, _: HDC, m: *mut RECT, data: LPARAM) -> BOOL {
        let ctx = unsafe { &mut *(data.0 as *mut Ctx) };
        let m = unsafe { *m };
        let overlaps = ctx.r.left < m.right && ctx.r.right > m.left && ctx.r.top < m.bottom && ctx.r.bottom > m.top;
        let agents = ctx.areas.iter().any(|a| a.left == m.left && a.top == m.top && a.right == m.right && a.bottom == m.bottom);
        if overlaps && !agents {
            ctx.hit = true;
            return false.into();
        }
        true.into()
    }
    if r.right <= r.left || r.bottom <= r.top {
        return false;
    }
    let mut ctx = Ctx { r: *r, areas: agent_areas, hit: false };
    unsafe {
        let _ = EnumDisplayMonitors(None, None, Some(each), LPARAM(&mut ctx as *mut _ as isize));
    }
    ctx.hit
}

/// A window a person would see as an app window, judged before it's shown:
/// top-level, unowned, not a tool window, with a caption or a sizing border.
/// (Hidden helper windows pass too; they're never moved, because only shown
/// windows are.)
pub fn is_candidate(hwnd: HWND) -> bool {
    unsafe {
        if GetAncestor(hwnd, GA_ROOT) != hwnd || !GetWindow(hwnd, GW_OWNER).unwrap_or_default().0.is_null() {
            return false;
        }
        let style = GetWindowLongW(hwnd, GWL_STYLE) as u32;
        let ex = GetWindowLongW(hwnd, GWL_EXSTYLE) as u32;
        if style & WS_CHILD.0 != 0 || ex & WS_EX_TOOLWINDOW.0 != 0 {
            return false;
        }
        style & WS_CAPTION.0 == WS_CAPTION.0 || style & WS_THICKFRAME.0 != 0
    }
}

/// Whether the window is showing somewhere on the user's screens.
pub fn showing_to_user(hwnd: HWND, agent_areas: &[RECT]) -> bool {
    unsafe {
        if !IsWindowVisible(hwnd).as_bool() || IsIconic(hwnd).as_bool() {
            return false;
        }
        let mut r = RECT::default();
        if GetWindowRect(hwnd, &mut r).is_err() {
            return false;
        }
        on_user_screen(&r, agent_areas)
    }
}

/// Whether the window is placed on the user's screens: shown, or still
/// hidden and window-sized (apps make small hidden helper windows that never
/// show; they're left where they are).
pub fn placed_on_user_screen(hwnd: HWND, agent_areas: &[RECT]) -> bool {
    unsafe {
        if IsIconic(hwnd).as_bool() {
            return false;
        }
        let mut r = RECT::default();
        if GetWindowRect(hwnd, &mut r).is_err() {
            return false;
        }
        let small = r.right - r.left < 200 || r.bottom - r.top < 100;
        if small && !IsWindowVisible(hwnd).as_bool() {
            return false;
        }
        on_user_screen(&r, agent_areas)
    }
}

// ---------- the DLL, inside the app ----------

/// A window this process created or showed during an open, or an agent
/// window it moved: where it goes, and how often it was moved lately.
#[derive(Clone, Copy)]
struct Caught {
    hwnd: usize,
    open: u32,
    area: RECT,
    index: u32,
    moves: u32,
    since: u64,
    /// For a popup: where the app put it over its window, before it moved
    /// it onto a display.
    anchor: Option<(i32, i32)>,
}

const EMPTY: Caught = Caught { hwnd: 0, open: 0, area: RECT { left: 0, top: 0, right: 0, bottom: 0 }, index: 0, moves: 0, since: 0, anchor: None };
/// An app that keeps moving its window back is left alone after this many
/// moves in `BURST_MS`, so the two never fight.
const MAX_MOVES: u32 = 20;
const BURST_MS: u64 = 2000;

static CAUGHT: Mutex<[Caught; 32]> = Mutex::new([EMPTY; 32]);

thread_local! {
    /// Set while this thread is moving a window, so the events the move
    /// raises on the same thread aren't handled again.
    static PLACING: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}
static VIEW: AtomicUsize = AtomicUsize::new(0);
static LAST_TRY: AtomicU64 = AtomicU64::new(0);
static EXE: Mutex<Option<[u16; EXE_LEN]>> = Mutex::new(None);

fn shared() -> Option<&'static Shared> {
    let p = VIEW.load(Ordering::Acquire);
    if p != 0 {
        return Some(unsafe { &*(p as *const Shared) });
    }
    let now = unsafe { GetTickCount64() };
    let last = LAST_TRY.load(Ordering::Relaxed);
    if last != 0 && now.saturating_sub(last) < 1000 {
        return None;
    }
    LAST_TRY.store(now.max(1), Ordering::Relaxed);
    unsafe {
        let handle = OpenFileMappingW(FILE_MAP_READ.0, false, MAPPING).ok()?;
        let view = MapViewOfFile(handle, FILE_MAP_READ, 0, 0, Shared::SIZE);
        // The view keeps the mapping alive.
        let _ = CloseHandle(handle);
        if view.Value.is_null() {
            return None;
        }
        let p = view.Value as usize;
        match VIEW.compare_exchange(0, p, Ordering::AcqRel, Ordering::Acquire) {
            Ok(_) => Some(&*(p as *const Shared)),
            // Another thread mapped it first; this view stays mapped, unused.
            Err(existing) => Some(&*(existing as *const Shared)),
        }
    }
}

fn own_exe() -> [u16; EXE_LEN] {
    let mut cached = EXE.lock().unwrap_or_else(|e| e.into_inner());
    *cached.get_or_insert_with(|| {
        let mut buf = [0u16; 1024];
        let n = unsafe { GetModuleFileNameW(None, &mut buf) } as usize;
        exe_key(&buf[..n.min(buf.len())])
    })
}

/// A slot for a window not tracked yet: a free one or a closed window's,
/// else the oldest hidden window's (apps make many hidden helpers), else the oldest.
fn free_slot(c: &[Caught]) -> usize {
    let window = |s: &Caught| HWND(s.hwnd as *mut _);
    if let Some(i) = c.iter().position(|s| s.hwnd == 0 || !unsafe { IsWindow(Some(window(s))) }.as_bool()) {
        return i;
    }
    let oldest = |hidden_only: bool| {
        c.iter()
            .enumerate()
            .filter(|(_, s)| !hidden_only || !unsafe { IsWindowVisible(window(s)) }.as_bool())
            .min_by_key(|(_, s)| s.since)
            .map(|(i, _)| i)
    };
    oldest(true).or_else(|| oldest(false)).unwrap_or(0)
}

fn remember(hwnd: HWND, open: &Open) {
    let mut c = CAUGHT.lock().unwrap_or_else(|e| e.into_inner());
    let h = hwnd.0 as usize;
    if let Some(slot) = c.iter_mut().find(|s| s.hwnd == h) {
        slot.open = open.id;
        slot.area = open.area;
        slot.index = open.index;
        return;
    }
    let now = unsafe { GetTickCount64() };
    let i = free_slot(&*c);
    c[i] = Caught { hwnd: h, open: open.id, area: open.area, index: open.index, moves: 0, since: now, anchor: None };
}

/// Count a move of `hwnd`; false once the app has moved it back too often.
fn may_move(hwnd: HWND, area: RECT, index: u32) -> bool {
    let mut c = CAUGHT.lock().unwrap_or_else(|e| e.into_inner());
    let h = hwnd.0 as usize;
    let now = unsafe { GetTickCount64() };
    let i = match c.iter().position(|s| s.hwnd == h) {
        Some(i) => i,
        None => {
            let i = free_slot(&*c);
            c[i] = Caught { hwnd: h, open: 0, area, index, moves: 0, since: now, anchor: None };
            i
        }
    };
    let s = &mut c[i];
    if now.saturating_sub(s.since) > BURST_MS {
        s.since = now;
        s.moves = 0;
    }
    s.moves += 1;
    s.moves <= MAX_MOVES
}

fn caught(hwnd: HWND) -> Option<Caught> {
    let c = CAUGHT.lock().unwrap_or_else(|e| e.into_inner());
    c.iter().find(|s| s.hwnd != 0 && s.hwnd == hwnd.0 as usize).copied()
}

fn set_anchor(hwnd: HWND, at: (i32, i32)) {
    let mut c = CAUGHT.lock().unwrap_or_else(|e| e.into_inner());
    let h = hwnd.0 as usize;
    let i = match c.iter().position(|s| s.hwnd == h) {
        Some(i) => i,
        None => {
            let i = free_slot(&*c);
            c[i] = Caught { hwnd: h, since: unsafe { GetTickCount64() }, ..EMPTY };
            i
        }
    };
    c[i].anchor = Some(at);
}

/// The agent window a popup belongs to (its root owner), if it's one.
fn agent_owner(hwnd: HWND, table: &Table, now: u64) -> Option<HWND> {
    let owner = unsafe { GetAncestor(hwnd, GA_ROOTOWNER) };
    if owner.0.is_null() || owner == hwnd {
        return None;
    }
    (table.kept(owner).is_some() || caught(owner).is_some_and(|c| table.open_active(c.open, now))).then_some(owner)
}

/// A popup of an agent window on a hidden screen: keep it over its window.
/// Where the app put it there is remembered, and it goes back to that spot
/// when the app moves it onto a display (Chromium keeps its bubbles and
/// menus on one); else to the agent's last click, else near the top left.
fn keep_popup(hwnd: HWND, owner: HWND, table: &Table, now: u64) {
    let areas = table.agent_areas();
    let (mut r, mut f) = (RECT::default(), RECT::default());
    unsafe {
        if GetWindowRect(hwnd, &mut r).is_err() || GetWindowRect(owner, &mut f).is_err() || IsIconic(hwnd).as_bool() {
            return;
        }
    }
    // The owner is on a real screen (an agent monitor, or handed to the user): nothing to do.
    if on_user_screen(&f, areas) {
        return;
    }
    let inside = |x: i32, y: i32| x >= f.left && x < f.right && y >= f.top && y < f.bottom;
    if !on_user_screen(&r, areas) {
        if inside(r.left, r.top) {
            set_anchor(hwnd, (r.left, r.top));
        }
        return;
    }
    let (w, h) = (r.right - r.left, r.bottom - r.top);
    let clicked = (now.saturating_sub(table.last_point_at) < 5000 && inside(table.last_point.0, table.last_point.1)).then_some(table.last_point);
    let (x, y) = caught(hwnd).and_then(|c| c.anchor).or(clicked).unwrap_or((f.left + 40, f.top + 80));
    let x = x.min(f.right - w).max(f.left);
    let y = y.min(f.bottom - h).max(f.top);
    if may_move(hwnd, f, 0) {
        debug_log(|| format!("popup {:?} to {x},{y}", hwnd.0));
        PLACING.with(|p| p.set(true));
        unsafe {
            let _ = SetWindowPos(hwnd, None, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
        }
        PLACING.with(|p| p.set(false));
    }
}

/// Debug builds with BCU_HOOK_LOG set at build time append what they do to %TEMP%\bcu_hook.log.
fn debug_log(f: impl FnOnce() -> String) {
    if option_env!("BCU_HOOK_LOG").is_some() {
        use std::io::Write;
        let path = std::env::temp_dir().join("bcu_hook.log");
        if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
            let _ = writeln!(file, "{} pid {} {}", unsafe { GetTickCount64() }, unsafe { GetCurrentProcessId() }, f());
        }
    }
}

fn handle(event: u32, hwnd: HWND, object: i32, child: i32) {
    if hwnd.0.is_null() {
        return;
    }
    let foreground = event == EVENT_SYSTEM_FOREGROUND;
    // Only top-level windows themselves (location changes also come for
    // carets, cursors and child windows, all the time).
    if !foreground && (object != OBJID_WINDOW.0 || child != CHILDID_SELF as i32 || unsafe { GetAncestor(hwnd, GA_ROOT) } != hwnd) {
        return;
    }
    if PLACING.with(|p| p.get()) {
        return;
    }
    debug_log(|| format!("event {event:#x} hwnd {:?}", hwnd.0));
    let Some(shared) = shared() else { return };
    let Some(table) = shared.read() else { return };
    let now = unsafe { GetTickCount64() };
    match event {
        EVENT_OBJECT_CREATE | EVENT_OBJECT_SHOW | EVENT_OBJECT_LOCATIONCHANGE => {
            if let Some(owner) = agent_owner(hwnd, &table, now) {
                keep_popup(hwnd, owner, &table, now);
                return;
            }
            // A window this app creates or shows while the agent opens one of
            // its windows is the agent's.
            if event != EVENT_OBJECT_LOCATIONCHANGE
                && caught(hwnd).is_none_or(|c| !table.open_active(c.open, now))
                && let Some(open) = table.open_for(unsafe { GetCurrentProcessId() }, &own_exe(), now)
                && is_candidate(hwnd)
            {
                remember(hwnd, &open);
            }
            // An agent window is moved back when it shows on the user's
            // screen. A new one is moved while still hidden, every time the
            // app positions it, so it's already off the user's screen when
            // it shows: moving it as it shows races the compositor.
            let (target, hidden_too) = match table.kept(hwnd) {
                Some(k) => (Some((k.area, k.index)), false),
                None => (caught(hwnd).filter(|c| table.open_active(c.open, now)).map(|c| (c.area, c.index)), true),
            };
            let on_user_screen = || {
                if hidden_too { placed_on_user_screen(hwnd, table.agent_areas()) } else { showing_to_user(hwnd, table.agent_areas()) }
            };
            if let Some((area, index)) = target
                && on_user_screen()
                && may_move(hwnd, area, index)
            {
                debug_log(|| format!("placing {:?} on {event:#x}", hwnd.0));
                // The app answers the move with its own window messages,
                // which can raise more of these events on this thread.
                PLACING.with(|p| p.set(true));
                place(hwnd, area, index, From::Inside);
                PLACING.with(|p| p.set(false));
            }
        }
        EVENT_SYSTEM_FOREGROUND => {
            // A window being opened for the agent activated itself: give the
            // foreground straight back from here, where it's allowed.
            let new = caught(hwnd).is_some_and(|c| table.open_active(c.open, now));
            let user = HWND(table.user_window as usize as *mut _);
            if new && !user.0.is_null() && user != hwnd && unsafe { IsWindow(Some(user)) }.as_bool() {
                unsafe {
                    let _ = SetForegroundWindow(user);
                }
            }
        }
        _ => {}
    }
}

/// The WinEvent callback, run inside the app on the thread that raised the event.
///
/// # Safety
/// Called by Windows as a WINEVENTPROC.
#[unsafe(no_mangle)]
pub unsafe extern "system" fn bcu_win_event(_hook: HWINEVENTHOOK, event: u32, hwnd: HWND, object: i32, child: i32, _thread: u32, _time: u32) {
    let _ = std::panic::catch_unwind(|| handle(event, hwnd, object, child));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn programs_match_by_path_or_by_name() {
        let key = |s: &str| exe_key(&s.encode_utf16().collect::<Vec<_>>());
        let helium = key(r"C:\Users\x\AppData\Local\imput\Helium\Application\Chrome.EXE");
        let chrome = key(r"C:\Program Files\Google\Chrome\Application\chrome.exe");
        assert!(exe_matches(&key(r"c:\users\x\appdata\local\imput\helium\application\chrome.exe"), &helium));
        assert!(!exe_matches(&helium, &chrome));
        assert!(exe_matches(&key("chrome.exe"), &chrome) && exe_matches(&key("chrome.exe"), &helium));
        assert!(!exe_matches(&key(""), &chrome));
    }

    #[test]
    fn slot_cascades_and_fits() {
        let area = RECT { left: -30000, top: -30000, right: -28400, bottom: -29000 };
        assert_eq!(slot(area, 0, 900, 500), (-29980, -29980, 900, 500));
        assert_eq!(slot(area, 1, 900, 500), (-29950, -29950, 900, 500));
        // Too big: shrunk to the area less a margin, and kept inside.
        let (x, y, w, h) = slot(area, 0, 5000, 5000);
        assert_eq!((w, h), (1560, 960));
        assert!(x + w <= area.right && y + h <= area.bottom);
    }

    #[test]
    fn opens_match_by_pid_or_exe_until_they_expire() {
        let mut t: Table = unsafe { std::mem::zeroed() };
        let exe = exe_key(&r"c:\apps\helium.exe".encode_utf16().collect::<Vec<_>>());
        t.opens[0] = Open { id: 7, pid: 0, until: 100, exe, area: RECT::default(), index: 0, _pad: 0 };
        t.opens[1] = Open { id: 8, pid: 42, until: 100, exe: [0; EXE_LEN], area: RECT::default(), index: 1, _pad: 0 };
        assert_eq!(t.open_for(1, &exe, 50).map(|o| o.id), Some(7));
        assert_eq!(t.open_for(42, &[0; EXE_LEN], 50).map(|o| o.id), Some(8));
        assert!(t.open_for(1, &[0; EXE_LEN], 50).is_none());
        assert!(t.open_for(42, &exe, 150).is_none());
        assert!(t.open_active(8, 50) && !t.open_active(8, 150));
    }

    #[test]
    fn the_table_round_trips_through_the_lock() {
        let s: Shared = unsafe { std::mem::zeroed() };
        s.write(|t| t.user_window = 5);
        assert_eq!(s.read().unwrap().user_window, 5);
    }
}
