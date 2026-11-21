//! Recordings of host apps' sessions, for a host's history of what its
//! agents did (`recordings`, docs/embedding.md). The same layout as the
//! Mac's (Sources/BCUCore/Recorder.swift), one folder per run:
//!   meta.json      session, label, start, end, screen size
//!   frames.jsonl   one line per kept frame: time, app in front, its exe
//!   events.jsonl   the session's activity and pointer, one line each
//!   staging/       the frames, as JPEGs named by their time
//! The Mac packs frames into video chunks (chunks.jsonl, chunk-*.mp4) every
//! minute or so; here they stay JPEGs, which hosts read the same way.
//!
//! A host's sessions are recorded only after it asks, into a folder it picks,
//! while they have the agent screen. A frame is kept when the picture changed
//! (checked twice a second, and right after each call), and is what a host's
//! preview of the session shows (stream.rs). Runs older than the host's
//! retention go, and the oldest frames go first past its size limit, checked
//! every minute.

use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Condvar, Mutex, Once};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

use crate::jpeg::{self, Bgra};
use crate::{host, monitor, sessions, stream, win};

pub const DEFAULT_LIMIT_MB: u64 = 300;
/// The least `limit_mb` takes.
pub const MIN_LIMIT_MB: u64 = 50;
pub const DEFAULT_RETENTION_DAYS: u64 = 7;
const SAMPLE: Duration = Duration::from_millis(500);

/// Where one host's recordings go, how long they're kept and how much room they may take.
#[derive(Clone, PartialEq)]
pub struct Store {
    pub directory: PathBuf,
    pub limit_mb: u64,
    pub retention_days: u64,
}

struct Run {
    id: String,
    session: String,
    dir: PathBuf,
    host: String,
    start: f64,
    label: String,
    size: (i32, i32),
    last_t: f64,
    thumb: Option<Vec<u8>>,
    frames: std::fs::File,
    events: std::fs::File,
    /// Take a frame on the next look, even for a small change.
    force: bool,
    /// Since when the session hasn't had the agent screen.
    away: Option<Instant>,
}

#[derive(Default)]
struct State {
    stores: HashMap<String, Store>,
    /// Live runs, by session.
    runs: HashMap<String, Run>,
    /// Activity and pointer lines of a recorded host's session from before
    /// its run began (its first call gets it the screen; the run begins at
    /// the next look), with its host and when each came.
    early: HashMap<String, (String, Vec<(Instant, Value)>)>,
    last_maintain: Option<Instant>,
}

/// How far back a new run takes in its session's activity.
const EARLY: Duration = Duration::from_secs(30);

static STATE: Mutex<Option<State>> = Mutex::new(None);
static WAKE: Condvar = Condvar::new();
static START: Once = Once::new();

fn with<R>(f: impl FnOnce(&mut State) -> R) -> R {
    let mut g = STATE.lock().unwrap_or_else(|e| e.into_inner());
    f(g.get_or_insert_with(State::default))
}

fn wall_ms() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64() * 1000.0).unwrap_or(0.0)
}

/// Record `host`'s sessions into `store` from now on, or stop (None). Runs
/// under way end; the same folder again keeps them going with the new limits.
pub fn set_store(host: &str, store: Option<Store>) {
    let ended: Vec<Run> = with(|s| {
        let same_dir = store.as_ref().is_some_and(|n| s.stores.get(host).is_some_and(|o| o.directory == n.directory));
        match &store {
            Some(n) => s.stores.insert(host.to_string(), n.clone()),
            None => s.stores.remove(host),
        };
        if same_dir {
            return Vec::new();
        }
        let ids: Vec<String> = s.runs.iter().filter(|(_, r)| r.host == host).map(|(id, _)| id.clone()).collect();
        s.early.retain(|_, (h, _)| h != host);
        ids.into_iter().filter_map(|id| s.runs.remove(&id)).collect()
    });
    for r in ended {
        finish(r);
    }
    if let Some(store) = store {
        std::thread::spawn(move || maintain(&store, &live_ids()));
    }
    START.call_once(|| {
        std::thread::Builder::new().name("recorder".into()).spawn(run).expect("recorder thread");
    });
    WAKE.notify_one();
}

fn live_ids() -> Vec<String> {
    with(|s| s.runs.values().map(|r| r.id.clone()).collect())
}

/// A line of a session's activity.
pub fn note(session: &str, text: &str, error: bool) {
    let mut line = json!({"t": wall_ms(), "x": text.chars().take(300).collect::<String>()});
    if error {
        line["e"] = json!(true);
    }
    event(session, line);
}

