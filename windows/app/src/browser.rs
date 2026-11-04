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
