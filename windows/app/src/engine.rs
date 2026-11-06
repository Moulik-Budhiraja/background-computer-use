//! Runs tool calls. Each agent session has its own thread, with its own UI
//! Automation client, element references, windows and monitor, so agents work
//! side by side; a session's calls run in order.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock, mpsc};
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};
use windows::Win32::Foundation::{HWND, LPARAM, POINT, RECT, WPARAM};
use windows::Win32::System::Com::{CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx};
use windows::Win32::UI::Accessibility::*;
use windows::Win32::UI::WindowsAndMessaging::{
    PostMessageW, SWP_NOACTIVATE, SWP_NOZORDER, SetWindowPos, WM_CLOSE,
};
use windows::core::BSTR;

use crate::snapshot::{self, Node, Snapshot};
use crate::{apps, browser, capture, guard, input, monitor, sessions, win};

pub struct Image {
    pub mime: String,
    pub data: String,
}

pub struct ToolResult {
    pub text: String,
    pub images: Vec<Image>,
    pub is_error: bool,
}

impl ToolResult {
    pub fn ok(text: impl Into<String>) -> Self {
        ToolResult { text: text.into(), images: Vec::new(), is_error: false }
    }
    pub fn error(text: impl Into<String>) -> Self {
        ToolResult { text: text.into(), images: Vec::new(), is_error: true }
    }
}

pub struct Request {
    pub tool: String,
    pub args: Map<String, Value>,
    pub reply: mpsc::Sender<ToolResult>,
}

type Fallible<T> = Result<T, String>;

#[derive(Clone, Copy, PartialEq)]
enum Kind {
    Opened,
    Borrowed,
    /// Registered by admin_adopt for testing; left where it is and never closed.
    Adopted,
}

impl Kind {
    fn label(self) -> &'static str {
        match self {
            Kind::Opened => "opened",
            Kind::Borrowed => "borrowed",
            Kind::Adopted => "adopted",
        }
    }
}

struct AgentWindow {
    hwnd: HWND,
    pid: u32,
    app: String,
    kind: Kind,
    /// When the agent got it, for the tray's app order.
    opened: Instant,
    /// Where a borrowed window was, to put it back.
    home: Option<RECT>,
    /// Why the agent handed it to the user, while it's handed off.
    handoff: Option<String>,
}

impl AgentWindow {
    fn handed_off(&self) -> bool {
        self.handoff.is_some()
    }
}

pub struct Engine {
    /// The session this engine runs.
    id: String,
    auto: IUIAutomation,
    windows: HashMap<u64, AgentWindow>,
    snapshots: HashMap<u64, Snapshot>,
    last_action: HashMap<u64, Instant>,
}

enum Job {
    Call(Request),
    /// The user is done with the window the agent handed them.
    HandBack,
    /// Close the session's windows, then say so on the channel if there is one.
    Stop(Option<mpsc::Sender<()>>),
}

/// Set when the app is quitting: batches stop between steps and waits end early.
static QUITTING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

fn quitting() -> bool {
    QUITTING.load(std::sync::atomic::Ordering::Relaxed)
}

/// Every session's queue, by session id.
static SESSIONS: OnceLock<Mutex<HashMap<String, mpsc::Sender<Job>>>> = OnceLock::new();
/// Opening a window watches for the app's next new window; one at a time, so
/// two sessions opening the same app don't take each other's.
static OPENING: Mutex<()> = Mutex::new(());

fn queues() -> std::sync::MutexGuard<'static, HashMap<String, mpsc::Sender<Job>>> {
    SESSIONS.get_or_init(|| Mutex::new(HashMap::new())).lock().unwrap_or_else(|e| e.into_inner())
}

/// Run a call on its session's thread (from the pipe threads). `_session`
/// and `_client` say which session it's for.
pub fn submit(r: Request) {
    monitor::wait_ready();
    let id = r.args.get("_session").and_then(Value::as_str).unwrap_or("cli").to_string();
    let client = r.args.get("_client").and_then(Value::as_str).map(String::from);
    let mut queues = queues();
    let tx = queues.entry(id.clone()).or_insert_with(|| spawn(id.clone(), client.as_deref()));
    if let Err(mpsc::SendError(Job::Call(r))) = tx.send(Job::Call(r)) {
        let _ = r.reply.send(ToolResult::error("the session's engine stopped; try again"));
    }
}

fn send(session: Option<&str>, job: impl Fn() -> Job) {
    for (id, tx) in queues().iter() {
        if session.is_none_or(|s| s == id) {
            let _ = tx.send(job());
        }
    }
}

/// The tray's Stop: close the windows of one session, or all.
pub fn stop(session: Option<&str>) {
    send(session, || Job::Stop(None));
}

/// Before the app quits (Quit, or an update): stop every session's call at the
/// next step, close their windows and give borrowed ones back, and wait for
/// that, `limit` at most.
pub fn stop_for_quit(limit: Duration) {
    QUITTING.store(true, std::sync::atomic::Ordering::Relaxed);
    let (tx, rx) = mpsc::channel();
    let mut sent = 0;
    for q in queues().values() {
        if q.send(Job::Stop(Some(tx.clone()))).is_ok() {
            sent += 1;
        }
    }
    let deadline = Instant::now() + limit;
    for _ in 0..sent {
        let left = deadline.saturating_duration_since(Instant::now());
        if rx.recv_timeout(left).is_err() {
            break;
        }
    }
}

/// The tray's Done on a handoff: the window goes back to the agent.
pub fn hand_back(session: &str) {
    send(Some(session), || Job::HandBack);
}

/// The tray's Pause and Resume, for one session or all.
pub fn set_paused(session: Option<&str>, paused: bool) {
    for v in sessions::all() {
        if session.is_none_or(|s| s == v.id) {
            sessions::update(&v.id, |v| v.paused = paused);
        }
    }
}

/// Whether every session the tray shows is paused (and there is one).
pub fn all_paused() -> bool {
    let vs: Vec<_> = sessions::all().into_iter().filter(|v| v.visible()).collect();
    !vs.is_empty() && vs.iter().all(|v| v.paused)
}

/// What a running call is doing, for the tray.
fn describe(tool: &str) -> &'static str {
    match tool {
        "open_window" | "borrow_window" => "Opening a window",
        "get_window_state" | "screenshot" => "Looking",
        "click" | "perform_action" => "Clicking",
        "type_text" | "set_value" => "Typing",
        "press_key" => "Pressing keys",
        "scroll" => "Scrolling",
        _ => "Working",
    }
}

