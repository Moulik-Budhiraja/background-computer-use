//! What a host app needs to show agent sessions in its own UI, over the pipe:
//! live session state, preview frames, stop, pause and handoffs. The same
//! protocol as the Mac's `HostServer` (docs/embedding.md); the TypeScript
//! client in clients/typescript speaks it on both.
//!
//! Requests are lines like `{"id": 1, "op": "hello"}`; each gets one reply
//! with the same `id` and `ok`. Pushed lines have `event` instead of `id`.
//! Points are on the session's agent screen, top-left origin, in pixels.
//!
//! Every process of the user can open the pipe (pipe.rs): there's no code
//! signature check like the Mac's, so `bcu serve --trust-client` changes
//! nothing here, and every client sees every session it asks for.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, Once, OnceLock, mpsc};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Map, Value, json};
use windows::Win32::Foundation::{HWND, POINT, RECT};
use windows::Win32::UI::WindowsAndMessaging::{SWP_NOACTIVATE, SWP_NOZORDER, SetWindowPos, SwitchToThisWindow};

use crate::pipe::Pipe;
use crate::{engine, monitor, sessions, stream, win};

/// Bumped when a change would break an existing client. The Mac's is the same.
pub const PROTOCOL: u64 = 1;

/// The Windows app's name, which runs the engine when it's the tray app.
pub const APP_NAME: &str = "Background Computer Use";

// ---------- who runs the engine ----------

struct Owner {
    name: String,
    /// The tray app shows host apps' sessions with its own controls.
    shows_hosts: bool,
}

static OWNER: OnceLock<Owner> = OnceLock::new();

/// Who runs this engine: the tray app (which shows hosts' sessions too), or
/// a host app's `bcu serve --owner <name>`. Call once, before serving.
pub fn configure(name: &str, shows_hosts: bool) {
    let _ = OWNER.set(Owner { name: name.to_string(), shows_hosts });
}

fn owner() -> &'static Owner {
    OWNER.get_or_init(|| Owner { name: APP_NAME.into(), shows_hosts: true })
}

/// The host app whose `bcu serve` runs this engine; None for the tray app.
pub fn host_app() -> Option<&'static str> {
    let o = owner();
    (!o.shows_hosts).then_some(o.name.as_str())
}

/// Another engine asked this one to step aside once its agents are done
/// (`yield`, from the tray app as it starts). `bcu serve` watches this.
static YIELDING: AtomicBool = AtomicBool::new(false);

pub fn yielding() -> bool {
    YIELDING.load(Ordering::Relaxed)
}

/// The engine's version: the release's, or the crate's in a development build.
pub fn version() -> &'static str {
    crate::updater::version()
}

// ---------- connections ----------

/// One client connection. Lines are written by a thread of its own, in the
/// order they're sent, so a slow client never holds up the engine.
pub struct Conn {
    pub id: u64,
    tx: Mutex<Option<mpsc::Sender<Vec<u8>>>>,
    /// Lines sent and not yet written.
    backlog: Arc<AtomicUsize>,
}

static NEXT_CONN: AtomicU64 = AtomicU64::new(1);

impl Conn {
    pub fn new(pipe: Arc<Pipe>) -> Arc<Conn> {
        let (tx, rx) = mpsc::channel::<Vec<u8>>();
        let backlog = Arc::new(AtomicUsize::new(0));
        let pending = backlog.clone();
        std::thread::Builder::new()
            .name("pipe writer".into())
            .spawn(move || {
                for bytes in rx {
                    let ok = pipe.write_all(&bytes).is_ok();
                    pending.fetch_sub(1, Ordering::Relaxed);
                    if !ok {
                        break;
                    }
                }
            })
            .expect("pipe writer thread");
        Arc::new(Conn { id: NEXT_CONN.fetch_add(1, Ordering::Relaxed), tx: Mutex::new(Some(tx)), backlog })
    }

    pub fn send(&self, v: &Value) {
        let mut bytes = serde_json::to_vec(v).unwrap_or_default();
        bytes.push(b'\n');
        self.send_bytes(bytes);
    }

    fn send_bytes(&self, bytes: Vec<u8>) {
        if let Some(tx) = lock(&self.tx).as_ref() {
            self.backlog.fetch_add(1, Ordering::Relaxed);
            if tx.send(bytes).is_err() {
                self.backlog.fetch_sub(1, Ordering::Relaxed);
            }
        }
    }

