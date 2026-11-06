//! Chromium browsers stop drawing a window they think nobody can see (their
//! "native window occlusion" check): one off every screen, or covered. On a
//! hidden screen that leaves the agent a blank window. Measured over Remote
//! Desktop: off screen, Edge drew no frames with the check on and ~32 a second
//! with it off.
//!
//! The `--disable-features=CalculateNativeWinOcclusion` switch turns the check
//! off, and every Chromium browser takes it when it starts. So on a hidden
//! screen the browser has to have been started with it: BCU passes it when it
//! starts the browser itself, and reads a running browser's command line to
//! see whether it has it. (The "Calculate window occlusion" flag in
//! edge://flags doesn't help: Edge 156 drops it from Local State at start and
//! keeps drawing nothing, and Chrome 156 doesn't have it.)

use std::path::Path;

use windows::Wdk::System::Threading::{NtQueryInformationProcess, PROCESSINFOCLASS};
use windows::Win32::Foundation::{CloseHandle, UNICODE_STRING};
use windows::Win32::System::Threading::{OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION};

use crate::win;

pub const SWITCH: &str = "--disable-features=CalculateNativeWinOcclusion";
const FEATURE: &str = "CalculateNativeWinOcclusion";

/// Whether `exe` is a Chromium browser: Chromium installs keep the exe in an
/// Application folder, next to a version folder holding <name>_elf.dll
/// (chrome_elf.dll, msedge_elf.dll).
pub fn is_chromium(exe: &str) -> bool {
    let Some(dir) = Path::new(exe).parent() else { return false };
    if !dir.file_name().is_some_and(|n| n.eq_ignore_ascii_case("Application")) {
        return false;
    }
    let has_elf = |version: &Path| {
        std::fs::read_dir(version).into_iter().flatten().flatten().any(|f| f.file_name().to_string_lossy().to_lowercase().ends_with("_elf.dll"))
    };
    std::fs::read_dir(dir).into_iter().flatten().flatten().any(|e| e.path().is_dir() && has_elf(&e.path()))
}

/// Whether `exe` is a web browser: a Chromium one, or Firefox.
pub fn is_browser(exe: &str) -> bool {
    is_chromium(exe) || Path::new(exe).file_name().is_some_and(|f| f.eq_ignore_ascii_case("firefox.exe"))
}

/// A process's command line (ProcessCommandLineInformation).
fn command_line(pid: u32) -> Option<String> {
    const PROCESS_COMMAND_LINE_INFORMATION: PROCESSINFOCLASS = PROCESSINFOCLASS(60);
    unsafe {
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let mut buf = vec![0u8; 64 * 1024];
        let mut len = 0u32;
        let status = NtQueryInformationProcess(process, PROCESS_COMMAND_LINE_INFORMATION, buf.as_mut_ptr() as *mut _, buf.len() as u32, &mut len);
        let _ = CloseHandle(process);
        if status.is_err() {
            return None;
        }
        let s = &*(buf.as_ptr() as *const UNICODE_STRING);
        Some(String::from_utf16_lossy(std::slice::from_raw_parts(s.Buffer.0, s.Length as usize / 2)))
    }
}

/// Processes of `exe` that have windows: the browser's own process, not its
/// renderers.
fn running(exe: &str) -> Vec<u32> {
    let mut pids: Vec<u32> = win::top_level_windows()
        .into_iter()
        .map(|h| win::pid_tid(h).0)
        .filter(|pid| win::exe_path(*pid).is_some_and(|p| p.eq_ignore_ascii_case(exe)))
        .collect();
    pids.sort_unstable();
    pids.dedup();
    pids
}

pub enum State {
    /// Running with the check off.
    Ready,
    /// Not running: start it with the switch.
    NotRunning,
    /// Running with the check on: it has to be quit and started again.
    NeedsRestart,
}

/// Whether the browser's windows will keep drawing on a hidden screen.
pub fn state(exe: &str) -> State {
    let pids = running(exe);
    if pids.is_empty() {
        State::NotRunning
    } else if pids.iter().any(|p| command_line(*p).is_some_and(|c| c.contains("--disable-features") && c.contains(FEATURE))) {
        State::Ready
    } else {
        State::NeedsRestart
    }
}