fn spawn(id: String, client: Option<&str>) -> mpsc::Sender<Job> {
    sessions::add(&id, sessions::label_for(client));
    let (tx, rx) = mpsc::channel::<Job>();
    std::thread::Builder::new()
        .name(format!("session {}", id.chars().take(8).collect::<String>()))
        .spawn(move || run_session(id, rx))
        .expect("session thread");
    tx
}

fn run_session(id: String, rx: mpsc::Receiver<Job>) {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
    }
    let auto: IUIAutomation = match unsafe { CoCreateInstance(&CUIAutomation8, None, CLSCTX_INPROC_SERVER) } {
        Ok(a) => a,
        Err(e) => {
            for job in rx {
                if let Job::Call(r) = job {
                    let _ = r.reply.send(ToolResult::error(format!("UI Automation is unavailable: {e}")));
                }
            }
            return;
        }
    };
    let mut engine = Engine { id: id.clone(), auto, windows: HashMap::new(), snapshots: HashMap::new(), last_action: HashMap::new() };
    let mut last_call = Instant::now();
    let mut last_check = Instant::now();
    loop {
        match rx.recv_timeout(Duration::from_millis(500)) {
            Ok(Job::Call(r)) => {
                let busy = describe(&r.tool);
                sessions::update(&id, |v| {
                    v.busy = Some(busy);
                    v.last_call = Some(Instant::now());
                });
                let result = engine.call(&r.tool, &r.args);
                let _ = r.reply.send(result);
                last_call = Instant::now();
                engine.publish(|v| {
                    v.busy = None;
                    v.last_call = Some(Instant::now());
                });
            }
            Ok(Job::Stop(done)) => {
                engine.stop_all();
                engine.publish(|_| {});
                if let Some(done) = done {
                    let _ = done.send(());
                }
            }
            Ok(Job::HandBack) => {
                engine.hand_back();
                engine.publish(|v| v.paused = false);
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
        // Every turn (at most 500 ms apart), so a window Windows moved onto
        // the user's screen doesn't stay there.
        engine.keep_on_screen();
        if last_check.elapsed() > Duration::from_secs(2) {
            last_check = Instant::now();
            // Windows the user or the app closed.
            let before = engine.windows.len();
            engine.windows.retain(|_, w| {
                let alive = win::exists(w.hwnd);
                if !alive {
                    guard::remove_agent_window(w.hwnd);
                }
                alive
            });
            if engine.windows.len() != before {
                engine.publish(|_| {});
            }
            // A session that's done gives its monitor to the next one.
            if engine.windows.is_empty() && last_call.elapsed() > Duration::from_secs(60) {
                monitor::release(&id);
            }
        }
    }
}

struct Args<'a>(&'a Map<String, Value>);

impl Args<'_> {
    fn int(&self, k: &str) -> Option<i64> {
        self.0.get(k).and_then(|v| v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)))
    }
    fn num(&self, k: &str) -> Option<f64> {
        self.0.get(k).and_then(Value::as_f64)
    }
    fn str(&self, k: &str) -> Option<&str> {
        self.0.get(k).and_then(Value::as_str)
    }
    fn bool(&self, k: &str) -> Option<bool> {
        self.0.get(k).and_then(Value::as_bool)
    }
    fn need_int(&self, k: &str) -> Fallible<i64> {
        self.int(k).ok_or_else(|| format!("missing `{k}`"))
    }
    fn need_str(&self, k: &str) -> Fallible<&str> {
        self.str(k).ok_or_else(|| format!("missing `{k}`"))
    }
}

const BATCHABLE: [&str; 9] = ["click", "set_value", "perform_action", "type_text", "press_key", "scroll", "drag", "press_menu_item", "wait"];

impl Engine {
    fn paused(&self) -> bool {
        sessions::get(&self.id).is_some_and(|v| v.paused)
    }

    /// Tell the tray what this session has now.
    fn publish(&self, also: impl FnOnce(&mut sessions::View)) {
        let mut ws: Vec<&AgentWindow> = self.windows.values().collect();
        ws.sort_by_key(|w| w.opened);
        let apps = ws.iter().map(|w| sessions::AppTag { name: w.app.clone(), exe: win::exe_path(w.pid).unwrap_or_default() }).collect();
        let handoff = ws.iter().find_map(|w| w.handoff.clone().map(|r| (w.app.clone(), r)));
        let count = ws.len();
        sessions::update(&self.id, |v| {
            v.apps = apps;
            v.windows = count;
            v.handoff = handoff;
            also(v);
        });
    }

    /// Where the agent points now, for the preview's cursor and for placing
    /// the menus it opens on a hidden screen.
    fn point_at(&self, p: POINT) {
        sessions::update(&self.id, |v| v.pointer = Some((p, Instant::now())));
        guard::note_point(p);
    }

    /// The screens can change under the windows: Remote Desktop connecting
    /// takes the agent monitors away, and Windows moves their windows onto
    /// the user's screen. Put any window that ended up there back on the
    /// session's screen. (Measured: back within 45 ms of reconnecting.)
    fn keep_on_screen(&self) {
        if self.windows.is_empty() {
            return;
        }
        let Some(m) = monitor::of_session(&self.id) else { return };
        for (n, w) in self.windows.values().enumerate() {
            if w.handed_off() || w.kind == Kind::Adopted || win::is_minimized(w.hwnd) || !monitor::on_user_screen(&win::frame(w.hwnd)) {
                continue;
            }
            apps::place(w.hwnd, m.rect, n);
        }
    }

