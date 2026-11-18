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
use windows::Win32::UI::WindowsAndMessaging::{PostMessageW, WINDOWPLACEMENT, WM_CLOSE};
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
    /// Its place on the agent screen (see `take_slot`).
    slot: usize,
    /// Where a borrowed window was, and whether maximized or minimized, to put it back.
    home: Option<WINDOWPLACEMENT>,
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
    /// The user is signing out or shutting down: give every window to the
    /// user as it is (no closing, which could ask about saving), then say so.
    Surrender(mpsc::Sender<()>),
    /// The agent disconnected: close its windows and end the session.
    End,
}

/// Places on the agent screen in use, by every session's windows (true =
/// taken). Each window gets its own: all agents share the screen, and a
/// window exactly under another stops drawing.
static SLOTS: Mutex<Vec<bool>> = Mutex::new(Vec::new());

fn lowest_free(used: &[bool]) -> usize {
    used.iter().position(|u| !u).unwrap_or(used.len())
}

fn take_slot() -> usize {
    let mut used = SLOTS.lock().unwrap_or_else(|e| e.into_inner());
    let i = lowest_free(&used);
    if i == used.len() {
        used.push(true);
    } else {
        used[i] = true;
    }
    i
}

fn free_slot(i: usize) {
    if let Some(u) = SLOTS.lock().unwrap_or_else(|e| e.into_inner()).get_mut(i) {
        *u = false;
    }
}

/// `bcu mcp` connections open per session: (session, connections, a count
/// of connects). A session whose last one closes ends after `GRACE`, unless
/// it connects again meanwhile.
static LIVE: Mutex<Vec<(String, usize, u64)>> = Mutex::new(Vec::new());
const GRACE: Duration = Duration::from_secs(10);

/// A `bcu mcp` connection started carrying calls for `session` (from the pipe threads).
pub fn connected(session: &str) {
    let mut live = LIVE.lock().unwrap_or_else(|e| e.into_inner());
    match live.iter_mut().find(|(s, _, _)| s == session) {
        Some(entry) => {
            entry.1 += 1;
            entry.2 += 1;
        }
        None => live.push((session.to_string(), 1, 1)),
    }
}

