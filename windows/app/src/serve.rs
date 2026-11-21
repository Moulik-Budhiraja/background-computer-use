//! `bcu serve`: the engine without the tray app, for a host app that shows
//! agents' screens in its own UI (docs/embedding.md). The host starts it as a
//! child process.
//!
//! One engine runs per user. The first line on stdout says which:
//!   {"event":"ready", ...}    an engine of the host's own is running
//!   {"event":"running", ...}  another one is (the tray app's, or another
//!                             host's); this process exits and the host uses it
//! Either way, the engine is at `socket`, the pipe.
//!
//! When the tray app is installed and set up but not running, `bcu serve`
//! starts it and uses its engine instead, unless `--own-engine`. When the
//! tray app starts while a host's engine runs, it asks that engine to step
//! aside (`yield`), and waits for it.
//!
//! Node puts the processes it starts in a job that kills them all when it
//! exits, so an engine in that job would be gone before it could give the
//! agents' windows back. So the process the host starts is a relay: it runs
//! the engine as a process of its own (`bcu serve-engine`), outside the job,
//! with the same stdin and stdout, and waits for it. The engine stops, and
//! releases the agents' windows first, when the relay or the host exits,
//! when the host writes `quit` on stdin or closes it, or on Ctrl+C. The relay
//! dying covers Node's `kill()`, which on Windows ends the process at once.

use std::io::{BufRead, Write};
use std::os::windows::io::AsRawHandle;
use std::os::windows::process::CommandExt;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, mpsc};
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use windows::Wdk::System::Threading::{NtQueryInformationProcess, ProcessBasicInformation};
use windows::Win32::Foundation::{CloseHandle, FILETIME, HANDLE};
use windows::Win32::Storage::FileSystem::{FILE_TYPE_PIPE, GetFileType};
use windows::Win32::System::Com::{COINIT_MULTITHREADED, CoInitializeEx};
use windows::Win32::System::Console::{GetStdHandle, STD_ERROR_HANDLE, STD_INPUT_HANDLE, SetConsoleCtrlHandler, SetStdHandle};
use windows::Win32::System::Threading::{
    GetCurrentProcess, GetProcessTimes, INFINITE, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE, WaitForSingleObject,
};
use windows::Win32::UI::HiDpi::{DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, SetProcessDpiAwarenessContext};
use windows::core::BOOL;

use crate::host::{self, APP_NAME, PROTOCOL};
use crate::{engine, gfx, guard, monitor, offscreen, pipe, setup};

const CREATE_NO_WINDOW: u32 = 0x0800_0000;
const CREATE_BREAKAWAY_FROM_JOB: u32 = 0x0100_0000;
const DETACHED_PROCESS: u32 = 0x0000_0008;

struct Options {
    owner: String,
    log_dir: Option<PathBuf>,
    parent_watch: bool,
    own_engine: bool,
    trusted: Vec<String>,
    /// The engine's: the relay that started it, and the host that started that.
    relay: Option<u32>,
    host: Option<u32>,
}

fn parse(args: &[String]) -> Result<Options, String> {
    let mut o = Options { owner: "Background Computer Use engine".into(), log_dir: None, parent_watch: true, own_engine: false, trusted: Vec::new(), relay: None, host: None };
    let mut i = 0;
    while i < args.len() {
        let value = args.get(i + 1);
        match (args[i].as_str(), value) {
            ("--owner", Some(v)) => o.owner = v.clone(),
            ("--log-dir", Some(v)) => o.log_dir = Some(PathBuf::from(v)),
            // A client the Mac's signature check would refuse. Windows has no
            // such check: every process of this user may use the pipe.
            ("--trust-client", Some(v)) => o.trusted.push(v.clone()),
            ("--relay", Some(v)) => o.relay = v.parse().ok(),
            ("--host-pid", Some(v)) => o.host = v.parse().ok(),
            ("--no-parent-watch", _) => {
                o.parent_watch = false;
                i += 1;
                continue;
            }
            ("--own-engine", _) => {
                o.own_engine = true;
                i += 1;
                continue;
            }
            (other, _) => return Err(format!("unknown option {other}")),
        }
        i += 2;
    }
    Ok(o)
}

fn emit(v: Value) {
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{v}");
    let _ = out.flush();
}