/// How a restart went, for the agent.
pub struct Restarted {
    pub windows_before: usize,
    pub windows_after: usize,
}

fn app_windows(exe: &str) -> usize {
    win::top_level_windows()
        .into_iter()
        .filter(|h| win::is_app_window(*h) && win::exe_path(win::pid_tid(*h).0).is_some_and(|p| p.eq_ignore_ascii_case(exe)))
        .count()
}

/// Quit the browser the way Windows does before an update (Restart
/// Manager's shutdown messages), so it saves its session and exits cleanly,
/// then start it again with the switch and `--restore-last-session`, which
/// brings back every window and tab. The user approves this first: it
/// restarts their browser in front of them and reloads its pages.
///
/// Measured with Edge 156 on a throwaway profile: shut down in 0.24 s, both
/// windows and every tab back, and no "restore pages?" prompt (it records a
/// clean exit).
pub fn restart(exe: &str, name: &str) -> Result<Restarted, String> {
    use windows::Win32::Foundation::{ERROR_SUCCESS, FILETIME};
    use windows::Win32::System::RestartManager::{CCH_RM_SESSION_KEY, RM_UNIQUE_PROCESS, RmEndSession, RmRegisterResources, RmShutdown, RmStartSession};
    use windows::Win32::System::Threading::GetProcessTimes;
    use windows::core::PWSTR;

    let pids = running(exe);
    let windows_before = app_windows(exe);
    let apps: Vec<RM_UNIQUE_PROCESS> = pids
        .iter()
        .filter_map(|pid| unsafe {
            let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, *pid).ok()?;
            let (mut start, mut exit, mut kernel, mut user) = (FILETIME::default(), FILETIME::default(), FILETIME::default(), FILETIME::default());
            let ok = GetProcessTimes(process, &mut start, &mut exit, &mut kernel, &mut user);
            let _ = CloseHandle(process);
            ok.ok()?;
            Some(RM_UNIQUE_PROCESS { dwProcessId: *pid, ProcessStartTime: start })
        })
        .collect();
    if !apps.is_empty() {
        let mut session = 0u32;
        let mut key = [0u16; CCH_RM_SESSION_KEY as usize + 1];
        unsafe {
            if RmStartSession(&mut session, None, PWSTR(key.as_mut_ptr())) != ERROR_SUCCESS {
                return Err(format!("couldn't ask {name} to quit (Restart Manager didn't start)"));
            }
            let registered = RmRegisterResources(session, None, Some(&apps), None);
            // Without the force flag: an app that refuses keeps running.
            let shut = if registered == ERROR_SUCCESS { RmShutdown(session, 0, None) } else { registered };
            let _ = RmEndSession(session);
            if shut != ERROR_SUCCESS {
                return Err(format!(
                    "{name} didn't quit (error {}). It may be asking the user something, like whether to leave a page. Ask the user to quit {name} themselves, then call open_window again.",
                    shut.0
                ));
            }
        }
    }
    let t = std::time::Instant::now();
    while !running(exe).is_empty() {
        if t.elapsed() > std::time::Duration::from_secs(15) {
            return Err(format!("{name} is still running 15 s after it was asked to quit. Ask the user to quit it, then call open_window again."));
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    let pid = crate::apps::launch(exe, Some(&format!("--restore-last-session {SWITCH}")))?;
    // The restored windows are the user's: if one takes the foreground, the
    // guard gives it back to the window the user was in.
    if let Some(pid) = pid {
        crate::guard::begin_action(pid);
    }
    let t = std::time::Instant::now();
    let mut windows_after = 0;
    while t.elapsed() < std::time::Duration::from_secs(15) {
        windows_after = app_windows(exe);
        if matches!(state(exe), State::Ready) && windows_after >= windows_before.max(1) {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    // Let the last restored window finish showing before the agent's opens.
    std::thread::sleep(std::time::Duration::from_millis(500));
    if let Some(pid) = pid {
        crate::guard::end_action(pid);
    }
    if !matches!(state(exe), State::Ready) {
        return Err(format!("{name} didn't start again with the setting. Ask the user to open {name}, then call open_window again."));
    }
    Ok(Restarted { windows_before, windows_after })
}