/// That connection closed: the agent quit, or its MCP client restarted it.
pub fn disconnected(session: &str) {
    let generation = {
        let mut live = LIVE.lock().unwrap_or_else(|e| e.into_inner());
        let Some(entry) = live.iter_mut().find(|(s, _, _)| s == session) else { return };
        entry.1 = entry.1.saturating_sub(1);
        if entry.1 > 0 {
            return;
        }
        entry.2
    };
    let session = session.to_string();
    std::thread::spawn(move || {
        std::thread::sleep(GRACE);
        let mut live = LIVE.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(i) = live.iter().position(|(s, n, g)| *s == session && *n == 0 && *g == generation) {
            live.remove(i);
            drop(live);
            // A new call for it starts a new session.
            if let Some(tx) = queues().remove(&session) {
                let _ = tx.send(Job::End);
            }
        }
    });
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
    let mut job = Job::Call(r);
    // A session thread that died (a panic outside a call) is started again.
    for _ in 0..2 {
        let tx = queues.entry(id.clone()).or_insert_with(|| spawn(id.clone(), client.as_deref()));
        match tx.send(job) {
            Ok(()) => return,
            Err(mpsc::SendError(back)) => {
                queues.remove(&id);
                job = back;
            }
        }
    }
    if let Job::Call(r) = job {
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
/// that, `limit` at most. The sessions do this side by side.
pub fn stop_for_quit(limit: Duration) {
    QUITTING.store(true, std::sync::atomic::Ordering::Relaxed);
    on_every_session(limit, |tx| Job::Stop(Some(tx)));
}

/// The user is signing out or shutting down (WM_QUERYENDSESSION): give every
/// agent window to the user now, before apps save where their windows were,
/// so none reopens on the agent screen. `limit` at most.
pub fn surrender_for_end_of_session(limit: Duration) {
    QUITTING.store(true, std::sync::atomic::Ordering::Relaxed);
    on_every_session(limit, Job::Surrender);
    // Shutting down can still be cancelled.
    QUITTING.store(false, std::sync::atomic::Ordering::Relaxed);
}

fn on_every_session(limit: Duration, job: impl Fn(mpsc::Sender<()>) -> Job) {
    let (tx, rx) = mpsc::channel();
    let mut sent = 0;
    for q in queues().values() {
        if q.send(job(tx.clone())).is_ok() {
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
    sessions::remove(&id);
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
                // A bug in one call fails that call, not the session.
                let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| engine.call(&r.tool, &r.args))).unwrap_or_else(|e| {
                    let what = e.downcast_ref::<&str>().map(|s| s.to_string()).or_else(|| e.downcast_ref::<String>().cloned()).unwrap_or_default();
                    ToolResult::error(format!("{} failed inside the app: {what}. Try again; if it keeps failing, try another way.", r.tool))
                });
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
            Ok(Job::Surrender(done)) => {
                let ids: Vec<u64> = engine.windows.keys().copied().collect();
                for w in ids {
                    engine.give_up(w);
                }
                engine.publish(|_| {});
                let _ = done.send(());
            }
            Ok(Job::End) => {
                engine.stop_all();
                sessions::remove(&id);
                return;
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
                    free_slot(w.slot);
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

    /// Where the agent points now, for the preview's cursor.
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
        for w in self.windows.values() {
            if w.handed_off() || w.kind == Kind::Adopted || win::is_minimized(w.hwnd) || !monitor::on_user_screen(&win::frame(w.hwnd)) {
                continue;
            }
            apps::place(w.hwnd, m.rect, w.slot);
        }
    }

    /// Stop (the tray's, a quit's, or the agent disconnecting): close the
    /// windows agents opened, return borrowed ones. All at once, a few
    /// seconds at most: a window that won't close (an app asking whether to
    /// save) goes to the user's screen instead, for them to answer.
    pub fn stop_all(&mut self) {
        let closing: Vec<HWND> = self.windows.values().filter(|w| w.kind == Kind::Opened).map(|w| w.hwnd).collect();
        for hwnd in &closing {
            unsafe {
                let _ = PostMessageW(Some(*hwnd), WM_CLOSE, WPARAM(0), LPARAM(0));
            }
        }
        let t = Instant::now();
        while closing.iter().any(|h| win::exists(*h) && win::is_visible(*h)) && t.elapsed() < Duration::from_secs(3) {
            std::thread::sleep(Duration::from_millis(50));
        }
        let ids: Vec<u64> = self.windows.keys().copied().collect();
        for id in ids {
            self.give_up(id);
        }
        monitor::release(&self.id);
    }

    /// The window is no longer the agent's. One that's still showing goes
    /// back to the user: a borrowed one where it was, any other to the
    /// middle of their screen, with its taskbar button.
    fn give_up(&mut self, id: u64) -> Option<AgentWindow> {
        let w = self.windows.remove(&id)?;
        self.snapshots.remove(&id);
        self.last_action.remove(&id);
        guard::remove_agent_window(w.hwnd);
        free_slot(w.slot);
        if w.kind != Kind::Adopted && win::exists(w.hwnd) && win::is_visible(w.hwnd) {
            match &w.home {
                Some(home) => apps::put_back(w.hwnd, home),
                None if w.handed_off() => apps::show_in_taskbar(w.hwnd),
                None => apps::to_user_screen(w.hwnd),
            }
        }
        Some(w)
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
            "navigate" => Err("navigate isn't built on Windows yet. Click the address bar, type_text the URL and \"\\n\".".into()),
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
            self.give_up(id);
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
        let slot = take_slot();
        let opened = {
            let _one_at_a_time = OPENING.lock().unwrap_or_else(|e| e.into_inner());
            apps::open(&app, mon, slot)
        };
        let (hwnd, mut notes) = opened.inspect_err(|_| free_slot(slot))?;
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
        self.windows.insert(id, AgentWindow { hwnd, pid, app: app.name.clone(), kind: Kind::Opened, opened: Instant::now(), slot, home: None, handoff: None });
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
        let pid = win::pid_tid(hwnd).0;
        // Windows drops this app's moves and input to an app running as
        // administrator (UIPI): the window would stay on the user's screen.
        if win::above_us(pid) {
            return Err(format!(
                "{} runs as administrator, so Windows doesn't let this app move window {id} or send it input. Ask the user to do this part, or to restart the app without admin rights.",
                win::app_name(pid)
            ));
        }
        let mon = self.agent_monitor()?;
        let home = apps::placement(hwnd);
        let slot = take_slot();
        guard::add_agent_window(hwnd, mon, slot);
        crate::offscreen::set_home(hwnd, &home);
        apps::place(hwnd, mon, slot);
        apps::hide_from_taskbar(hwnd);
        let w = AgentWindow { hwnd, pid, app: win::app_name(pid), kind: Kind::Borrowed, opened: Instant::now(), slot, home: Some(home), handoff: None };
        if !apps::on_monitor(hwnd, &mon) || win::is_minimized(hwnd) {
            self.windows.insert(id, w);
            self.give_up(id);
            return Err(format!("window {id} of {} didn't move onto your monitor, so it was left with the user.", win::app_name(pid)));
        }
        self.windows.insert(id, w);
        Ok(ToolResult::ok(format!("Borrowed window {id} of {} onto your monitor. release_window puts it back where it was.", win::app_name(pid))))
    }

    /// Move a window onto the user's screen, without activating it, for them to take over.
    fn handoff(&mut self, args: &Args) -> Fallible<ToolResult> {
        let id = self.window(args)?;
        let reason = args.need_str("reason")?.to_string();
        let w = self.windows.get_mut(&id).unwrap();
        guard::remove_agent_window(w.hwnd);
        apps::to_user_screen(w.hwnd);
        w.handoff = Some(reason.clone());
        Ok(ToolResult::ok(format!("Handed window {id} to the user: \"{reason}\". It's on their screen now. Stop here; call take_back when they say they're done.")))
    }

    fn take_back(&mut self, args: &Args) -> Fallible<ToolResult> {
        let id = args.need_int("window_id")? as u64;
        let mon = self.agent_monitor()?;
        let w = self.windows.get_mut(&id).ok_or_else(|| format!("window {id} isn't one of yours"))?;
        let index = w.slot;
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
            Some(m) => lines.push(format!(
                "Your monitor: {}x{} pixels ({}), a screen the user never sees.",
                m.rect.right - m.rect.left,
                m.rect.bottom - m.rect.top,
                monitor::name(&m)
            )),
            None => lines.push(format!(
                "You have no screen to work on, so you can't open windows: {}",
                crate::setup::screen_problem().unwrap_or_else(|| "the agent screen isn't on.".into())
            )),
        }
        if let Some((name, exe)) = win::default_browser() {
            lines.push(format!(
                "User's default browser: {name} ({exe}). Use it for anything on the web: it's signed in to the user's accounts, and other browsers here aren't."
            ));
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
        self.windows.insert(id, AgentWindow { hwnd, pid, app: win::app_name(pid), kind: Kind::Adopted, opened: Instant::now(), slot: take_slot(), home: None, handoff: None });
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
        let w = self.give_up(id).unwrap();
        let text = match w.kind {
            Kind::Opened if !keep => format!("Closed window {id}."),
            Kind::Opened => format!("Left window {id} open, on the user's screen now."),
            Kind::Borrowed => format!("Returned window {id} to the user."),
            Kind::Adopted => format!("Released window {id}."),
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slots_go_to_the_lowest_free_place() {
        assert_eq!(lowest_free(&[]), 0);
        assert_eq!(lowest_free(&[true, true]), 2);
        assert_eq!(lowest_free(&[true, false, true]), 1);
    }
}