    /// On a hidden screen a Chromium browser has to run with its occlusion
    /// check off, or its windows come out blank. The switch to start the
    /// browser with, if it isn't running yet. A browser already running
    /// without it is restarted with it when the agent says the user agreed
    /// (`restart`); `notes` says how that went.
    fn browser_switch(&self, exe: &str, name: &str, restart: bool, notes: &mut Vec<String>) -> Fallible<Option<&'static str>> {
        if !monitor::hidden_mode() || !browser::is_chromium(exe) {
            return Ok(None);
        }
        match browser::state(exe) {
            browser::State::Ready => Ok(None),
            browser::State::NotRunning => Ok(Some(browser::SWITCH)),
            browser::State::NeedsRestart if restart => {
                let r = browser::restart(exe, name)?;
                notes.push(format!("{name} restarted with {} of its {} windows back", r.windows_after, r.windows_before));
                Ok(None)
            }
            browser::State::NeedsRestart => {
                let instead = match win::default_browser() {
                    Some((default, default_exe)) if !default_exe.eq_ignore_ascii_case(exe) => format!(
                        "But {name} isn't the user's default browser, {default}, and isn't signed in to their accounts: unless the user asked for {name}, use {default}."
                    ),
                    _ => format!("Don't use a different browser instead: only {name} is signed in to the user's accounts."),
                };
                Err(format!(
                    "{name} has to restart once before you can use it here. This is a Remote Desktop session, so your windows are off-screen, and {name} was started without the setting that keeps off-screen windows drawing: yours would come out blank. BCU can restart it with that setting; its windows and tabs come back, and open pages reload. \
                     Ask the user first, for example: \"Can I restart {name}? Your windows and tabs will come back.\" If they agree, call open_window with app=\"{name}\" and restart_browser=true. {instead}"
                ))
            }
        }
    }

    /// Stop from the tray: close the windows agents opened, return borrowed ones.
    pub fn stop_all(&mut self) {
        // Ask every opened window to close first, so they close together.
        for w in self.windows.values().filter(|w| w.kind == Kind::Opened) {
            unsafe {
                let _ = PostMessageW(Some(w.hwnd), WM_CLOSE, WPARAM(0), LPARAM(0));
            }
        }
        let ids: Vec<u64> = self.windows.keys().copied().collect();
        for id in ids {
            let mut args = Map::new();
            args.insert("window_id".into(), json!(id));
            let _ = self.release_window(&Args(&args));
        }
        if self.windows.is_empty() {
            monitor::release(&self.id);
        }
    }

    /// The user is done with what the agent handed them: back to the agent's monitor.
    fn hand_back(&mut self) {
        let ids: Vec<u64> = self.windows.iter().filter(|(_, w)| w.handed_off()).map(|(id, _)| *id).collect();
        for id in ids {
            let mut args = Map::new();
            args.insert("window_id".into(), json!(id));
            let _ = self.take_back(&Args(&args));
        }
    }

    pub fn call(&mut self, tool: &str, args: &Map<String, Value>) -> ToolResult {
        let args = Args(args);
        let acting = BATCHABLE.contains(&tool) || tool == "open_window" || tool == "borrow_window";
        if acting && self.paused() {
            return ToolResult::error("Paused by the user.");
        }
        // Activations of the app the agent acts on are the agent's doing: the
        // guard gives the foreground straight back to the user.
        let window = args.int("window_id").and_then(|id| self.windows.get(&(id as u64)));
        let pid = window.map(|w| w.pid);
        if acting && let Some(w) = window {
            guard::begin_action(w.pid);
            guard::note_target(w.hwnd);
        }
        let mut result = self.dispatch(tool, &args).unwrap_or_else(ToolResult::error);
        if acting && let Some(pid) = pid {
            if let Some(note) = guard::end_action(pid) {
                result.text += &format!("\nFocus guard: {note}.");
            }
        }
        if acting && let Some(id) = args.int("window_id") {
            self.last_action.insert(id as u64, Instant::now());
        }
        result
    }

    fn dispatch(&mut self, tool: &str, args: &Args) -> Fallible<ToolResult> {
        match tool {
            "status" => Ok(self.status(args)),
            "list_apps" => Ok(self.list_apps()),
            "list_windows" => self.list_windows(args),
            "get_window_state" => self.get_window_state(args),
            "screenshot" => self.screenshot(args),
            "click" => self.click(args),
            "set_value" => self.set_value(args),
            "perform_action" => self.perform_action(args),
            "release_window" => self.release_window(args),
            "guard_report" => Ok(ToolResult::ok(guard::report())),
            "batch" => self.batch(args),
            "admin_adopt" => self.adopt(args),
            "type_text" => self.type_text(args),
            "press_key" => self.press_key(args),
            "scroll" => self.scroll(args),
            "drag" => self.drag(args),
            "open_window" => self.open_window(args),
            "borrow_window" => self.borrow_window(args),
            "handoff" => self.handoff(args),
            "take_back" => self.take_back(args),
            "press_menu_item" => Err("press_menu_item isn't built on Windows yet. Open the menu with click and pick the item from get_window_state.".into()),
            _ => Err(format!("unknown tool {tool}")),
        }
    }

    // ---------- lookups ----------

    fn window(&mut self, args: &Args) -> Fallible<u64> {
        let id = args.need_int("window_id")? as u64;
        let Some(w) = self.windows.get(&id) else {
            return Err(format!("window {id} isn't one of yours. Use open_window or borrow_window first, or list_windows."));
        };
        if !win::exists(w.hwnd) {
            guard::remove_agent_window(w.hwnd);
            self.windows.remove(&id);
            self.snapshots.remove(&id);
            return Err(format!("window {id} no longer exists"));
        }
        if w.handed_off() {
            return Err(format!("window {id} is handed off to the user. Wait for them, then call take_back."));
        }
        Ok(id)
    }

    fn agent_monitor(&mut self) -> Fallible<RECT> {
        Ok(monitor::for_session(&self.id)?.rect)
    }

    fn open_window(&mut self, args: &Args) -> Fallible<ToolResult> {
        let name = args.need_str("app")?;
        let app = apps::resolve(name)?;
        let mon = self.agent_monitor()?;
        let mut restart_notes = Vec::new();
        let restart = args.bool("restart_browser").unwrap_or(false);
        let switch = match &app.path {
            Some(path) => self.browser_switch(path, &app.name, restart, &mut restart_notes)?,
            None => None,
        };
        let index = self.windows.len();
        let (hwnd, mut notes) = {
            let _one_at_a_time = OPENING.lock().unwrap_or_else(|e| e.into_inner());
            apps::open(&app, mon, index, switch)?
        };
        notes.splice(0..0, restart_notes);
        // Agents reach for whatever browser comes to mind; only the default
        // one has the user's logins.
        if let Some((default_name, default_exe)) = win::default_browser()
            && let Some(path) = &app.path
            && browser::is_browser(path)
            && !path.eq_ignore_ascii_case(&default_exe)
        {
            notes.push(format!(
                "{} isn't the user's default browser, {default_name}, and isn't signed in to their accounts. Unless the user asked for {}, release this window and open {default_name} instead",
                app.name, app.name
            ));
        }
        let pid = win::pid_tid(hwnd).0;
        let id = win::id(hwnd);
        self.windows.insert(id, AgentWindow { hwnd, pid, app: app.name.clone(), kind: Kind::Opened, opened: Instant::now(), home: None, handoff: None });
        let f = win::frame(hwnd);
        Ok(ToolResult::ok(format!(
            "Opened window {id} of {} on your monitor ({}x{}). Next: get_window_state window_id={id}.\nNotes: {}",
            app.name,
            f.right - f.left,
            f.bottom - f.top,
            notes.join("; ")
        )))
    }

    fn borrow_window(&mut self, args: &Args) -> Fallible<ToolResult> {
        let id = args.need_int("window_id")? as u64;
        let hwnd = win::from_id(id);
        if self.windows.contains_key(&id) {
            return Err(format!("window {id} is already yours"));
        }
        if guard::is_agent_window(hwnd) {
            return Err(format!("window {id} belongs to another agent"));
        }
        if !win::exists(hwnd) || !win::is_app_window(hwnd) {
            return Err(format!("{id} isn't one of the user's windows. Use list_windows with app=... to find one."));
        }
        if win::foreground() == hwnd {
            return Err(format!("the user is using window {id} right now. Pick another, or wait."));
        }
        let mon = self.agent_monitor()?;
        // Its browser is running, so this only checks that it keeps drawing.
        if let Some(exe) = win::exe_path(win::pid_tid(hwnd).0) {
            self.browser_switch(&exe, &win::app_name(win::pid_tid(hwnd).0), false, &mut Vec::new())?;
        }
        let mut home = RECT::default();
        unsafe {
            let _ = windows::Win32::UI::WindowsAndMessaging::GetWindowRect(hwnd, &mut home);
        }
        let pid = win::pid_tid(hwnd).0;
        guard::add_agent_window(hwnd, mon, self.windows.len());
        apps::place(hwnd, mon, self.windows.len());
        apps::hide_from_taskbar(hwnd);
        self.windows.insert(id, AgentWindow { hwnd, pid, app: win::app_name(pid), kind: Kind::Borrowed, opened: Instant::now(), home: Some(home), handoff: None });
        Ok(ToolResult::ok(format!("Borrowed window {id} of {} onto your monitor. release_window puts it back where it was.", win::app_name(pid))))
    }

    /// Move a window onto the user's screen, without activating it, for them to take over.
    fn handoff(&mut self, args: &Args) -> Fallible<ToolResult> {
        let id = self.window(args)?;
        let reason = args.need_str("reason")?.to_string();
        let w = self.windows.get_mut(&id).unwrap();
        let work = primary_work_area();
        let f = win::frame(w.hwnd);
        let (fw, fh) = ((f.right - f.left).min(work.right - work.left), (f.bottom - f.top).min(work.bottom - work.top));
        let x = work.left + (work.right - work.left - fw) / 2;
        let y = work.top + (work.bottom - work.top - fh) / 2;
        guard::remove_agent_window(w.hwnd);
        unsafe {
            let _ = SetWindowPos(w.hwnd, None, x, y, fw, fh, SWP_NOZORDER | SWP_NOACTIVATE);
        }
        apps::show_in_taskbar(w.hwnd);
        w.handoff = Some(reason.clone());
        Ok(ToolResult::ok(format!("Handed window {id} to the user: \"{reason}\". It's on their screen now. Stop here; call take_back when they say they're done.")))
    }

    fn take_back(&mut self, args: &Args) -> Fallible<ToolResult> {
        let id = args.need_int("window_id")? as u64;
        let mon = self.agent_monitor()?;
        let index = self.windows.len();
        let w = self.windows.get_mut(&id).ok_or_else(|| format!("window {id} isn't one of yours"))?;
        if !w.handed_off() {
            return Err(format!("window {id} isn't handed off"));
        }
        if win::foreground() == w.hwnd {
            return Err(format!("the user is still using window {id}. Ask them to finish or switch away first."));
        }
        w.handoff = None;
        guard::add_agent_window(w.hwnd, mon, index);
        apps::place(w.hwnd, mon, index);
        apps::hide_from_taskbar(w.hwnd);
        Ok(ToolResult::ok(format!("Window {id} is back on your monitor.")))
    }

    fn node(&self, id: u64, args: &Args) -> Fallible<Node> {
        let index = args.need_int("element")? as usize;
        let snap = self.snapshots.get(&id).ok_or_else(|| format!("no element numbers for window {id} yet: call get_window_state first"))?;
        snap.nodes.get(&index).cloned().ok_or_else(|| format!("element {index} isn't in the last get_window_state for window {id}"))
    }

    // ---------- tools ----------

    fn status(&self, _args: &Args) -> ToolResult {
        let mut lines = Vec::new();
        match monitor::of_session(&self.id).or_else(monitor::first) {
            Some(m) if monitor::hidden_mode() => lines.push(format!(
                "Your monitor: {}x{} pixels ({}). This is a Remote Desktop session, so your windows are kept off-screen instead of on an agent monitor; they work the same.",
                m.rect.right - m.rect.left,
                m.rect.bottom - m.rect.top,
                monitor::name(&m)
            )),
            Some(m) => {
                lines.push(format!("Your monitor: {}x{} pixels ({}).", m.rect.right - m.rect.left, m.rect.bottom - m.rect.top, monitor::name(&m)))
            }
            None => lines.push("Your monitor: MISSING. The Virtual Display Driver isn't installed or is off; open_window will fail until the user runs setup.".into()),
        }
        if let Some((name, exe)) = win::default_browser() {
            lines.push(format!(
                "User's default browser: {name} ({exe}). Use it for anything on the web: it's signed in to the user's accounts, and other browsers here aren't."
            ));
            if monitor::hidden_mode() && browser::is_chromium(&exe) && matches!(browser::state(&exe), browser::State::NeedsRestart) {
                lines.push(format!(
                    "{name} has to restart once before you can open windows in it here. When the task needs it, ask the user (\"Can I restart {name}? Your windows and tabs will come back.\"), then call open_window with app=\"{name}\" and restart_browser=true."
                ));
            }
        }
        if self.paused() {
            lines.push("Paused by the user.".into());
        }
        let mine: Vec<_> = self.windows.iter().collect();
        if mine.is_empty() {
            lines.push("You have no windows open.".into());
        } else {
            lines.push("Your windows:".into());
            for (id, w) in mine {
                lines.push(format!("  {id}: {} [{}{}] \"{}\"", w.app, w.kind.label(), if w.handed_off() { ", handed off" } else { "" }, win::title(w.hwnd)));
            }
        }
        ToolResult::ok(lines.join("\n"))
    }

    fn list_apps(&self) -> ToolResult {
        let fg_pid = win::pid_tid(win::foreground()).0;
        let mut apps: Vec<(u32, String, usize)> = Vec::new();
        for hwnd in win::top_level_windows().into_iter().filter(|h| win::is_app_window(*h)) {
            let pid = win::pid_tid(hwnd).0;
            match apps.iter_mut().find(|a| a.0 == pid) {
                Some(a) => a.2 += 1,
                None => apps.push((pid, win::exe_name(pid), 1)),
            }
        }
        let lines: Vec<String> = apps
            .iter()
            .map(|(pid, exe, n)| {
                format!(
                    "{} ({exe}, pid {pid}), {n} window(s){}",
                    win::app_name(*pid),
                    if *pid == fg_pid { " — the user is using this app" } else { "" }
                )
            })
            .collect();
        ToolResult::ok(lines.join("\n"))
    }

    fn list_windows(&self, args: &Args) -> Fallible<ToolResult> {
        let mut lines = vec!["Your windows:".to_string()];
        let mine: Vec<_> = self.windows.iter().collect();
        if mine.is_empty() {
            lines.push("  (none)".into());
        }
        for (id, w) in &mine {
            lines.push(format!("  {id}: {} \"{}\" [{}]", w.app, win::title(w.hwnd), w.kind.label()));
        }
        if let Some(app) = args.str("app") {
            let needle = app.to_lowercase();
            let theirs: Vec<HWND> = win::top_level_windows()
                .into_iter()
                .filter(|h| win::is_app_window(*h) && !guard::is_agent_window(*h) && !self.windows.contains_key(&win::id(*h)))
                .filter(|h| {
                    let pid = win::pid_tid(*h).0;
                    let exe = win::exe_name(pid).to_lowercase();
                    exe == needle || exe.trim_end_matches(".exe") == needle.trim_end_matches(".exe") || win::app_name(pid).to_lowercase() == needle
                })
                .collect();
            lines.push(format!("{app}'s other windows (the user's):"));
            if theirs.is_empty() {
                lines.push("  (none)".into());
            }
            for h in theirs {
                let f = win::frame(h);
                lines.push(format!(
                    "  {}: \"{}\" {}x{}{}",
                    win::id(h),
                    win::title(h),
                    f.right - f.left,
                    f.bottom - f.top,
                    if win::is_minimized(h) { " (minimized)" } else { "" }
                ));
            }
        }
        Ok(ToolResult::ok(lines.join("\n")))
    }

    fn adopt(&mut self, args: &Args) -> Fallible<ToolResult> {
        let id = args.need_int("window_id")? as u64;
        let hwnd = win::from_id(id);
        if !win::exists(hwnd) {
            return Err(format!("{id} is not a window"));
        }
        let pid = win::pid_tid(hwnd).0;
        self.windows.insert(id, AgentWindow { hwnd, pid, app: win::app_name(pid), kind: Kind::Adopted, opened: Instant::now(), home: None, handoff: None });
        Ok(ToolResult::ok(format!("Adopted window {id} of {} for testing. It stays where it is.", win::app_name(pid))))
    }

    fn take_snapshot(&self, id: u64, max: usize, previous: Option<&Snapshot>) -> Fallible<Snapshot> {
        let w = &self.windows[&id];
        let title = win::title(w.hwnd);
        let frame = win::frame(w.hwnd);
        let popups = self.popups(w.pid, w.hwnd, frame);
        let target = snapshot::Target { hwnd: w.hwnd, title: &title, app: &w.app, pid: w.pid, frame, popups: &popups };
        snapshot::take(&self.auto, &target, max, previous).map_err(|e| format!("couldn't read the window's UI Automation tree: {e}"))
    }

    /// The app's other top-level windows over this one that aren't app windows:
    /// menus, suggestion lists, dropdowns.
    fn popups(&self, pid: u32, hwnd: HWND, frame: RECT) -> Vec<IUIAutomationElement> {
        win::top_level_windows()
            .into_iter()
            .filter(|h| *h != hwnd && win::is_visible(*h) && win::pid_tid(*h).0 == pid && !win::is_app_window(*h))
            .filter(|h| {
                let f = win::frame(*h);
                f.right - f.left > 4 && f.bottom - f.top > 4 && f.left < frame.right && frame.left < f.right && f.top < frame.bottom && frame.top < f.bottom
            })
            .filter_map(|h| unsafe { self.auto.ElementFromHandle(h).ok() })
            .collect()
    }

    fn get_window_state(&mut self, args: &Args) -> Fallible<ToolResult> {
        let id = self.window(args)?;
        let max = args.int("max_elements").unwrap_or(250).clamp(1, 2000) as usize;
        let previous = self.snapshots.remove(&id);
        let first_read = previous.is_none();
        let mut snap = self.take_snapshot(id, max, previous.as_ref())?;
        // Chromium and Electron build their full tree only after a UI Automation
        // client has asked once, so a first read of web content comes back thin.
        if first_read && snap.nodes.len() < 12 {
            std::thread::sleep(Duration::from_millis(700));
            snap = self.take_snapshot(id, max, previous.as_ref())?;
        }
        // Right after an action, wait for the window to settle: nothing changing
        // for 400 ms, up to 5 s from the action.
        if let Some(acted) = self.last_action.remove(&id) {
            let deadline = acted + Duration::from_secs(5);
            let earliest = acted + Duration::from_millis(400);
            if Instant::now() < earliest {
                std::thread::sleep(earliest - Instant::now());
                snap = self.take_snapshot(id, max, previous.as_ref())?;
            }
            let mut stable_since = Instant::now();
            while Instant::now() < deadline && stable_since.elapsed() < Duration::from_millis(400) {
                std::thread::sleep(Duration::from_millis(130));
                let again = self.take_snapshot(id, max, previous.as_ref())?;
                if again.text != snap.text {
                    stable_since = Instant::now();
                }
                snap = again;
            }
        }
        let mut images = Vec::new();
        if args.bool("screenshot").unwrap_or(true)
            && let Ok(img) = self.screenshot_image(id)
        {
            images.push(img);
        }
        let full = args.bool("full").unwrap_or(false);
        let text = match (&previous, full) {
            (Some(prev), false) => snapshot::diff(prev, &snap),
            _ => None,
        }
        .unwrap_or_else(|| {
            let mut t = snap.text.clone();
            if snap.renumbered {
                t += "\n(Most elements are new, so numbering restarted; numbers from earlier reads no longer apply.)";
            }
            t
        });
        self.snapshots.insert(id, snap);
        Ok(ToolResult { text, images, is_error: false })
    }

    fn screenshot_image(&self, id: u64) -> Fallible<Image> {
        let w = &self.windows[&id];
        let img = capture::window(w.hwnd, win::frame(w.hwnd))?;
        Ok(Image { mime: "image/png".into(), data: capture::base64(&capture::png(&img)?) })
    }

    fn screenshot(&mut self, args: &Args) -> Fallible<ToolResult> {
        if args.int("window_id").is_none() {
            return Err("screenshots of the whole agent monitor aren't built on Windows yet; pass window_id".into());
        }
        let id = self.window(args)?;
        let f = win::frame(self.windows[&id].hwnd);
        let img = self.screenshot_image(id)?;
        Ok(ToolResult { text: format!("Window {id}, {}x{}", f.right - f.left, f.bottom - f.top), images: vec![img], is_error: false })
    }

    /// A window-relative point from x/y, in screen pixels.
    fn point(&self, id: u64, args: &Args) -> Fallible<POINT> {
        let (Some(x), Some(y)) = (args.num("x"), args.num("y")) else {
            return Err("give an element or x and y".into());
        };
        let f = win::frame(self.windows[&id].hwnd);
        Ok(POINT { x: f.left + x.round() as i32, y: f.top + y.round() as i32 })
    }

    /// An element's center, if it's inside the window or one of its popups,
    /// where a posted click lands.
    fn element_point(&self, id: u64, n: &Node) -> Option<POINT> {
        let r = n.rect;
        let p = POINT { x: (r.left + r.right) / 2, y: (r.top + r.bottom) / 2 };
        (r.right > r.left && r.bottom > r.top && self.target(id, p).is_some()).then_some(p)
    }

    /// The window a posted click at screen point `p` should go to: the topmost
    /// of the agent's window and its app's popups (menus, dropdowns, which are
    /// windows of their own) that has `p` inside. None if `p` misses them all.
    fn target(&self, id: u64, p: POINT) -> Option<HWND> {
        let w = &self.windows[&id];
        let inside = |h: HWND| {
            let f = win::frame(h);
            p.x > f.left && p.x < f.right && p.y > f.top && p.y < f.bottom
        };
        // EnumWindows lists top-level windows from the top of the z-order down.
        win::top_level_windows()
            .into_iter()
            .take_while(|h| *h != w.hwnd)
            .find(|h| win::is_visible(*h) && win::pid_tid(*h).0 == w.pid && !win::is_app_window(*h) && inside(*h))
            .or_else(|| inside(w.hwnd).then_some(w.hwnd))
    }

    fn click(&mut self, args: &Args) -> Fallible<ToolResult> {
        let id = self.window(args)?;
        let hwnd = self.windows[&id].hwnd;
        let button = if args.str("button").is_some_and(|b| b.eq_ignore_ascii_case("right")) { input::Button::Right } else { input::Button::Left };
        let count = args.int("count").unwrap_or(1).clamp(1, 3) as u32;
        if args.int("element").is_some() {
            let n = self.node(id, args)?;
            // A posted click is what a person's click does, and it never moves the
            // foreground. UI Automation's actions can: Chromium activates its
            // window when an element is invoked.
            if let Some(p) = self.element_point(id, &n) {
                self.point_at(p);
                input::click(self.target(id, p).unwrap_or(hwnd), p, button, count)?;
                return Ok(ToolResult::ok(format!("Clicked element {} ({}) at its center.", n.index, snapshot::role_name(n.control_type))));
            }
            if button == input::Button::Left && count == 1
                && let Some(how) = press(&n)?
            {
                return Ok(ToolResult::ok(format!(
                    "Pressed element {} ({}) through UI Automation ({how}); it's outside the visible window, so it couldn't be clicked.",
                    n.index,
                    snapshot::role_name(n.control_type)
                )));
            }
            return Err(format!("element {} is outside the visible window. Scroll it into view first.", n.index));
        }
        let p = self.point(id, args)?;
        self.point_at(p);
        input::click(self.target(id, p).unwrap_or(hwnd), p, button, count)?;
        Ok(ToolResult::ok(format!("Clicked at ({}, {}).", args.num("x").unwrap_or(0.0) as i64, args.num("y").unwrap_or(0.0) as i64)))
    }

    fn type_text(&mut self, args: &Args) -> Fallible<ToolResult> {
        let id = self.window(args)?;
        let hwnd = self.windows[&id].hwnd;
        let text = args.need_str("text")?.replace("\\n", "\n");
        if args.int("element").is_some() {
            // Focus the field the way a person would: click it, then put the
            // caret at the end so the text is added after what's there.
            let n = self.node(id, args)?;
            let p = self.element_point(id, &n).ok_or_else(|| format!("element {} is outside the visible window. Scroll it into view first.", n.index))?;
            self.point_at(p);
            input::click(self.target(id, p).unwrap_or(hwnd), p, input::Button::Left, 1)?;
            input::press_key(hwnd, input::key_for("end")?, &[input::modifier_for("ctrl")?])?;
        }
        input::type_text(hwnd, &text)?;
        Ok(ToolResult::ok(format!("Typed {} characters.", text.chars().count())))
    }

    fn press_key(&mut self, args: &Args) -> Fallible<ToolResult> {
        let id = self.window(args)?;
        let hwnd = self.windows[&id].hwnd;
        let key_name = args.need_str("key")?;
        let key = input::key_for(key_name)?;
        let names: Vec<String> = args
            .0
            .get("modifiers")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(|m| m.as_str().map(String::from)).collect())
            .unwrap_or_default();
        let mods = names.iter().map(|m| input::modifier_for(m)).collect::<Fallible<Vec<_>>>()?;
        input::press_key(hwnd, key, &mods)?;
        let mut combo = names.clone();
        combo.push(key_name.to_string());
        Ok(ToolResult::ok(format!("Pressed {}.", combo.join("+"))))
    }

    fn scroll(&mut self, args: &Args) -> Fallible<ToolResult> {
        let id = self.window(args)?;
        let hwnd = self.windows[&id].hwnd;
        let p = if args.int("element").is_some() {
            let n = self.node(id, args)?;
            self.element_point(id, &n).ok_or_else(|| format!("element {} is outside the visible window", n.index))?
        } else if args.num("x").is_some() {
            self.point(id, args)?
        } else {
            let f = win::frame(hwnd);
            POINT { x: (f.left + f.right) / 2, y: (f.top + f.bottom) / 2 }
        };
        let dx = args.int("dx").unwrap_or(0) as i32;
        let dy = args.int("dy").unwrap_or(0) as i32;
        if dx == 0 && dy == 0 {
            return Err("give dx or dy (lines; positive dy scrolls down)".into());
        }
        self.point_at(p);
        input::scroll(self.target(id, p).unwrap_or(hwnd), p, dx, dy)?;
        Ok(ToolResult::ok(format!("Scrolled dx={dx} dy={dy}.")))
    }

    fn drag(&mut self, args: &Args) -> Fallible<ToolResult> {
        let id = self.window(args)?;
        let hwnd = self.windows[&id].hwnd;
        let f = win::frame(hwnd);
        let get = |k: &str| args.num(k).ok_or_else(|| format!("missing `{k}`"));
        let from = POINT { x: f.left + get("from_x")? as i32, y: f.top + get("from_y")? as i32 };
        let to = POINT { x: f.left + get("to_x")? as i32, y: f.top + get("to_y")? as i32 };
        self.point_at(from);
        input::drag(hwnd, from, to)?;
        self.point_at(to);
        Ok(ToolResult::ok("Dragged."))
    }

    fn set_value(&mut self, args: &Args) -> Fallible<ToolResult> {
        let id = self.window(args)?;
        let n = self.node(id, args)?;
        let value = args.need_str("value")?;
        unsafe {
            let p: IUIAutomationValuePattern = n
                .element
                .GetCurrentPatternAs(UIA_ValuePatternId)
                .map_err(|_| format!("element {} has no value to set. Try type_text with element={}.", n.index, n.index))?;
            p.SetValue(&BSTR::from(value)).map_err(|e| format!("couldn't set element {}'s value: {e}", n.index))?;
            std::thread::sleep(Duration::from_millis(80));
            let now = p.CurrentValue().map(|b| b.to_string()).unwrap_or_default();
            if now == value {
                Ok(ToolResult::ok(format!("Set element {} to \"{value}\" (verified).", n.index)))
            } else {
                Ok(ToolResult::ok(format!(
                    "Set element {}; reading it back gives \"{}\". If the page didn't react, use type_text with element={}.",
                    n.index,
                    now.chars().take(200).collect::<String>(),
                    n.index
                )))
            }
        }
    }

    fn perform_action(&mut self, args: &Args) -> Fallible<ToolResult> {
        let id = self.window(args)?;
        let n = self.node(id, args)?;
        let action = args.need_str("action")?.to_lowercase();
        let e = &n.element;
        let done = unsafe {
            match action.as_str() {
                "invoke" | "press" => e.GetCurrentPatternAs::<IUIAutomationInvokePattern>(UIA_InvokePatternId).and_then(|p| p.Invoke()),
                "toggle" => e.GetCurrentPatternAs::<IUIAutomationTogglePattern>(UIA_TogglePatternId).and_then(|p| p.Toggle()),
                "expand" => e.GetCurrentPatternAs::<IUIAutomationExpandCollapsePattern>(UIA_ExpandCollapsePatternId).and_then(|p| p.Expand()),
                "collapse" => e.GetCurrentPatternAs::<IUIAutomationExpandCollapsePattern>(UIA_ExpandCollapsePatternId).and_then(|p| p.Collapse()),
                "select" => e.GetCurrentPatternAs::<IUIAutomationSelectionItemPattern>(UIA_SelectionItemPatternId).and_then(|p| p.Select()),
                "scrollintoview" | "scroll_into_view" => {
                    e.GetCurrentPatternAs::<IUIAutomationScrollItemPattern>(UIA_ScrollItemPatternId).and_then(|p| p.ScrollIntoView())
                }
                "focus" | "setfocus" => e.SetFocus(),
                _ => {
                    return Err(format!(
                        "unknown action {action}. Actions: invoke, toggle, expand, collapse, select, scrollintoview, focus. This element has: {}",
                        n.patterns.join(", ")
                    ));
                }
            }
        };
        done.map_err(|err| format!("{action} on element {} failed: {err}. Its actions: {}", n.index, n.patterns.join(", ")))?;
        Ok(ToolResult::ok(format!("Performed {action} on element {}.", n.index)))
    }

    fn release_window(&mut self, args: &Args) -> Fallible<ToolResult> {
        let id = args.need_int("window_id")? as u64;
        let w = self.windows.get(&id).ok_or_else(|| format!("window {id} isn't one of yours"))?;
        let keep = args.bool("keep_open").unwrap_or(false);
        if w.kind == Kind::Opened && !keep {
            // The app may ask first (unsaved changes): the window stays the
            // agent's until it's really gone, so the agent can answer.
            let hwnd = w.hwnd;
            unsafe {
                let _ = PostMessageW(Some(hwnd), WM_CLOSE, WPARAM(0), LPARAM(0));
            }
            let t = Instant::now();
            while win::exists(hwnd) && win::is_visible(hwnd) && t.elapsed() < Duration::from_millis(2000) {
                std::thread::sleep(Duration::from_millis(50));
            }
            if win::exists(hwnd) && win::is_visible(hwnd) {
                self.last_action.insert(id, Instant::now());
                return Err(format!(
                    "window {id} didn't close; the app may be asking something, like whether to save. Read it with get_window_state, answer, and call release_window again."
                ));
            }
        }
        let w = self.windows.remove(&id).unwrap();
        self.snapshots.remove(&id);
        guard::remove_agent_window(w.hwnd);
        let text = match w.kind {
            Kind::Opened if !keep => format!("Closed window {id}."),
            Kind::Borrowed => {
                if let Some(r) = w.home {
                    unsafe {
                        let _ = SetWindowPos(w.hwnd, None, r.left, r.top, r.right - r.left, r.bottom - r.top, SWP_NOZORDER | SWP_NOACTIVATE);
                    }
                }
                apps::show_in_taskbar(w.hwnd);
                format!("Returned window {id} to the user.")
            }
            _ => format!("Released window {id}."),
        };
        Ok(ToolResult::ok(text))
    }

    fn batch(&mut self, args: &Args) -> Fallible<ToolResult> {
        let steps = args.0.get("actions").and_then(Value::as_array).filter(|a| !a.is_empty()).ok_or(
            "`actions` must be a non-empty array of objects like {\"tool\": \"click\", \"element\": 4}",
        )?;
        if steps.len() > 40 {
            return Err("at most 40 actions per batch".into());
        }
        let default_window = args.int("window_id");
        for (i, step) in steps.iter().enumerate() {
            let tool = step["tool"].as_str().ok_or_else(|| format!("action {} has no `tool`", i + 1))?;
            if !BATCHABLE.contains(&tool) {
                return Err(format!("action {}: `{tool}` can't be batched. Allowed: {}.", i + 1, BATCHABLE.join(", ")));
            }
            if tool != "wait" && step.get("window_id").is_none() && default_window.is_none() {
                return Err(format!("action {} needs a window_id (or set window_id on the batch)", i + 1));
            }
        }
        let mut lines = Vec::new();
        let mut last_window = default_window;
        let mut failed = false;
        for (i, step) in steps.iter().enumerate() {
            let mut step_args = step.as_object().cloned().unwrap_or_default();
            let tool = step_args.remove("tool").and_then(|t| t.as_str().map(String::from)).unwrap_or_default();
            if !step_args.contains_key("window_id")
                && let Some(d) = default_window
            {
                step_args.insert("window_id".into(), json!(d));
            }
            if let Some(s) = args.str("_session") {
                step_args.insert("_session".into(), json!(s));
            }
            if let Some(w) = Args(&step_args).int("window_id") {
                last_window = Some(w);
            }
            if quitting() {
                lines.push(format!("Stopped before action {}: the app is quitting.", i + 1));
                failed = true;
                break;
            }
            if tool == "wait" {
                let ms = Args(&step_args).num("ms").unwrap_or(500.0).clamp(0.0, 5000.0);
                let until = Instant::now() + Duration::from_millis(ms as u64);
                while Instant::now() < until && !quitting() {
                    std::thread::sleep(Duration::from_millis(50).min(until - Instant::now()));
                }
                lines.push(format!("{}. wait: {} ms", i + 1, ms as u64));
                continue;
            }
            let r = self.call(&tool, &step_args);
            if r.is_error {
                lines.push(format!("{}. {tool} FAILED: {}", i + 1, r.text));
                if i + 1 < steps.len() {
                    lines.push(format!("Stopped; the remaining {} action(s) didn't run.", steps.len() - i - 1));
                }
                failed = true;
                break;
            }
            lines.push(format!("{}. {tool}: {}", i + 1, r.text.lines().next().unwrap_or("done")));
        }
        let mut images = Vec::new();
        if args.bool("state").unwrap_or(true)
            && let Some(w) = last_window
            && self.windows.contains_key(&(w as u64))
        {
            let mut state_args = Map::new();
            state_args.insert("window_id".into(), json!(w));
            state_args.insert("screenshot".into(), json!(args.bool("screenshot").unwrap_or(false)));
            if let Some(f) = args.bool("full") {
                state_args.insert("full".into(), json!(f));
            }
            if let Some(m) = args.int("max_elements") {
                state_args.insert("max_elements".into(), json!(m));
            }
            if let Ok(state) = self.get_window_state(&Args(&state_args)) {
                lines.push(String::new());
                lines.push(state.text);
                images = state.images;
            }
        }
        Ok(ToolResult { text: lines.join("\n"), images, is_error: failed })
    }
}

