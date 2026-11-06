//! Keeps agent windows off the user's screen, from the moment they're shown.
//!
//! Two layers:
//! - Inside the app (bcu_hook.dll, see hook/src/lib.rs): an in-context
//!   WinEvent hook on each process the agent opens windows in or has windows
//!   in. It moves a new window to the agent's screen on the app's own thread,
//!   while the app creates or shows it, and puts an agent window back the
//!   moment the app moves it onto the user's screen.
//! - From here (`watch`, called from the guard's event hooks): the same moves
//!   for apps the DLL can't load into (UWP and elevated apps, or no DLL).
//!   These land once the app's thread gets to them, after it showed the
//!   window: measured 16-38 ms on the user's screen.
//!
//! Both read the table in shared memory this module writes (`bcu_hook::Shared`).

use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Mutex, OnceLock, mpsc};
use std::time::{Duration, Instant};

use bcu_hook::{EXE_LEN, From, Kept, MAX_AREAS, Open, Shared};
use windows::Win32::Foundation::{HMODULE, HWND, INVALID_HANDLE_VALUE, LPARAM, RECT, WPARAM};
use windows::Win32::System::LibraryLoader::{GetProcAddress, LoadLibraryW};
use windows::Win32::System::Memory::{CreateFileMappingW, FILE_MAP_ALL_ACCESS, MapViewOfFile, PAGE_READWRITE};
use windows::Win32::System::SystemInformation::GetTickCount64;
use windows::Win32::System::Threading::GetCurrentThreadId;
use windows::Win32::UI::Accessibility::{HWINEVENTHOOK, SetWinEventHook, UnhookWinEvent, WINEVENTPROC};
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::HSTRING;

use crate::win;

/// How long an open waits for its window at most; it normally ends as soon as the window shows.
const OPEN_LIMIT: Duration = Duration::from_secs(20);

static SHARED: OnceLock<usize> = OnceLock::new();
/// Serializes writes to the table.
static WRITE: Mutex<()> = Mutex::new(());
static NEXT_OPEN: AtomicU32 = AtomicU32::new(1);
static HOOKS: OnceLock<Mutex<HookThread>> = OnceLock::new();
/// Kept windows and the process each one's hook is on.
static KEPT_PIDS: Mutex<Vec<(usize, u32)>> = Mutex::new(Vec::new());
/// Processes hooked for an open, by the open's id.
static OPEN_PIDS: Mutex<Vec<(u32, u32)>> = Mutex::new(Vec::new());

struct HookThread {
    tx: mpsc::Sender<Cmd>,
    tid: u32,
}

enum Cmd {
    Hook(u32, mpsc::Sender<bool>),
    Unhook(u32),
}

fn shared() -> Option<&'static Shared> {
    SHARED.get().map(|p| unsafe { &*(*p as *const Shared) })
}

fn write(f: impl FnOnce(&mut bcu_hook::Table)) {
    if let Some(s) = shared() {
        let _lock = WRITE.lock().unwrap_or_else(|e| e.into_inner());
        s.write(f);
    }
}

fn now_ms() -> u64 {
    unsafe { GetTickCount64() }
}

/// Create the shared table and, if bcu_hook.dll is next to the app, the
/// thread that hooks it into apps. Call once at start.
pub fn start() {
    unsafe {
        let Ok(mapping) = CreateFileMappingW(INVALID_HANDLE_VALUE, None, PAGE_READWRITE, 0, Shared::SIZE as u32, bcu_hook::MAPPING) else {
            eprintln!("offscreen: couldn't create the shared table");
            return;
        };
        let view = MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, Shared::SIZE);
        if view.Value.is_null() {
            return;
        }
        // The mapping stays open for the app's lifetime.
        let _ = SHARED.set(view.Value as usize);
    }
    let dll = std::env::current_exe().ok().and_then(|e| e.parent().map(|d| d.join("bcu_hook.dll")));
    let Some(dll) = dll.filter(|p| p.exists()) else {
        eprintln!("offscreen: bcu_hook.dll not found; moving windows from outside only");
        return;
    };
    let (ready_tx, ready_rx) = mpsc::channel();
    std::thread::Builder::new()
        .name("window-hooks".into())
        .spawn(move || hook_thread(dll, ready_tx))
        .expect("window hooks thread");
    if let Ok(Some(h)) = ready_rx.recv() {
        let _ = HOOKS.set(Mutex::new(h));
    }
}