    /// Lines sent that the client hasn't taken yet.
    pub fn backlog(&self) -> usize {
        self.backlog.load(Ordering::Relaxed)
    }

    fn close(&self) {
        lock(&self.tx).take();
    }
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

struct Client {
    conn: Arc<Conn>,
    subscribed: bool,
    /// Sessions of this host only; None with `all`.
    host: Option<String>,
    all: bool,
    last_sessions: Option<Vec<u8>>,
    streams: HashMap<u64, Arc<stream::Stream>>,
}

static CLIENTS: Mutex<Option<HashMap<u64, Client>>> = Mutex::new(None);

fn with_clients<R>(f: impl FnOnce(&mut HashMap<u64, Client>) -> R) -> R {
    f(lock(&CLIENTS).get_or_insert_with(HashMap::new))
}

/// The connection closed: its streams end with it.
pub fn closed(conn: &Conn) {
    let gone = with_clients(|c| c.remove(&conn.id));
    if let Some(c) = gone {
        for s in c.streams.values() {
            s.stop();
        }
    }
    conn.close();
}

// ---------- what the engine tells hosts about each session ----------

/// A window of a session, as the session's thread last published it.
#[derive(Clone)]
pub struct WindowInfo {
    pub id: u64,
    pub hwnd: HWND,
    pub pid: u32,
    pub app: String,
    /// The app's executable, full path: what the Mac's `bundle_id` is.
    pub exe: Option<String>,
    pub kind: &'static str,
    /// Why it was handed to the user, while it is.
    pub handoff: Option<String>,
}

// Only the window's number is used off the session's thread.
unsafe impl Send for WindowInfo {}

#[derive(Default)]
struct Extra {
    host: Option<String>,
    parent: Option<String>,
    windows: Vec<WindowInfo>,
    activity: VecDeque<(f64, String, bool)>,
}

static EXTRAS: Mutex<Option<HashMap<String, Extra>>> = Mutex::new(None);

fn with_extras<R>(f: impl FnOnce(&mut HashMap<String, Extra>) -> R) -> R {
    f(lock(&EXTRAS).get_or_insert_with(HashMap::new))
}

/// A tool call for `session` arrived: `_host` and `_parent` say whose it is.
pub fn note_call(session: &str, args: &Map<String, Value>) {
    let host = args.get("_host").and_then(Value::as_str).filter(|h| !h.is_empty());
    let parent = args.get("_parent").and_then(Value::as_str).filter(|p| !p.is_empty());
    let changed = with_extras(|x| {
        let e = x.entry(session.to_string()).or_default();
        let mut changed = false;
        if e.host.is_none() && host.is_some() {
            e.host = host.map(String::from);
            changed = true;
        }
        if e.parent.is_none() && parent.is_some() {
            e.parent = parent.map(String::from);
            changed = true;
        }
        changed
    });
    if changed {
        schedule_push();
    }
}

/// The session's thread published its windows (Engine::publish).
pub fn published(session: &str, windows: Vec<WindowInfo>) {
    with_extras(|x| x.entry(session.to_string()).or_default().windows = windows);
    schedule_push();
}

/// A call finished, for the session's activity (the Mac's wording).
pub fn called(session: &str, tool: &str, took: Duration, text: &str, error: bool) {
    let first = text.lines().next().unwrap_or("");
    let line = if error {
        format!("{tool} failed after {} ms: {first}", took.as_millis())
    } else {
        format!("{tool} ({} ms): {first}", took.as_millis())
    };
    log(session, line, error);
}

/// A line of the session's activity.
pub fn log(session: &str, text: String, error: bool) {
    let text: String = text.chars().take(300).collect();
    with_extras(|x| {
        let a = &mut x.entry(session.to_string()).or_default().activity;
        a.push_back((wall_ms(), text, error));
        while a.len() > 60 {
            a.pop_front();
        }
    });
    schedule_push();
}

/// The session a subagent's session came from, if it's a subagent's.
pub fn parent(session: &str) -> Option<String> {
    with_extras(|x| x.get(session).and_then(|e| e.parent.clone()))
}

/// The session in the same agent family as `caller` (its parent, its
/// subagents, their siblings) that has window `id`: an agent can hand a
/// window to its subagent, or back.
pub fn relative_owning(caller: &str, id: u64) -> Option<String> {
    with_extras(|x| {
        let root = x.get(caller).and_then(|e| e.parent.clone()).unwrap_or_else(|| caller.to_string());
        x.iter()
            .filter(|(s, e)| s.as_str() != caller && (s.as_str() == root || e.parent.as_deref() == Some(root.as_str())))
            .find(|(_, e)| e.windows.iter().any(|w| w.id == id))
            .map(|(s, _)| s.clone())
    })
}

/// The sessions of `session`'s family: its root, and the root's subagents.
pub fn family(session: &str) -> Vec<String> {
    with_extras(|x| {
        let root = x.get(session).and_then(|e| e.parent.clone()).unwrap_or_else(|| session.to_string());
        let mut out: Vec<String> = x.iter().filter(|(_, e)| e.parent.as_deref() == Some(root.as_str())).map(|(s, _)| s.clone()).collect();
        out.push(root);
        if !out.iter().any(|s| s == session) {
            out.push(session.to_string());
        }
        out
    })
}

/// Windows of these sessions.
pub fn windows_of(sessions: &[String]) -> Vec<WindowInfo> {
    with_extras(|x| sessions.iter().filter_map(|s| x.get(s)).flat_map(|e| e.windows.iter().cloned()).collect())
}

/// Every session's windows, with the session.
pub fn all_windows() -> Vec<(String, WindowInfo)> {
    with_extras(|x| x.iter().flat_map(|(s, e)| e.windows.iter().map(move |w| (s.clone(), w.clone()))).collect())
}

/// Where an agent's action is about to land, in screen pixels: `click`,
/// `move` (scrolling, typing) or `drag` (from `p` to `to`).
pub fn pointer(session: &str, p: POINT, kind: &str, to: Option<POINT>) {
    let Some(m) = monitor::of_session(session) else { return };
    let host = with_extras(|x| x.get(session).map(|e| e.host.clone()));
    let mut o = json!({"event": "pointer", "session": session, "x": p.x - m.rect.left, "y": p.y - m.rect.top, "kind": kind});
    if let Some(t) = to {
        o["to"] = json!({"x": t.x - m.rect.left, "y": t.y - m.rect.top});
    }
    for conn in subscribers(host.flatten()) {
        conn.send(&o);
    }
}

/// The user stopped the session from the tray app: its windows are released,
/// and the hosts showing it hear so. A host's own `stop` isn't echoed.
pub fn stopped_by_user(session: &str) {
    let host = with_extras(|x| x.get(session).and_then(|e| e.host.clone()));
    for conn in subscribers(host) {
        conn.send(&json!({"event": "stopped", "session": session}));
    }
}

/// The clients subscribed to sessions of `host`.
fn subscribers(host: Option<String>) -> Vec<Arc<Conn>> {
    with_clients(|c| {
        c.values()
            .filter(|c| c.subscribed && (c.all || (c.host.is_some() && c.host == host)))
            .map(|c| c.conn.clone())
            .collect()
    })
}

// ---------- requests ----------

/// Answer one request (pipe threads).
pub fn handle(conn: &Arc<Conn>, op: &str, req: &Map<String, Value>) -> Value {
    with_clients(|c| {
        c.entry(conn.id).or_insert_with(|| Client {
            conn: conn.clone(),
            subscribed: false,
            host: None,
            all: false,
            last_sessions: None,
            streams: HashMap::new(),
        });
    });
    match dispatch(conn, op, req) {
        Ok(mut v) => {
            v["ok"] = json!(true);
            v
        }
        Err(e) => json!({"ok": false, "error": e}),
    }
}

fn s<'a>(req: &'a Map<String, Value>, k: &str) -> Option<&'a str> {
    req.get(k).and_then(Value::as_str)
}

