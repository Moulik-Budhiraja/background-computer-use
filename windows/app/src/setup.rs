//! First-run setup: install the virtual monitor's driver (needs admin, so
//! Windows asks), add the MCP server and the skill to Claude Code and Codex
//! (`bcu connect`), and start the app at sign-in.

use std::os::windows::process::CommandExt;
use std::path::PathBuf;

use windows::Win32::Foundation::{CloseHandle, WAIT_OBJECT_0};
use windows::Win32::System::Registry::{HKEY_CURRENT_USER, REG_SZ, RRF_RT_REG_SZ, RegDeleteKeyValueW, RegGetValueW, RegSetKeyValueW};
use windows::Win32::System::Threading::{GetExitCodeProcess, INFINITE, WaitForSingleObject};
use windows::Win32::UI::Shell::{SEE_MASK_NOCLOSEPROCESS, SHELLEXECUTEINFOW, ShellExecuteExW};
use windows::Win32::UI::WindowsAndMessaging::{IDOK, MB_ICONINFORMATION, MB_OKCANCEL, MessageBoxW, SW_HIDE};
use windows::core::{HSTRING, PCWSTR, w};

use crate::monitor;

const CREATE_NO_WINDOW: u32 = 0x0800_0000;

fn exe_dir() -> PathBuf {
    std::env::current_exe().ok().and_then(|p| p.parent().map(|d| d.to_path_buf())).unwrap_or_default()
}

fn support_dir() -> PathBuf {
    let base = std::env::var_os("APPDATA").map(PathBuf::from).unwrap_or_default();
    base.join("BackgroundComputerUse")
}

/// The user said "not now" once; don't ask again on every launch.
fn declined_marker() -> PathBuf {
    support_dir().join("setup-declined")
}

/// Ask on first launch if the monitor isn't there.
pub fn offer_on_launch() {
    if monitor::installed() || declined_marker().exists() {
        return;
    }
    std::thread::spawn(|| run(true));
}

/// Run setup. With `ask`, confirm first.
pub fn run(ask: bool) {
    if ask {
        let answer = unsafe {
            MessageBoxW(
                None,
                w!("Your agents get their own screen.\n\nThey do all their work in their own windows so they don't get in your way."),
                w!("Background Computer Use"),
                MB_OKCANCEL | MB_ICONINFORMATION,
            )
        };
        if answer != IDOK {
            let _ = std::fs::create_dir_all(support_dir());
            let _ = std::fs::write(declined_marker(), b"");
            return;
        }
    }
    let _ = std::fs::remove_file(declined_marker());
    if !monitor::installed() {
        install_monitor();
        monitor::ensure_count();
    }
    // bcu.exe lives next to the app.
    let _ = std::process::Command::new(exe_dir().join("bcu.exe")).arg("connect").creation_flags(CREATE_NO_WINDOW).status();
    start_at_sign_in();
}

/// install-monitor.ps1, elevated. Windows shows its own admin prompt.
fn install_monitor() -> bool {
    let script = exe_dir().join("install-monitor.ps1");
    let params = HSTRING::from(format!("-NoProfile -ExecutionPolicy Bypass -File \"{}\"", script.display()));
    let mut info = SHELLEXECUTEINFOW {
        cbSize: size_of::<SHELLEXECUTEINFOW>() as u32,
        fMask: SEE_MASK_NOCLOSEPROCESS,
        lpVerb: w!("runas"),
        lpFile: w!("powershell.exe"),
        lpParameters: PCWSTR(params.as_ptr()),
        nShow: SW_HIDE.0,
        ..Default::default()
    };
    unsafe {
        if ShellExecuteExW(&mut info).is_err() || info.hProcess.is_invalid() {
            return false;
        }
        let ok = WaitForSingleObject(info.hProcess, INFINITE) == WAIT_OBJECT_0;
        let mut code = 1u32;
        let _ = GetExitCodeProcess(info.hProcess, &mut code);
        let _ = CloseHandle(info.hProcess);
        ok && code == 0
    }
}

const RUN_KEY: PCWSTR = w!(r"Software\Microsoft\Windows\CurrentVersion\Run");