/// Owns the in-context hooks: Windows removes a hook only on the thread that set it.
fn hook_thread(dll: std::path::PathBuf, ready: mpsc::Sender<Option<HookThread>>) {
    let (module, callback) = unsafe {
        let Ok(module) = LoadLibraryW(&HSTRING::from(dll.as_os_str())) else {
            let _ = ready.send(None);
            return;
        };
        let Some(proc) = GetProcAddress(module, windows::core::PCSTR(bcu_hook::CALLBACK.as_ptr())) else {
            let _ = ready.send(None);
            return;
        };
        let callback: WINEVENTPROC = Some(std::mem::transmute::<unsafe extern "system" fn() -> isize, unsafe extern "system" fn(HWINEVENTHOOK, u32, HWND, i32, i32, u32, u32)>(proc));
        (module, callback)
    };
    let (tx, rx) = mpsc::channel();
    let mut msg = MSG::default();
    unsafe {
        // Create this thread's message queue before anyone posts to it.
        let _ = PeekMessageW(&mut msg, None, 0, 0, PM_NOREMOVE);
    }
    let _ = ready.send(Some(HookThread { tx, tid: unsafe { GetCurrentThreadId() } }));
    let mut hooks: HashMap<u32, (usize, Vec<HWINEVENTHOOK>)> = HashMap::new();
    loop {
        while let Ok(cmd) = rx.try_recv() {
            match cmd {
                Cmd::Hook(pid, done) => {
                    let entry = hooks.entry(pid).or_insert_with(|| (0, install(module, callback, pid)));
                    entry.0 += 1;
                    let _ = done.send(!entry.1.is_empty());
                }
                Cmd::Unhook(pid) => {
                    if let Some(entry) = hooks.get_mut(&pid) {
                        entry.0 -= 1;
                        if entry.0 == 0 {
                            for h in hooks.remove(&pid).map(|e| e.1).unwrap_or_default() {
                                unsafe {
                                    let _ = UnhookWinEvent(h);
                                }
                            }
                        }
                    }
                }
            }
        }
        unsafe {
            if !GetMessageW(&mut msg, None, 0, 0).as_bool() {
                return;
            }
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
}

fn install(module: HMODULE, callback: WINEVENTPROC, pid: u32) -> Vec<HWINEVENTHOOK> {
    let flags = WINEVENT_INCONTEXT | WINEVENT_SKIPOWNPROCESS;
    let ranges = [
        (EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND),
        (EVENT_OBJECT_CREATE, EVENT_OBJECT_SHOW),
        (EVENT_OBJECT_LOCATIONCHANGE, EVENT_OBJECT_LOCATIONCHANGE),
    ];
    let hooks: Vec<HWINEVENTHOOK> =
        ranges.iter().map(|(lo, hi)| unsafe { SetWinEventHook(*lo, *hi, Some(module), callback, pid, 0, flags) }).filter(|h| !h.is_invalid()).collect();
    if hooks.len() < ranges.len() {
        for h in &hooks {
            unsafe {
                let _ = UnhookWinEvent(*h);
            }
        }
        return Vec::new();
    }
    hooks
}

/// Hook the DLL into `pid` (counted; `unhook` undoes one). With `wait`,
/// returns once it's set, so it's in place before the app is asked for a window.
fn hook(pid: u32, wait: bool) {
    let Some(h) = HOOKS.get() else { return };
    let (done_tx, done_rx) = mpsc::channel();
    let tid = {
        let h = h.lock().unwrap_or_else(|e| e.into_inner());
        if h.tx.send(Cmd::Hook(pid, done_tx)).is_err() {
            return;
        }
        h.tid
    };
    unsafe {
        let _ = PostThreadMessageW(tid, WM_APP, WPARAM(0), LPARAM(0));
    }
    if wait {
        let _ = done_rx.recv_timeout(Duration::from_millis(500));
    }
}

fn unhook(pid: u32) {
    let Some(h) = HOOKS.get() else { return };
    let h = h.lock().unwrap_or_else(|e| e.into_inner());
    if h.tx.send(Cmd::Unhook(pid)).is_ok() {
        unsafe {
            let _ = PostThreadMessageW(h.tid, WM_APP, WPARAM(0), LPARAM(0));
        }
    }
}

/// An open_window in progress: new windows of these processes (and of the
/// executable, from outside) go to the agent's screen until it's dropped.
pub struct Opening {
    id: u32,
    area: RECT,
    index: u32,
}

/// Start catching new windows of the app for an agent opening one.
/// `pids`: the app's running processes. `exe`: its path (or only its file
/// name), for a process that starts now.
pub fn begin_open(pids: &[u32], exe: Option<&str>, area: RECT, index: usize) -> Opening {
    let id = NEXT_OPEN.fetch_add(1, Ordering::Relaxed);
    let mut opening = Opening { id, area, index: index as u32 };
    refresh_areas();
    if let Some(exe) = exe {
        let key = bcu_hook::exe_key(&exe.encode_utf16().collect::<Vec<_>>());
        opening.add(0, key);
    }
    for pid in pids {
        opening.add_pid(*pid);
    }
    opening
}

impl Opening {
    fn add(&mut self, pid: u32, exe: [u16; EXE_LEN]) {
        let entry = Open { id: self.id, pid, until: now_ms() + OPEN_LIMIT.as_millis() as u64, exe, area: self.area, index: self.index, _pad: 0 };
        write(|t| {
            if let Some(slot) = t.opens.iter_mut().find(|o| o.id == 0 || o.until <= now_ms()) {
                *slot = entry;
            }
        });
    }

    /// Also catch new windows of this process (the one just started).
    pub fn add_pid(&mut self, pid: u32) {
        if pid == 0 || !hook_for_open(self.id, pid, true) {
            return;
        }
        self.add(pid, [0; EXE_LEN]);
    }
}

impl Drop for Opening {
    fn drop(&mut self) {
        let id = self.id;
        write(|t| {
            for o in t.opens.iter_mut().filter(|o| o.id == id) {
                o.id = 0;
            }
        });
        let pids: Vec<u32> = {
            let mut list = OPEN_PIDS.lock().unwrap_or_else(|e| e.into_inner());
            let (mine, rest) = list.drain(..).partition(|(open, _)| *open == id);
            *list = rest;
            mine.into_iter().map(|(_, pid)| pid).collect()
        };
        for pid in pids {
            unhook(pid);
        }
        CAUGHT_OUTSIDE.lock().unwrap_or_else(|e| e.into_inner()).retain(|(_, open)| *open != id);
    }
}

/// Hook `pid` for the open `id`, once. False if it already was.
fn hook_for_open(id: u32, pid: u32, wait: bool) -> bool {
    {
        let mut list = OPEN_PIDS.lock().unwrap_or_else(|e| e.into_inner());
        if list.contains(&(id, pid)) {
            return false;
        }
        list.push((id, pid));
    }
    hook(pid, wait);
    true
}

/// An agent window: keep it on `area` from now on.
pub fn keep(hwnd: HWND, area: RECT, index: usize) {
    refresh_areas();
    let h = hwnd.0 as usize as u64;
    write(|t| {
        let entry = Kept { hwnd: h, area, index: index as u32, _pad: 0 };
        if let Some(slot) = t.kept.iter_mut().find(|k| k.hwnd == h) {
            *slot = entry;
        } else if let Some(slot) = t.kept.iter_mut().find(|k| k.hwnd == 0 || !win::exists(HWND(k.hwnd as usize as *mut _))) {
            *slot = entry;
        }
    });
    let pid = win::pid_tid(hwnd).0;
    let mut pids = KEPT_PIDS.lock().unwrap_or_else(|e| e.into_inner());
    if pid != 0 && !pids.iter().any(|(w, _)| *w == hwnd.0 as usize) {
        pids.push((hwnd.0 as usize, pid));
        drop(pids);
        hook(pid, true);
    }
}

/// No longer an agent window (released, handed off, closed).
pub fn forget(hwnd: HWND) {
    let h = hwnd.0 as usize as u64;
    write(|t| {
        for k in t.kept.iter_mut().filter(|k| k.hwnd == h) {
            k.hwnd = 0;
        }
    });
    let mut pids = KEPT_PIDS.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(i) = pids.iter().position(|(w, _)| *w == hwnd.0 as usize) {
        let (_, pid) = pids.remove(i);
        drop(pids);
        unhook(pid);
    }
}

/// Where the agent just clicked, for placing the popup it opens.
pub fn set_last_point(x: i32, y: i32) {
    let now = now_ms();
    write(|t| {
        t.last_point = (x, y);
        t.last_point_at = now;
    });
}

pub fn set_user_window(hwnd: HWND) {
    let h = hwnd.0 as usize as u64;
    if shared().and_then(|s| s.read()).is_some_and(|t| t.user_window != h) {
        write(|t| t.user_window = h);
    }
}

/// The agent monitors that are real displays, so the DLL can tell them from the user's.
fn refresh_areas() {
    let areas: Vec<RECT> = crate::monitor::all().iter().map(|m| m.rect).take(MAX_AREAS).collect();
    write(|t| {
        t.areas = [RECT::default(); MAX_AREAS];
        t.areas[..areas.len()].copy_from_slice(&areas);
        t.area_count = areas.len() as u32;
    });
}

/// Windows caught from outside during an open, with the open's id.
static CAUGHT_OUTSIDE: Mutex<Vec<(usize, u32)>> = Mutex::new(Vec::new());
/// Moves from outside, per window, to stop fighting an app that keeps moving back.
static MOVES: Mutex<Vec<(usize, Instant, u32)>> = Mutex::new(Vec::new());
static EXES: Mutex<Vec<(u32, [u16; EXE_LEN])>> = Mutex::new(Vec::new());

fn exe_of(pid: u32) -> [u16; EXE_LEN] {
    let mut cache = EXES.lock().unwrap_or_else(|e| e.into_inner());
    if let Some((_, k)) = cache.iter().find(|(p, _)| *p == pid) {
        return *k;
    }
    let key = bcu_hook::exe_key(&win::exe_path(pid).unwrap_or_default().encode_utf16().collect::<Vec<_>>());
    if cache.len() > 256 {
        cache.clear();
    }
    cache.push((pid, key));
    key
}

/// From the guard's out-of-context hook, for EVENT_OBJECT_CREATE on any
/// window, and EVENT_OBJECT_SHOW and EVENT_OBJECT_LOCATIONCHANGE on a
/// top-level one: the outside layer. Returns whether the window is an
/// agent's (so the menu logic skips it).
pub fn watch(event: u32, hwnd: HWND) -> bool {
    let Some(table) = shared().and_then(|s| s.read()) else { return false };
    let now = now_ms();
    if event == EVENT_OBJECT_CREATE {
        // A process of the app being opened that just started (the shell
        // starts some apps, like packaged ones, through a broker, and returns
        // only once their window is up): hook it at its first window, a
        // helper it makes well before the one the agent gets.
        let opens: Vec<u32> = table.opens.iter().filter(|o| o.id != 0 && o.until > now && o.pid == 0).map(|o| o.id).collect();
        if !opens.is_empty() {
            let pid = win::pid_tid(hwnd).0;
            let exe = exe_of(pid);
            for o in table.opens.iter().filter(|o| opens.contains(&o.id) && o.pid == 0 && bcu_hook::exe_matches(&o.exe, &exe)) {
                hook_for_open(o.id, pid, false);
            }
        }
        return false;
    }
    let h = hwnd.0 as usize;
    let mut target = table.kept(hwnd).map(|k| (k.area, k.index));
    if target.is_none() {
        let mut caught = CAUGHT_OUTSIDE.lock().unwrap_or_else(|e| e.into_inner());
        let known = caught.iter().find(|(w, _)| *w == h).map(|(_, id)| *id);
        target = match known.and_then(|id| table.opens.iter().find(|o| o.id == id && o.until > now)) {
            Some(o) => Some((o.area, o.index)),
            None if event == EVENT_OBJECT_SHOW && table.opens.iter().any(|o| o.id != 0 && o.until > now) => {
                let pid = win::pid_tid(hwnd).0;
                let open = table.open_for(pid, &exe_of(pid), now).filter(|_| bcu_hook::is_candidate(hwnd));
                if let Some(o) = open {
                    caught.push((h, o.id));
                }
                open.map(|o| (o.area, o.index))
            }
            None => None,
        };
    }
    let Some((area, index)) = target else { return false };
    if bcu_hook::showing_to_user(hwnd, table.agent_areas()) && may_move(h) {
        bcu_hook::place(hwnd, area, index, From::OutsideAsync);
    }
    true
}

fn may_move(h: usize) -> bool {
    let mut moves = MOVES.lock().unwrap_or_else(|e| e.into_inner());
    moves.retain(|(w, since, _)| *w == h || since.elapsed() < Duration::from_secs(10));
    match moves.iter_mut().find(|(w, _, _)| *w == h) {
        Some((_, since, n)) => {
            if since.elapsed() > Duration::from_secs(2) {
                *since = Instant::now();
                *n = 0;
            }
            *n += 1;
            *n <= 20
        }
        None => {
            moves.push((h, Instant::now(), 1));
            true
        }
    }
}