fn int(req: &Map<String, Value>, k: &str) -> Option<i64> {
    req.get(k).and_then(|v| v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)))
}

fn dispatch(conn: &Arc<Conn>, op: &str, req: &Map<String, Value>) -> Result<Value, String> {
    match op {
        "hello" => Ok(json!({"engine": engine_info()})),

        "catalog" => Ok(json!({"tools": crate::tools::tools(), "instructions": crate::tools::server_instructions()})),

        "subscribe" => {
            let host = s(req, "host").map(String::from);
            let all = req.get("all").and_then(Value::as_bool).unwrap_or(host.is_none());
            with_clients(|c| {
                if let Some(c) = c.get_mut(&conn.id) {
                    c.host = host;
                    c.all = all;
                    c.subscribed = true;
                    c.last_sessions = None;
                }
            });
            push_now();
            Ok(json!({}))
        }

        "unsubscribe" => {
            with_clients(|c| {
                if let Some(c) = c.get_mut(&conn.id) {
                    c.subscribed = false;
                }
            });
            Ok(json!({}))
        }

        "sessions" => {
            let host = s(req, "host");
            let all = req.get("all").and_then(Value::as_bool).unwrap_or(host.is_none());
            let list: Vec<Value> = session_list()
                .into_iter()
                .filter(|(_, h, _)| all || (host.is_some() && h.as_deref() == host))
                .map(|(_, _, v)| v)
                .collect();
            Ok(json!({"engine": engine_info(), "sessions": list}))
        }

        "pause" => {
            let id = session(req)?;
            engine::set_paused(Some(&id), req.get("paused").and_then(Value::as_bool).unwrap_or(true));
            Ok(json!({}))
        }

        "stop" => {
            let id = session(req)?;
            engine::stop_session(&id);
            Ok(json!({}))
        }

        "rename" => {
            let id = session(req)?;
            let label = s(req, "label").map(str::trim).filter(|l| !l.is_empty()).ok_or("rename needs label")?;
            sessions::update(&id, |v| v.label = label.to_string());
            Ok(json!({}))
        }

        "hand_back" => {
            let id = session(req)?;
            engine::hand_back(&id);
            Ok(json!({}))
        }

        "open_handoff" => {
            let id = session(req)?;
            let w = windows_of(&[id]).into_iter().find(|w| w.handoff.is_some()).ok_or("that session hasn't handed a window off")?;
            let area = match req.get("area") {
                None | Some(Value::Null) => None,
                Some(a) => Some(area(a)?),
            };
            open_handoff(w.hwnd, area);
            Ok(json!({}))
        }

        "frames" => {
            let id = session(req)?;
            let opts = stream_options(req, None, &id)?;
            let stream = stream::Stream::start(id, conn.clone(), opts);
            let n = stream.id;
            with_clients(|c| {
                if let Some(c) = c.get_mut(&conn.id) {
                    c.streams.insert(n, stream);
                }
            });
            Ok(json!({"stream": n}))
        }

        "frames_update" => {
            let s = stream_of(conn, req)?;
            let opts = stream_options(req, Some(s.options()), &s.session)?;
            s.update(opts);
            Ok(json!({}))
        }

        "frames_stop" => {
            let s = stream_of(conn, req)?;
            s.stop();
            with_clients(|c| {
                if let Some(c) = c.get_mut(&conn.id) {
                    c.streams.remove(&s.id);
                }
            });
            Ok(json!({}))
        }

        "yield" => {
            // Only a host's own engine steps aside; the tray app's never does.
            let yields = !owner().shows_hosts;
            if yields && !YIELDING.swap(true, Ordering::Relaxed) {
                eprintln!("asked to yield; stopping once no agent is working");
            }
            Ok(json!({"yielding": yields}))
        }

        _ => Err(format!("unknown op {op}")),
    }
}