/// `bcu serve`: say which engine to use, starting one if none runs.
pub fn run(args: &[String]) -> i32 {
    let o = match parse(args) {
        Ok(o) => o,
        Err(e) => {
            emit(json!({"event": "error", "error": e}));
            return 64;
        }
    };
    if let Some(info) = running_engine() {
        emit_running(&info);
        return 0;
    }
    if !o.own_engine
        && let Some(app) = usable_app()
    {
        if start_app(&app)
            && let Some(info) = wait_for_engine(Duration::from_secs(20))
        {
            emit_running(&info);
            return 0;
        }
        eprintln!("{APP_NAME} didn't start its engine; running one for {}", o.owner);
    }
    let Ok(exe) = std::env::current_exe() else {
        emit(json!({"event": "error", "error": "can't find bcu.exe"}));
        return 1;
    };
    let mut cmd = std::process::Command::new(exe);
    cmd.arg("serve-engine").args(args).arg("--relay").arg(std::process::id().to_string());
    if let Some(host) = parent_pid() {
        cmd.arg("--host-pid").arg(host.to_string());
    }
    // Out of the job Node put this process in. With a job that doesn't allow
    // that, in it: the engine still stops when the host asks.
    let child = cmd.creation_flags(CREATE_NO_WINDOW | CREATE_BREAKAWAY_FROM_JOB).spawn().or_else(|_| cmd.creation_flags(CREATE_NO_WINDOW).spawn());
    match child {
        Ok(mut c) => c.wait().ok().and_then(|s| s.code()).unwrap_or(1),
        Err(e) => {
            emit(json!({"event": "error", "error": format!("couldn't start the engine: {e}")}));
            1
        }
    }
}

/// `bcu serve-engine`, started by `run`: the engine itself.
pub fn run_engine(args: &[String]) -> i32 {
    let o = match parse(args) {
        Ok(o) => o,
        Err(e) => {
            emit(json!({"event": "error", "error": e}));
            return 64;
        }
    };
    if let Some(dir) = &o.log_dir {
        log_to(dir);
    }
    unsafe {
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
    }
    host::configure(&o.owner, false);
    if !o.trusted.is_empty() {
        eprintln!("--trust-client has no effect on Windows: every process of this user may use the pipe");
    }
    // The pipe first: holding it is what makes this the one engine, so
    // nothing else (the guard, the window hooks) starts until it does.
    let (tx, rx) = mpsc::channel();
    {
        let tx = tx.clone();
        std::thread::Builder::new()
            .name("pipe".into())
            .spawn(move || {
                let listening = tx.clone();
                let result = pipe::serve_then(move || {
                    let _ = listening.send(Ok(()));
                });
                let _ = tx.send(result);
            })
            .expect("pipe thread");
    }
    match rx.recv_timeout(Duration::from_secs(10)) {
        Ok(Ok(())) => {}
        other => {
            // Another engine got there first.
            if let Some(info) = running_engine() {
                emit_running(&info);
                return 0;
            }
            let why = match other {
                Ok(Err(e)) => e,
                _ => "the pipe didn't come up".into(),
            };
            emit(json!({"event": "error", "error": why}));
            return 1;
        }
    }
    offscreen::start();
    guard::start();
    gfx::startup();
    // The agent screen, as the user wants it. Calls wait for this.
    std::thread::spawn(|| {
        setup::start_screen();
        monitor::set_ready();
    });
    eprintln!("engine started for {}, version {}", o.owner, host::version());
    emit(json!({
        "event": "ready", "socket": pipe::pipe_name(), "pid": std::process::id(), "version": host::version(),
        "protocol": PROTOCOL, "owner": o.owner,
    }));

    let (stop, stopping) = mpsc::channel::<String>();
    watch_stdin(stop.clone());
    watch_console(stop.clone());
    if o.parent_watch {
        for (pid, what) in [(o.relay, "bcu serve"), (o.host, "the app that started it")] {
            if let Some(pid) = pid {
                watch_process(pid, what, stop.clone());
            }
        }
    }
    // Asked to step aside: once no agent is working.
    let yielded = stop.clone();
    std::thread::spawn(move || {
        loop {
            std::thread::sleep(Duration::from_secs(1));
            if host::yielding() && host::agents_idle() {
                let _ = yielded.send(format!("yielded to {APP_NAME}"));
                return;
            }
        }
    });
    let why = stopping.recv().unwrap_or_else(|_| "no reason".into());
    eprintln!("engine stopping: {why}");
    engine::stop_for_quit(Duration::from_secs(10));
    STOPPED.store(true, Ordering::SeqCst);
    eprintln!("engine stopped");
    std::process::exit(0);
}

/// The engine has released the agents' windows.
static STOPPED: AtomicBool = AtomicBool::new(false);