/// Whether the app starts when the user signs in.
pub fn starts_at_sign_in() -> bool {
    let mut n = 0u32;
    unsafe { RegGetValueW(HKEY_CURRENT_USER, RUN_KEY, w!("BackgroundComputerUse"), RRF_RT_REG_SZ, None, None, Some(&mut n)).is_ok() }
}

pub fn set_start_at_sign_in(on: bool) {
    if on {
        start_at_sign_in();
    } else {
        unsafe {
            let _ = RegDeleteKeyValueW(HKEY_CURRENT_USER, RUN_KEY, w!("BackgroundComputerUse"));
        }
    }
}

fn start_at_sign_in() {
    let Ok(exe) = std::env::current_exe() else { return };
    let value: Vec<u16> = format!("\"{}\"", exe.display()).encode_utf16().chain(std::iter::once(0)).collect();
    unsafe {
        let _ = RegSetKeyValueW(
            HKEY_CURRENT_USER,
            RUN_KEY,
            w!("BackgroundComputerUse"),
            REG_SZ.0,
            Some(value.as_ptr() as *const _),
            (value.len() * 2) as u32,
        );
    }
}

/// Where the installer puts the app, under %LOCALAPPDATA%\Programs.
const INSTALL_DIR_NAME: &str = "Background Computer Use";
const UNINSTALL_KEY: PCWSTR = w!(r"Software\Microsoft\Windows\CurrentVersion\Uninstall\BackgroundComputerUse");

/// Uninstall (from Settings > Apps): quit the running app, remove the
/// shortcut, sign-in entry and uninstall entry, then the app's folder once
/// this process has exited. The agent monitors' driver stays installed.
pub fn uninstall(silent: bool) {
    if !silent {
        let answer = unsafe { MessageBoxW(None, w!("Uninstall Background Computer Use?"), w!("Background Computer Use"), MB_OKCANCEL | MB_ICONINFORMATION) };
        if answer != IDOK {
            return;
        }
    }
    quit_running();
    set_start_at_sign_in(false);
    unsafe {
        let _ = windows::Win32::System::Registry::RegDeleteTreeW(HKEY_CURRENT_USER, UNINSTALL_KEY);
    }
    if let Some(start_menu) = std::env::var_os("APPDATA").map(PathBuf::from) {
        let _ = std::fs::remove_file(start_menu.join(r"Microsoft\Windows\Start Menu\Programs\Background Computer Use.lnk"));
    }
    let dir = exe_dir();
    // Only the installed copy deletes its folder.
    if dir.file_name().is_some_and(|n| n == INSTALL_DIR_NAME) {
        const DETACHED_PROCESS: u32 = 0x0000_0008;
        let _ = std::process::Command::new("cmd")
            .raw_arg(format!("/c ping -n 3 127.0.0.1 >nul & rmdir /s /q \"{}\"", dir.display()))
            .creation_flags(CREATE_NO_WINDOW | DETACHED_PROCESS)
            .current_dir(std::env::temp_dir())
            .spawn();
    }
}

/// Ask another running copy of the app to quit, and wait for it (10 s at most).
fn quit_running() {
    use windows::Win32::System::Threading::{OpenProcess, PROCESS_SYNCHRONIZE, PROCESS_TERMINATE, TerminateProcess};
    use windows::Win32::UI::WindowsAndMessaging::{FindWindowW, GetWindowThreadProcessId, PostMessageW, WM_CLOSE};
    unsafe {
        let Ok(hwnd) = FindWindowW(w!("BackgroundComputerUseTray"), PCWSTR::null()) else { return };
        let mut pid = 0u32;
        GetWindowThreadProcessId(hwnd, Some(&mut pid));
        if pid == std::process::id() {
            return;
        }
        let process = OpenProcess(PROCESS_SYNCHRONIZE | PROCESS_TERMINATE, false, pid).ok();
        let _ = PostMessageW(Some(hwnd), WM_CLOSE, Default::default(), Default::default());
        if let Some(p) = process {
            if WaitForSingleObject(p, 10_000) != WAIT_OBJECT_0 {
                let _ = TerminateProcess(p, 0);
            }
            let _ = CloseHandle(p);
        }
    }
}