/// The session a request names. Another app's session would look the same as none.
fn session(req: &Map<String, Value>) -> Result<String, String> {
    let id = s(req, "session").ok_or("missing session")?;
    sessions::get(id).map(|v| v.id).ok_or_else(|| format!("no session {id}"))
}

fn stream_of(conn: &Conn, req: &Map<String, Value>) -> Result<Arc<stream::Stream>, String> {
    let n = int(req, "stream").ok_or("no such stream")? as u64;
    with_clients(|c| c.get(&conn.id).and_then(|c| c.streams.get(&n).cloned())).ok_or_else(|| "no such stream".into())
}

fn stream_options(req: &Map<String, Value>, base: Option<stream::Options>, session: &str) -> Result<stream::Options, String> {
    let mut o = base.unwrap_or_default();
    if let Some(f) = int(req, "fps") {
        o.fps = f.clamp(1, 60) as u32;
    }
    if let Some(w) = int(req, "max_width") {
        o.max_width = w.clamp(16, 7680) as i32;
    }
    if let Some(q) = req.get("quality").and_then(Value::as_f64) {
        o.quality = q.clamp(0.05, 1.0) as f32;
    }
    if let Some(w) = int(req, "window") {
        // One of the session's own windows, or 0 for its whole screen.
        if w != 0 && !windows_of(&family(session)).iter().any(|x| x.id == w as u64) {
            return Err(format!("no window {w} in that session"));
        }
        o.window = w as u64;
    }
    if let Some(x) = int(req, "exclude") {
        o.exclude = x as u64;
    }
    Ok(o)
}