fn log_to(dir: &PathBuf) {
    let _ = std::fs::create_dir_all(dir);
    if let Ok(f) = std::fs::OpenOptions::new().create(true).append(true).open(dir.join("engine.log")) {
        unsafe {
            let _ = SetStdHandle(STD_ERROR_HANDLE, HANDLE(f.as_raw_handle()));
        }
        // Stays open for as long as the process.
        std::mem::forget(f);
    }
}

/// `quit` on stdin, or stdin closing: the host is done with the engine. Only
/// when stdin is a pipe from the host (not the console, or nothing).
fn watch_stdin(stop: mpsc::Sender<String>) {
    let is_pipe = unsafe { GetStdHandle(STD_INPUT_HANDLE).is_ok_and(|h| !h.is_invalid() && GetFileType(h) == FILE_TYPE_PIPE) };
    if !is_pipe {
        return;
    }
    std::thread::spawn(move || {
        for line in std::io::stdin().lock().lines() {
            match line {
                Ok(l) if l.trim() == "quit" => {
                    let _ = stop.send("asked to quit".into());
                    return;
                }
                Ok(_) => {}
                Err(_) => break,
            }
        }
        let _ = stop.send("the app that started it closed stdin".into());
    });
}

static CONSOLE: Mutex<Option<mpsc::Sender<String>>> = Mutex::new(None);

/// Ctrl+C, Ctrl+Break, the console closing, signing out: stop as for `quit`.
fn watch_console(stop: mpsc::Sender<String>) {
    unsafe extern "system" fn on_event(kind: u32) -> BOOL {
        if let Some(tx) = CONSOLE.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
            let _ = tx.send(format!("console event {kind}"));
        }
        // Windows ends the process once this returns from a close, sign-out or
        // shutdown event: give the windows back first.
        if kind >= 2 {
            let t = Instant::now();
            while !STOPPED.load(Ordering::SeqCst) && t.elapsed() < Duration::from_millis(4500) {
                std::thread::sleep(Duration::from_millis(50));
            }
        }
        true.into()
    }
    *CONSOLE.lock().unwrap_or_else(|e| e.into_inner()) = Some(stop);
    unsafe {
        let _ = SetConsoleCtrlHandler(Some(on_event), true);
    }
}

fn filetime(t: FILETIME) -> u64 {
    ((t.dwHighDateTime as u64) << 32) | t.dwLowDateTime as u64
}

fn created(process: HANDLE) -> Option<u64> {
    let (mut c, mut e, mut k, mut u) = (FILETIME::default(), FILETIME::default(), FILETIME::default(), FILETIME::default());
    unsafe { GetProcessTimes(process, &mut c, &mut e, &mut k, &mut u).ok()? };
    Some(filetime(c))
}

/// Stop when process `pid` exits.
fn watch_process(pid: u32, what: &'static str, stop: mpsc::Sender<String>) {
    let Ok(h) = (unsafe { OpenProcess(PROCESS_SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, false, pid) }) else {
        let _ = stop.send(format!("{what} is gone"));
        return;
    };
    // A pid is reused once its process is gone: one that started after this
    // one isn't the one that started it.
    if let (Some(theirs), Some(ours)) = (created(h), created(unsafe { GetCurrentProcess() }))
        && theirs > ours
    {
        unsafe {
            let _ = CloseHandle(h);
        }
        let _ = stop.send(format!("{what} is gone"));
        return;
    }
    let raw = h.0 as usize;
    std::thread::spawn(move || {
        let h = HANDLE(raw as *mut _);
        unsafe {
            WaitForSingleObject(h, INFINITE);
            let _ = CloseHandle(h);
        }
        let _ = stop.send(format!("{what} quit"));
    });
}

/// The process that started this one.
fn parent_pid() -> Option<u32> {
    #[repr(C)]
    struct Basic {
        exit_status: i32,
        peb: usize,
        affinity: usize,
        base_priority: i32,
        pid: usize,
        parent: usize,
    }
    let mut info = Basic { exit_status: 0, peb: 0, affinity: 0, base_priority: 0, pid: 0, parent: 0 };
    let mut len = 0u32;
    let status = unsafe {
        NtQueryInformationProcess(GetCurrentProcess(), ProcessBasicInformation, &mut info as *mut _ as *mut _, size_of::<Basic>() as u32, &mut len)
    };
    (status.0 >= 0 && info.parent != 0).then_some(info.parent as u32)
}

// ---------- the engine that's running ----------