/// Where an action is about to land, in points on the agent screen.
pub fn pointer(session: &str, x: i32, y: i32, click: bool) {
    let mut line = json!({"t": wall_ms(), "p": [x, y]});
    if click {
        line["c"] = json!(true);
    }
    event(session, line);
}

/// Into the session's run, or kept for the run about to begin.
fn event(session: &str, line: Value) {
    let host = host::host_of(session);
    with(|s| {
        if let Some(r) = s.runs.get_mut(session) {
            write_line(&mut r.events, &line);
        } else if let Some(h) = host.filter(|h| s.stores.contains_key(h)) {
            let (_, lines) = s.early.entry(session.to_string()).or_insert_with(|| (h, Vec::new()));
            lines.retain(|(t, _)| t.elapsed() < EARLY);
            lines.push((Instant::now(), line));
        }
    });
}

/// A call just finished: take a frame soon, even for a small change.
pub fn capture_soon(session: &str) {
    let wanted = with(|s| s.runs.get_mut(session).map(|r| r.force = true).is_some());
    if wanted {
        WAKE.notify_one();
    }
}

/// The session was renamed: the run under way goes by the new name.
pub fn rename(session: &str, label: &str) {
    with(|s| {
        if let Some(r) = s.runs.get_mut(session) {
            r.label = label.to_string();
            write_meta(r, None);
        }
    });
}

/// The engine is stopping: every run ends here.
pub fn finish_all() {
    let runs: Vec<Run> = with(|s| s.runs.drain().map(|(_, r)| r).collect());
    for r in runs {
        finish(r);
    }
}

fn run() {
    loop {
        {
            let g = STATE.lock().unwrap_or_else(|e| e.into_inner());
            let forced = g.as_ref().is_some_and(|s| s.runs.values().any(|r| r.force));
            if !forced {
                let _ = WAKE.wait_timeout(g, SAMPLE);
            }
        }
        // A frame wanted after a call: once the window has had a moment to change.
        std::thread::sleep(Duration::from_millis(150));
        tick();
    }
}

/// Since when captures have waited for the user to stop typing or clicking.
static HELD: Mutex<Option<Instant>> = Mutex::new(None);

/// Whether the user gave input in the last 300 ms. Copying the screen goes
/// through the compositor, and on a weak GPU (or none, in a VM) doing it
/// while they type held up their input enough to repeat and drop keys.
fn user_busy() -> bool {
    use windows::Win32::System::SystemInformation::GetTickCount;
    use windows::Win32::UI::Input::KeyboardAndMouse::{GetLastInputInfo, LASTINPUTINFO};
    let mut info = LASTINPUTINFO { cbSize: size_of::<LASTINPUTINFO>() as u32, dwTime: 0 };
    unsafe { GetLastInputInfo(&mut info).as_bool() && GetTickCount().wrapping_sub(info.dwTime) < 300 }
}

fn tick() {
    let stores = with(|s| s.stores.clone());
    if stores.is_empty() {
        return;
    }
    // Captures wait while the user types or clicks, 2 s at most.
    let hold = {
        let mut held = HELD.lock().unwrap_or_else(|e| e.into_inner());
        let hold = user_busy() && held.get_or_insert_with(Instant::now).elapsed() < Duration::from_secs(2);
        if !hold {
            *held = None;
        }
        hold
    };
    // Which sessions are recorded now: a host's that asked, while they have the screen.
    let screens: HashMap<String, windows::Win32::Foundation::RECT> = monitor::slots().into_iter().collect();
    let wanted: Vec<(String, String, String)> = sessions::all()
        .into_iter()
        .filter_map(|v| {
            let h = host::host_of(&v.id)?;
            (stores.contains_key(&h) && screens.contains_key(&v.id)).then(|| (v.id, h, v.label))
        })
        .collect();
    // A run ends once its session has been without the screen for a while
    // (it gave it up, a minute after its last window), not at a blip.
    let ended: Vec<Run> = with(|s| {
        for (id, r) in s.runs.iter_mut() {
            let here = wanted.iter().any(|(w, _, _)| w == id);
            r.away = if here { None } else { r.away.or(Some(Instant::now())) };
        }
        let gone: Vec<String> = s.runs.iter().filter(|(_, r)| r.away.is_some_and(|t| t.elapsed() > Duration::from_secs(5))).map(|(id, _)| id.clone()).collect();
        gone.into_iter().filter_map(|id| s.runs.remove(&id)).collect()
    });
    for r in ended {
        eprintln!("recordings: {} ended: the session gave up the agent screen", r.id);
        finish(r);
    }
    for (session, h, label) in wanted {
        let Some(store) = stores.get(&h) else { continue };
        if with(|s| !s.runs.contains_key(&session))
            && let Some(r) = begin(store, &session, &h, &label)
        {
            // The host may have stopped recording or picked another folder
            // since `stores` was read: only a run for the store it has now.
            let unwanted = with(|s| {
                if s.stores.get(&h) == Some(store) && !s.runs.contains_key(&session) {
                    let mut r = r;
                    // What the session did just before: its first call, say.
                    if let Some((_, lines)) = s.early.remove(&session) {
                        for (t, line) in lines {
                            if t.elapsed() < EARLY {
                                write_line(&mut r.events, &line);
                            }
                        }
                    }
                    s.runs.insert(session.clone(), r);
                    None
                } else {
                    Some(r)
                }
            });
            if let Some(r) = unwanted {
                finish(r);
                continue;
            }
        }
        if !hold {
            capture(&session);
        }
    }
    // Every minute, so a busy session can't take far more room than the
    // host allows before its runs are trimmed.
    let due = with(|s| {
        let due = s.last_maintain.is_none_or(|t| t.elapsed() > Duration::from_secs(60));
        if due {
            s.last_maintain = Some(Instant::now());
        }
        due
    });
    if due {
        let live = live_ids();
        for store in stores.values() {
            maintain(store, &live);
        }
    }
}