fn area(v: &Value) -> Result<RECT, String> {
    let n = |k: &str| v.get(k).and_then(Value::as_f64);
    match (n("x"), n("y"), n("width"), n("height")) {
        (Some(x), Some(y), Some(w), Some(h)) => {
            Ok(RECT { left: x.round() as i32, top: y.round() as i32, right: (x + w).round() as i32, bottom: (y + h).round() as i32 })
        }
        _ => Err("area needs x, y, width and height (screen pixels, top-left origin)".into()),
    }
}

/// Bring a handed-off window to the front of the user's screen, in `area`
/// (centered, no bigger than it) if given.
fn open_handoff(hwnd: HWND, area: Option<RECT>) {
    if let Some(a) = area {
        let f = win::frame(hwnd);
        let (w, h) = ((f.right - f.left).min(a.right - a.left), (f.bottom - f.top).min(a.bottom - a.top));
        let x = a.left + (a.right - a.left - w) / 2;
        let y = a.top + (a.bottom - a.top - h) / 2;
        unsafe {
            let _ = SetWindowPos(hwnd, None, x, y, w, h, SWP_NOZORDER | SWP_NOACTIVATE);
        }
    }
    unsafe { SwitchToThisWindow(hwnd, true) };
}

// ---------- state ----------

pub fn engine_info() -> Value {
    let problem = crate::setup::screen_problem();
    let mut o = json!({
        "protocol": PROTOCOL,
        "version": version(),
        "owner": owner().name,
        "pid": std::process::id(),
        "platform": "windows",
        // Windows asks for neither; what agents need is the agent screen.
        "permissions": {"accessibility": true, "screen_recording": true, "agent_screen": problem.is_none()},
        "max_displays": monitor::WANTED,
        "display": {"width": monitor::WIDTH, "height": monitor::HEIGHT},
    });
    if let Some(p) = problem {
        o["agent_screen_problem"] = json!(p);
    }
    if owner().shows_hosts {
        o["shows_hosts"] = json!(true);
    }
    o
}

fn wall_ms() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64() * 1000.0).unwrap_or(0.0)
}

/// ISO 8601 in UTC with milliseconds, like the Mac's activity times.
fn iso(ms: f64) -> String {
    let total = (ms / 1000.0).floor() as i64;
    let millis = (ms - total as f64 * 1000.0).round().clamp(0.0, 999.0) as i64;
    let (days, secs) = (total.div_euclid(86_400), total.rem_euclid(86_400));
    // Civil from days (Howard Hinnant's algorithm).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + if m <= 2 { 1 } else { 0 };
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}.{millis:03}Z", secs / 3600, secs % 3600 / 60, secs % 60)
}

/// Every session: (id, host, JSON), in the order they started.
fn session_list() -> Vec<(String, Option<String>, Value)> {
    let views = sessions::all();
    let screens: HashMap<String, RECT> = monitor::slots().into_iter().collect();
    with_extras(|x| views.iter().map(|v| {
        let e = x.get(&v.id);
        let host = e.and_then(|e| e.host.clone());
        (v.id.clone(), host, session_json(v, e, screens.get(&v.id)))
    }).collect())
}