/// Press an element with the UI Automation pattern a left click would trigger.
fn press(n: &Node) -> Fallible<Option<&'static str>> {
    let e = &n.element;
    unsafe {
        if n.patterns.contains(&"invoke") {
            let p: IUIAutomationInvokePattern = e.GetCurrentPatternAs(UIA_InvokePatternId).map_err(|e| e.to_string())?;
            p.Invoke().map_err(|e| format!("Invoke failed: {e}"))?;
            return Ok(Some("invoke"));
        }
        if n.patterns.contains(&"toggle") {
            let p: IUIAutomationTogglePattern = e.GetCurrentPatternAs(UIA_TogglePatternId).map_err(|e| e.to_string())?;
            p.Toggle().map_err(|e| format!("Toggle failed: {e}"))?;
            return Ok(Some("toggle"));
        }
        if n.patterns.contains(&"select") {
            let p: IUIAutomationSelectionItemPattern = e.GetCurrentPatternAs(UIA_SelectionItemPatternId).map_err(|e| e.to_string())?;
            p.Select().map_err(|e| format!("Select failed: {e}"))?;
            return Ok(Some("select"));
        }
        if n.patterns.contains(&"expand") {
            let p: IUIAutomationExpandCollapsePattern = e.GetCurrentPatternAs(UIA_ExpandCollapsePatternId).map_err(|e| e.to_string())?;
            let state = p.CurrentExpandCollapseState().unwrap_or(ExpandCollapseState_Collapsed);
            if state == ExpandCollapseState_Expanded {
                p.Collapse().map_err(|e| format!("Collapse failed: {e}"))?;
                return Ok(Some("collapse"));
            }
            p.Expand().map_err(|e| format!("Expand failed: {e}"))?;
            return Ok(Some("expand"));
        }
    }
    Ok(None)
}

/// The primary monitor's work area (without the taskbar).
fn primary_work_area() -> RECT {
    use windows::Win32::UI::WindowsAndMessaging::{SPI_GETWORKAREA, SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS, SystemParametersInfoW};
    let mut r = RECT::default();
    unsafe {
        let _ = SystemParametersInfoW(SPI_GETWORKAREA, 0, Some(&mut r as *mut _ as *mut _), SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0));
    }
    r
}