/// The engine serving the pipe, as `hello` describes it, if one is.
pub fn running_engine() -> Option<Value> {
    if !pipe::engine_running() {
        return None;
    }
    match pipe::request(&json!({"id": 1, "op": "hello"}), Duration::from_secs(5)) {
        Ok(v) if v["ok"] == json!(true) => Some(v["engine"].clone()),
        // The tray app from before hosts could use its engine.
        _ => Some(json!({"owner": APP_NAME, "shows_hosts": true})),
    }
}

fn emit_running(info: &Value) {
    let mut o = json!({"event": "running", "socket": pipe::pipe_name(), "owner": info.get("owner").cloned().unwrap_or(json!(APP_NAME))});
    for k in ["pid", "version", "protocol"] {
        if let Some(v) = info.get(k) {
            o[k] = v.clone();
        }
    }
    emit(o);
}

fn wait_for_engine(limit: Duration) -> Option<Value> {
    let t = Instant::now();
    while t.elapsed() < limit {
        if let Some(info) = running_engine() {
            return Some(info);
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    None
}

/// At the tray app's start, before it starts anything: another engine may
/// be running. Another copy of the app's: false, and this copy exits. A host
/// app's (`bcu serve`): ask it to step aside, and wait until it has, while
/// its agents finish.
pub fn wait_turn() -> bool {
    let Some(info) = running_engine() else { return true };
    if info.get("shows_hosts") == Some(&json!(true)) {
        return false;
    }
    eprintln!("{} runs the engine; asking it to step aside", info["owner"].as_str().unwrap_or("a host app"));
    let mut asked = None::<Instant>;
    loop {
        // Again now and then: the host may have started a new engine meanwhile.
        if asked.is_none_or(|t| t.elapsed() > Duration::from_secs(10)) {
            let _ = pipe::request(&json!({"id": 1, "op": "yield"}), Duration::from_secs(5));
            asked = Some(Instant::now());
        }
        std::thread::sleep(Duration::from_millis(300));
        match running_engine() {
            None => return true,
            Some(i) if i.get("shows_hosts") == Some(&json!(true)) => return false,
            Some(_) => {}
        }
    }
}

// ---------- the tray app's record, for hosts ----------

fn record_path() -> PathBuf {
    std::env::var_os("APPDATA").map(PathBuf::from).unwrap_or_default().join("BackgroundComputerUse").join("app.json")
}

/// Where the tray app is and which protocol it speaks, so a host's `bcu
/// serve` can start it instead of running an engine of its own. The tray app
/// writes this once it serves the pipe.
pub fn write_app_record() {
    let Ok(exe) = std::env::current_exe() else { return };
    let record = json!({"path": exe.to_string_lossy(), "version": host::version(), "protocol": PROTOCOL});
    let path = record_path();
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let _ = std::fs::write(path, record.to_string());
}

/// The tray app, when it's installed, set up (the onboarding is done and the
/// agent screen's driver is there) and speaks this protocol.
fn usable_app() -> Option<PathBuf> {
    let record: Value = serde_json::from_str(&std::fs::read_to_string(record_path()).ok()?).ok()?;
    let path = PathBuf::from(record["path"].as_str()?);
    (path.exists() && record["protocol"].as_u64() == Some(PROTOCOL) && setup::onboarded() && monitor::driver_installed()).then_some(path)
}

fn start_app(path: &PathBuf) -> bool {
    // Not in the job Node put this process in: the app outlives the host.
    // And not on this process's stdout, which is the host's.
    let mut cmd = std::process::Command::new(path);
    cmd.stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null());
    cmd.creation_flags(DETACHED_PROCESS | CREATE_BREAKAWAY_FROM_JOB).spawn().or_else(|_| cmd.creation_flags(DETACHED_PROCESS).spawn()).is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(s: &str) -> Vec<String> {
        s.split_whitespace().map(String::from).collect()
    }

    #[test]
    fn options() {
        let o = parse(&args("--owner Ping --log-dir C:\\logs --trust-client C:\\a.exe --own-engine --relay 12 --host-pid 34")).unwrap();
        assert_eq!(o.owner, "Ping");
        assert_eq!(o.log_dir, Some(PathBuf::from("C:\\logs")));
        assert_eq!(o.trusted, vec!["C:\\a.exe"]);
        assert!(o.own_engine && o.parent_watch);
        assert_eq!((o.relay, o.host), (Some(12), Some(34)));
        assert!(!parse(&args("--no-parent-watch")).unwrap().parent_watch);
        assert!(parse(&args("--bogus")).is_err());
        assert!(parse(&args("--owner")).is_err());
    }
}