fn session_json(v: &sessions::View, e: Option<&Extra>, screen: Option<&RECT>) -> Value {
    let since = |s: u64| v.last_call.is_some_and(|t| t.elapsed() < Duration::from_secs(s));
    let (state, text) = if v.handoff.is_some() {
        ("waiting", v.status_text())
    } else if v.paused {
        ("paused", "Paused".to_string())
    } else if v.busy.is_some() || since(8) || v.windows > 0 {
        ("working", v.status_text())
    } else {
        ("idle", "Idle".to_string())
    };
    let windows: Vec<Value> = e
        .map(|e| {
            e.windows
                .iter()
                .map(|w| {
                    let handed = w.handoff.is_some();
                    let mut o = json!({"id": w.id, "app": w.app, "pid": w.pid, "kind": w.kind, "handed_off": handed, "with_user": handed});
                    if let Some(exe) = &w.exe {
                        o["exe"] = json!(exe);
                    }
                    if let Some(r) = &w.handoff {
                        o["handoff_reason"] = json!(r);
                    }
                    if let (Some(m), false) = (screen, handed) {
                        let f = win::frame(w.hwnd);
                        o["frame"] = json!({"x": f.left - m.left, "y": f.top - m.top, "width": f.right - f.left, "height": f.bottom - f.top});
                    }
                    o
                })
                .collect()
        })
        .unwrap_or_default();
    let activity: Vec<Value> = e
        .map(|e| e.activity.iter().rev().take(20).rev().map(|(t, text, error)| json!({"time": iso(*t), "text": text, "error": error})).collect())
        .unwrap_or_default();
    let mut o = json!({
        "id": v.id,
        "label": v.label,
        "status": {"state": state, "text": text},
        "active": v.busy.is_some() || since(3),
        "paused": v.paused,
        "user_in_control": false,
        "windows": windows,
        "activity": activity,
    });
    if let Some(h) = e.and_then(|e| e.host.as_ref()) {
        o["host"] = json!(h);
    }
    if let Some(p) = e.and_then(|e| e.parent.as_ref()) {
        o["parent"] = json!(p);
    }
    if let Some(m) = screen {
        o["display"] = json!({"width": m.right - m.left, "height": m.bottom - m.top});
        if let Some((p, _)) = v.pointer {
            o["pointer"] = json!({"x": p.x - m.left, "y": p.y - m.top});
        }
    }
    if let Some(w) = e.and_then(|e| e.windows.iter().find(|w| w.handoff.is_some())) {
        o["handoff"] = json!({"window": w.id, "app": w.app, "reason": w.handoff, "with_user": true});
    }
    o
}

// ---------- pushing `sessions` ----------

static DIRTY: Mutex<bool> = Mutex::new(false);
static WAKE: Condvar = Condvar::new();
static PUSHER: Once = Once::new();

/// Something changed: push `sessions` to subscribers, at most every 50 ms.
pub fn schedule_push() {
    PUSHER.call_once(|| {
        std::thread::Builder::new().name("host push".into()).spawn(push_loop).expect("host push thread");
    });
    *lock(&DIRTY) = true;
    WAKE.notify_one();
}

fn push_now() {
    schedule_push();
}