/// A run's folder name: when it started, to the millisecond (so folders sort
/// by time), the start of the session for reading, and a hash of all of it
/// (a subagent's session starts with its parent's).
pub fn run_id(session: &str, t: &windows::Win32::Foundation::SYSTEMTIME) -> String {
    let safe: String = session.replace('/', "-").chars().take(17).map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '_' }).collect();
    let mut hash: u32 = 2_166_136_261;
    for b in session.bytes() {
        hash = (hash ^ b as u32).wrapping_mul(16_777_619);
    }
    format!(
        "{:04}{:02}{:02}-{:02}{:02}{:02}-{:03}-{safe}-{hash:08x}",
        t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond, t.wMilliseconds
    )
}

fn begin(store: &Store, session: &str, host: &str, label: &str) -> Option<Run> {
    let now = unsafe { windows::Win32::System::SystemInformation::GetLocalTime() };
    let id = run_id(session, &now);
    let dir = store.directory.join(&id);
    if let Err(e) = std::fs::create_dir_all(dir.join("staging")) {
        eprintln!("recordings: can't create {}: {e}", dir.display());
        return None;
    }
    let open = |name: &str| std::fs::OpenOptions::new().create(true).append(true).open(dir.join(name)).ok();
    let size = (monitor::WIDTH, monitor::HEIGHT);
    let r = Run {
        id,
        session: session.to_string(),
        host: host.to_string(),
        start: wall_ms(),
        label: label.to_string(),
        size,
        last_t: 0.0,
        thumb: None,
        frames: open("frames.jsonl")?,
        events: open("events.jsonl")?,
        force: true,
        away: None,
        dir,
    };
    write_meta(&r, None);
    Some(r)
}

fn write_meta(r: &Run, end: Option<f64>) {
    let mut meta = json!({"v": 1, "session": r.session, "label": r.label, "start": r.start, "w": r.size.0, "h": r.size.1});
    if let Some(e) = end {
        meta["end"] = json!(e);
    }
    let tmp = r.dir.join("meta.json.tmp");
    if std::fs::write(&tmp, meta.to_string()).is_ok() {
        let _ = std::fs::rename(&tmp, r.dir.join("meta.json"));
    }
}

fn finish(mut r: Run) {
    write_meta(&r, Some(wall_ms()));
    let _ = r.frames.flush();
    let _ = r.events.flush();
    // Nothing was recorded: no run.
    if std::fs::read_dir(r.dir.join("staging")).map(|mut d| d.next().is_none()).unwrap_or(true) {
        let _ = std::fs::remove_dir_all(&r.dir);
    }
}

fn write_line(f: &mut std::fs::File, v: &Value) {
    let mut bytes = serde_json::to_vec(v).unwrap_or_default();
    bytes.push(b'\n');
    let _ = f.write_all(&bytes);
}