fn push_loop() {
    // State that changes without a call (a call's "Working" turning "Idle"
    // after a while, windows the user closed) is pushed at least this often.
    const TICK: Duration = Duration::from_secs(1);
    loop {
        {
            let mut dirty = lock(&DIRTY);
            if !*dirty {
                dirty = WAKE.wait_timeout(dirty, TICK).map(|(g, _)| g).unwrap_or_else(|e| e.into_inner().0);
            }
            *dirty = false;
        }
        push();
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn push() {
    let targets: Vec<(u64, Option<String>, bool)> = with_clients(|c| c.values().filter(|c| c.subscribed).map(|c| (c.conn.id, c.host.clone(), c.all)).collect());
    if targets.is_empty() {
        return;
    }
    let list = session_list();
    let info = engine_info();
    for (id, host, all) in targets {
        let sessions: Vec<&Value> = list.iter().filter(|(_, h, _)| all || (host.is_some() && *h == host)).map(|(_, _, v)| v).collect();
        let mut line = serde_json::to_vec(&json!({"event": "sessions", "engine": info, "sessions": sessions})).unwrap_or_default();
        line.push(b'\n');
        let conn = with_clients(|c| {
            let c = c.get_mut(&id)?;
            if c.last_sessions.as_ref() == Some(&line) {
                return None;
            }
            c.last_sessions = Some(line.clone());
            Some(c.conn.clone())
        });
        if let Some(conn) = conn {
            conn.send_bytes(line);
        }
    }
}

// ---------- the sessions a stream may show ----------

/// Whether anything but `session`'s family's windows (and the shell's
/// desktop and taskbar) is on `screen`, the shared agent screen: then a
/// copy of it would show that, and the stream draws the family's windows on
/// their own instead. Anything counts, not just other sessions' published
/// windows: a window another agent is opening right now isn't published yet.
pub fn others_on(session: &str, screen: &RECT) -> bool {
    let mine: HashSet<usize> = shown_windows(session, screen, 0).iter().map(|h| h.0 as usize).collect();
    win::top_level_windows().into_iter().any(|h| {
        if mine.contains(&(h.0 as usize)) || !win::is_visible(h) || win::is_minimized(h) || win::is_cloaked(h) || is_shell(h) {
            return false;
        }
        let f = win::frame(h);
        f.left < screen.right && screen.left < f.right && f.top < screen.bottom && screen.top < f.bottom
    })
}

/// The desktop and the taskbar Windows puts on every screen.
fn is_shell(h: HWND) -> bool {
    use windows::Win32::UI::WindowsAndMessaging::GetClassNameW;
    let mut buf = [0u16; 64];
    let n = unsafe { GetClassNameW(h, &mut buf) };
    matches!(String::from_utf16_lossy(&buf[..n.max(0) as usize]).as_str(), "Progman" | "WorkerW" | "Shell_TrayWnd" | "Shell_SecondaryTrayWnd")
}

/// The family's windows on `screen` and the popups of their apps over them
/// (menus, dropdowns), from the top down, without `exclude`: what a frame
/// of the session shows, and where take-over input goes. A popup counts
/// when one of the family's windows owns it, or, unowned (a menu), when no
/// session outside the family has windows in its app: in one browser
/// process with another session's windows, that session's menus don't.
pub fn shown_windows(session: &str, screen: &RECT, exclude: u64) -> Vec<HWND> {
    use windows::Win32::UI::WindowsAndMessaging::{GA_ROOTOWNER, GetAncestor};
    let family = family(session);
    let mine = windows_of(&family);
    let hwnds: HashSet<usize> = mine.iter().filter(|w| w.handoff.is_none()).map(|w| w.hwnd.0 as usize).collect();
    let others: HashSet<u32> = all_windows().into_iter().filter(|(s, _)| !family.contains(s)).map(|(_, w)| w.pid).collect();
    let own_pids: HashSet<u32> = mine.iter().map(|w| w.pid).filter(|p| !others.contains(p)).collect();
    let overlaps = |f: &RECT| f.left < screen.right && screen.left < f.right && f.top < screen.bottom && screen.top < f.bottom;
    let family_popup = |h: HWND| {
        if win::is_app_window(h) || crate::guard::is_agent_window(h) {
            return false;
        }
        let owner = unsafe { GetAncestor(h, GA_ROOTOWNER) };
        if !owner.0.is_null() && owner != h {
            return hwnds.contains(&(owner.0 as usize));
        }
        own_pids.contains(&win::pid_tid(h).0)
    };
    // EnumWindows lists top-level windows from the top down.
    win::top_level_windows()
        .into_iter()
        .filter(|h| win::id(*h) != exclude && win::is_visible(*h) && !win::is_minimized(*h) && overlaps(&win::frame(*h)))
        .filter(|h| hwnds.contains(&(h.0 as usize)) || family_popup(*h))
        .collect()
}

/// When the last call of any session ran, and whether any agent has windows:
/// a yielding engine stops once none has either in the last 3 s.
pub fn agents_idle() -> bool {
    sessions::all().iter().all(|v| v.busy.is_none() && v.windows == 0 && v.last_call.is_none_or(|t| t.elapsed() > Duration::from_secs(3)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iso_times() {
        assert_eq!(iso(0.0), "1970-01-01T00:00:00.000Z");
        assert_eq!(iso(1_700_000_000_123.0), "2023-11-14T22:13:20.123Z");
        assert_eq!(iso(951_782_400_000.0), "2000-02-29T00:00:00.000Z");
    }

    #[test]
    fn families() {
        note_call("p", &Map::new());
        let mut a = Map::new();
        a.insert("_parent".into(), json!("p"));
        note_call("p/a", &a);
        note_call("p/b", &a);
        published("p/a", vec![WindowInfo { id: 7, hwnd: HWND(std::ptr::null_mut()), pid: 1, app: "X".into(), exe: None, kind: "opened", handoff: None }]);
        assert_eq!(relative_owning("p", 7).as_deref(), Some("p/a"));
        assert_eq!(relative_owning("p/b", 7).as_deref(), Some("p/a"));
        assert_eq!(relative_owning("p/a", 7), None);
        let mut f = family("p/b");
        f.sort();
        assert_eq!(f, vec!["p", "p/a", "p/b"]);
    }
}