/// Look at the session's screen and keep a frame if it changed.
fn capture(session: &str) {
    let force = with(|s| s.runs.get_mut(session).map(|r| std::mem::replace(&mut r.force, false))).unwrap_or(false);
    let o = stream::Options { max_width: monitor::WIDTH, ..Default::default() };
    let Some((img, Some(screen))) = stream::picture(session, &o) else { return };
    let thumb = thumbnail(&img);
    let changed = with(|s| {
        let r = s.runs.get_mut(session)?;
        if r.thumb.as_ref().is_some_and(|last| !differs(last, &thumb, force)) {
            return None;
        }
        r.thumb = Some(thumb);
        Some(r.dir.clone())
    });
    let Some(dir) = changed else { return };
    let Ok(data) = jpeg::encode(&img, 0.8) else { return };
    let (app, exe) = front_app(session, &screen);
    with(|s| {
        let Some(r) = s.runs.get_mut(session) else { return };
        if r.dir != dir {
            return;
        }
        let mut t = wall_ms().round();
        if t <= r.last_t {
            t = r.last_t + 1.0;
        }
        if std::fs::write(dir.join("staging").join(format!("{}.jpg", t as i64)), &data).is_err() {
            return;
        }
        r.last_t = t;
        let mut line = json!({"t": t, "a": app});
        if let Some(exe) = exe {
            line["b"] = json!(exe);
        }
        write_line(&mut r.frames, &line);
    });
}

/// The app of the topmost window of the session's family on the screen, and its exe.
fn front_app(session: &str, screen: &windows::Win32::Foundation::RECT) -> (String, Option<String>) {
    let mine = host::windows_of(&host::family(session));
    for h in win::top_level_windows() {
        if let Some(w) = mine.iter().find(|w| w.hwnd == h && w.handoff.is_none()) {
            let f = win::frame(h);
            let (cx, cy) = ((f.left + f.right) / 2, (f.top + f.bottom) / 2);
            if win::is_visible(h) && !win::is_minimized(h) && cx >= screen.left && cx < screen.right && cy >= screen.top && cy < screen.bottom {
                return (w.app.clone(), w.exe.clone());
            }
        }
    }
    (String::new(), None)
}

const THUMB_W: usize = 256;
const THUMB_H: usize = 160;

/// A small gray copy, for telling whether anything changed.
fn thumbnail(img: &Bgra) -> Vec<u8> {
    let mut out = vec![0u8; THUMB_W * THUMB_H];
    for y in 0..THUMB_H {
        let sy = y * img.h as usize / THUMB_H;
        for x in 0..THUMB_W {
            let sx = x * img.w as usize / THUMB_W;
            let p = (sy * img.w as usize + sx) * 4;
            let (b, g, r) = (img.bits[p] as u32, img.bits[p + 1] as u32, img.bits[p + 2] as u32);
            out[y * THUMB_W + x] = ((r * 299 + g * 587 + b * 114) / 1000) as u8;
        }
    }
    out
}

/// A blinking caret moves one or two thumbnail pixels a little; anything the
/// agent does moves more. Right after a call, any change counts.
fn differs(a: &[u8], b: &[u8], force: bool) -> bool {
    if a.len() != b.len() {
        return true;
    }
    let (step, needed) = if force { (3, 1) } else { (18, 6) };
    a.iter().zip(b).filter(|(x, y)| (**x as i32 - **y as i32).abs() > step).take(needed).count() >= needed
}

// ---------- keeping a store in check ----------

fn dir_size(p: &Path) -> u64 {
    std::fs::read_dir(p)
        .map(|it| {
            it.filter_map(|e| e.ok())
                .map(|e| {
                    let path = e.path();
                    if path.is_dir() { dir_size(&path) } else { e.metadata().map(|m| m.len()).unwrap_or(0) }
                })
                .sum()
        })
        .unwrap_or(0)
}

/// Delete runs that ended longer ago than the store keeps them, then the
/// oldest frames while the store takes more than its limit (a run left with
/// no frames goes too). `live`: runs being recorded, which keep their folder.
pub fn maintain(store: &Store, live: &[String]) {
    maintain_within(store, live, store.limit_mb.max(MIN_LIMIT_MB) * 1_000_000)
}

fn maintain_within(store: &Store, live: &[String], limit: u64) {
    let cutoff = wall_ms() - store.retention_days.max(1) as f64 * 86_400_000.0;
    let Ok(entries) = std::fs::read_dir(&store.directory) else { return };
    let mut runs: Vec<(PathBuf, f64)> = Vec::new();
    for e in entries.filter_map(|e| e.ok()) {
        let dir = e.path();
        if !dir.is_dir() {
            continue;
        }
        let id = e.file_name().to_string_lossy().to_string();
        let meta = std::fs::read_to_string(dir.join("meta.json")).ok().and_then(|t| serde_json::from_str::<Value>(&t).ok());
        let Some(meta) = meta else {
            // No meta: half made. Gone once it's old.
            let old = e.metadata().and_then(|m| m.modified()).ok().and_then(|m| m.duration_since(UNIX_EPOCH).ok()).is_some_and(|d| (d.as_millis() as f64) < cutoff);
            if old && !live.contains(&id) {
                let _ = std::fs::remove_dir_all(&dir);
            }
            continue;
        };
        let start = meta["start"].as_f64().unwrap_or(0.0);
        let end = meta["end"].as_f64().unwrap_or(start);
        if !live.contains(&id) && end < cutoff {
            let _ = std::fs::remove_dir_all(&dir);
            eprintln!("recordings: deleted {id}, older than {} days", store.retention_days);
            continue;
        }
        runs.push((dir, start));
    }
    let mut used: u64 = runs.iter().map(|(d, _)| dir_size(d)).sum();
    if used <= limit {
        return;
    }
    runs.sort_by(|a, b| a.1.total_cmp(&b.1));
    for (dir, _) in runs {
        if used <= limit {
            break;
        }
        let live_run = dir.file_name().is_some_and(|n| live.iter().any(|l| l.as_str() == n.to_string_lossy()));
        let mut staged: Vec<PathBuf> = std::fs::read_dir(dir.join("staging")).map(|it| it.filter_map(|e| e.ok().map(|e| e.path())).collect()).unwrap_or_default();
        staged.sort_by_key(|p| p.file_stem().and_then(|s| s.to_str()).and_then(|s| s.parse::<i64>().ok()).unwrap_or(0));
        let keep = if live_run { 1 } else { 0 };
        let mut left = staged.len();
        for f in staged {
            if used <= limit || left <= keep {
                break;
            }
            let n = std::fs::metadata(&f).map(|m| m.len()).unwrap_or(0);
            if std::fs::remove_file(&f).is_ok() {
                used = used.saturating_sub(n);
                left -= 1;
            }
        }
        if left == 0 && !live_run {
            used = used.saturating_sub(dir_size(&dir));
            let _ = std::fs::remove_dir_all(&dir);
        }
    }
    eprintln!("recordings: over the {} MB limit in {}, deleted the oldest frames", limit / 1_000_000, store.directory.display());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn run_ids_sort_by_time() {
        let t = windows::Win32::Foundation::SYSTEMTIME { wYear: 2026, wMonth: 11, wDay: 20, wHour: 9, wMinute: 5, wSecond: 7, wMilliseconds: 42, ..Default::default() };
        let id = run_id("helper/sub agent", &t);
        assert!(id.starts_with("20261120-090507-042-helper-sub_agent-"), "{id}");
        assert_eq!(id, run_id("helper/sub agent", &t));
        assert_ne!(id, run_id("helper/other", &t));
    }

    #[test]
    fn small_changes_wait() {
        let a = vec![100u8; THUMB_W * THUMB_H];
        let mut b = a.clone();
        b[10] = 200;
        assert!(!differs(&a, &b, false), "one pixel isn't a change");
        assert!(differs(&a, &b, true), "right after a call, it is");
        for i in 0..6 {
            b[100 + i] = 200;
        }
        assert!(differs(&a, &b, false));
    }

    #[test]
    fn maintain_keeps_the_limit_and_retention() {
        let root = std::env::temp_dir().join(format!("bcu-rec-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let now = wall_ms();
        let make = |id: &str, start: f64, end: f64, frames: usize| {
            let d = root.join(id);
            std::fs::create_dir_all(d.join("staging")).unwrap();
            std::fs::write(d.join("meta.json"), json!({"v": 1, "session": "s", "start": start, "end": end}).to_string()).unwrap();
            for i in 0..frames {
                std::fs::write(d.join("staging").join(format!("{}.jpg", start as i64 + i as i64)), vec![0u8; 1000]).unwrap();
            }
        };
        make("old", now - 10.0 * 86_400_000.0, now - 9.0 * 86_400_000.0, 1);
        make("a", now - 3000.0, now - 2000.0, 4);
        make("b", now - 1000.0, now - 500.0, 3);
        // Each run's meta is a few dozen bytes: 7 frames of 1000 bytes over a 5,300-byte limit.
        maintain_within(&Store { directory: root.clone(), limit_mb: 50, retention_days: 7 }, &[], 5_300);
        assert!(!root.join("old").exists(), "past retention");
        let left = |id: &str| std::fs::read_dir(root.join(id).join("staging")).map(|d| d.count()).unwrap_or(0);
        // The oldest two frames of the oldest run go.
        assert_eq!((left("a"), left("b")), (2, 3));
        let _ = std::fs::remove_dir_all(&root);
    }
}
