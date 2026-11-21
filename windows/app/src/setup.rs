//! Setup: the first-run onboarding (onboarding.rs) and the settings behind
//! it: the agent screen, connecting Claude Code and Codex (`bcu connect`),
//! and starting at sign-in.
//!
//! The agent screen (monitor.rs) is where agents work. Turning it on installs
//! the Virtual Display Driver the first time (Windows asks for admin once),
//! sets it to one monitor at 30 Hz on the main screen's GPU, then checks the
//! compositor still keeps up, and turns it back off if not. Without it,
//! agents can't open windows, and `screen_problem` says why.

use std::os::windows::process::CommandExt;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

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

fn marker(name: &str) -> PathBuf {
    support_dir().join(name)
}

fn set_marker(name: &str, on: bool) {
    if on {
        let _ = std::fs::create_dir_all(support_dir());
        let _ = std::fs::write(marker(name), b"");
    } else {
        let _ = std::fs::remove_file(marker(name));
    }
}

/// The user finished (or closed) the onboarding once.
const ONBOARDED: &str = "onboarded";
/// The user turned the agent screen off.
const SCREEN_OFF: &str = "agent-screen-off";
/// The agent screen turned itself off because Windows slowed down; holds why.
const SCREEN_SLOW: &str = "agent-screen-slow";
const KEEP_DRAWING_DECLINED: &str = "keep-drawing-declined";

pub fn onboarded() -> bool {
    marker(ONBOARDED).exists()
}

pub fn set_onboarded() {
    set_marker(ONBOARDED, true);
}

/// Whether the agent screen should be on: not turned off by the user, or by
/// itself because it slowed the PC down.
pub fn screen_wanted() -> bool {
    !marker(SCREEN_OFF).exists() && !marker(SCREEN_SLOW).exists()
}

const REMOTE: &str = "this is a Remote Desktop session. The agent screen is a display of the computer itself, which Remote Desktop can't show, so agents can't open windows here; they can when the user is at the computer.";

/// Why agents have no screen right now, for the agent and the user. None
/// when it's on.
pub fn screen_problem() -> Option<String> {
    // Where the user sets the agent screen up: the tray app, or the host app
    // whose `bcu serve` runs the engine.
    let (set_up, turn_on) = match crate::host::host_app() {
        None => ("choose Set up… from the Background Computer Use tray icon".to_string(), "from the Background Computer Use tray icon (Agent screen)".to_string()),
        Some(app) => (format!("set up the agent screen in {app}"), format!("in {app}")),
    };
    if monitor::remote_session() {
        return Some(REMOTE.into());
    }
    if let Ok(why) = std::fs::read_to_string(marker(SCREEN_SLOW)) {
        return Some(format!("{} The user can turn it on again {turn_on}.", why.trim()));
    }
    if marker(SCREEN_OFF).exists() {
        return Some(format!("the user turned the agent screen off. They can turn it on {turn_on}."));
    }
    if BUSY.load(Ordering::SeqCst) {
        return Some("the agent screen is being set up. Try again in a minute.".into());
    }
    if !monitor::driver_installed() {
        return Some(format!("the agent screen isn't set up yet. Ask the user to {set_up}."));
    }
    if !monitor::driver_running() {
        return Some(format!(
            "the agent screen's driver is installed, but Windows didn't start it. Ask the user to {set_up}; restarting the PC can also help."
        ));
    }
    if !monitor::installed() {
        return Some(format!("the agent screen isn't on. Ask the user to {set_up}."));
    }
    None
}

/// At start: put the agent screen as it should be. An older version's
/// screens (0.1.21 had four at 60 Hz) are set up again the way this version
/// wants them, with the slowdown check. Without the driver, the onboarding
/// offers to set it up (`on_launch`).
pub fn start_screen() {
    if monitor::remote_session() {
        return;
    }
    if !screen_wanted() {
        monitor::apply_setting(false);
        return;
    }
    if !monitor::driver_installed() {
        return;
    }
    if !driver_settings_current() {
        let _ = enable_screen();
        return;
    }
    monitor::apply_setting(true);
}

/// Whether the task that keeps agents working after Remote Desktop
/// disconnects is there. Users can't query a SYSTEM task, so this checks for
/// its script, which install-monitor.ps1 writes once the task is registered.
pub fn keep_drawing_installed() -> bool {
    std::env::var_os("ProgramFiles").is_some_and(|p| PathBuf::from(p).join("Background Computer Use").join("keep-drawing.ps1").exists())
}

/// At start, once the screens are set up: the onboarding until it's done,
/// and over Remote Desktop, the offer of the task that keeps agents working
/// after a disconnect, once.
pub fn on_launch() {
    if !onboarded() {
        crate::tray::open_onboarding(false);
        return;
    }
    // Agents can't work without the agent screen: offer to set it up.
    if screen_wanted() && !monitor::remote_session() && !monitor::driver_installed() {
        crate::tray::open_onboarding(true);
        return;
    }
    if monitor::remote_session() && !marker(KEEP_DRAWING_DECLINED).exists() && !keep_drawing_installed() {
        std::thread::spawn(|| {
            let answer = unsafe {
                MessageBoxW(
                    None,
                    w!("Keep agents working after you disconnect?\n\nWhen Remote Desktop disconnects, Windows stops drawing your session, so agents can't see their windows. Background Computer Use can move your session to this computer's own screen and lock it there, so they keep working.\n\nWindows will ask for permission once."),
                    w!("Background Computer Use"),
                    MB_OKCANCEL | MB_ICONINFORMATION,
                )
            };
            if answer != IDOK {
                set_marker(KEEP_DRAWING_DECLINED, true);
            } else if !BUSY.swap(true, Ordering::SeqCst) {
                elevated("-Task");
                BUSY.store(false, Ordering::SeqCst);
            }
        });
    }
}

/// Set while something here runs that Windows asks admin for, so a second
/// click doesn't start it twice.
static BUSY: AtomicBool = AtomicBool::new(false);

pub fn busy() -> bool {
    BUSY.load(Ordering::SeqCst)
}

/// Add the MCP server and the skill to Claude Code and Codex. Returns what
/// `bcu connect` said, a line per step.
pub fn connect_agents() -> Vec<String> {
    match std::process::Command::new(exe_dir().join("bcu.exe")).arg("connect").creation_flags(CREATE_NO_WINDOW).output() {
        Ok(o) => String::from_utf8_lossy(&o.stdout).lines().map(str::to_string).filter(|l| !l.trim().is_empty()).collect(),
        Err(e) => vec![format!("couldn't run bcu.exe: {e}")],
    }
}

/// An agent this works with, and whether it's on this PC and connected.
#[derive(Clone, Copy)]
pub struct Agent {
    pub name: &'static str,
    pub found: bool,
    pub connected: bool,
}

const SERVER_NAME: &str = "background-computer-use";

/// Claude Code and Codex. Runs `claude --version`, so call it off the UI thread.
pub fn agents() -> [Agent; 2] {
    let home = std::env::var_os("USERPROFILE").map(PathBuf::from).unwrap_or_default();
    let claude = std::process::Command::new("cmd")
        .args(["/c", "claude", "--version"])
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .is_ok_and(|o| o.status.success());
    let has = |path: PathBuf, text: &str| std::fs::read_to_string(path).is_ok_and(|s| s.contains(text));
    [
        Agent { name: "Claude Code", found: claude, connected: claude && has(home.join(".claude.json"), &format!("\"{SERVER_NAME}\"")) },
        Agent {
            name: "Codex",
            found: home.join(".codex").exists(),
            connected: has(home.join(".codex").join("config.toml"), &format!("[mcp_servers.{SERVER_NAME}]")),
        },
    ]
}

/// The command another agent runs to use this: `"...cu.exe" mcp`.
pub fn mcp_command() -> String {
    format!("\"{}\" mcp", exe_dir().join("bcu.exe").display())
}

/// Put `text` on the clipboard.
pub fn copy_text(text: &str) -> bool {
    use windows::Win32::Foundation::{HANDLE, HGLOBAL};
    use windows::Win32::System::DataExchange::{CloseClipboard, EmptyClipboard, OpenClipboard, SetClipboardData};
    use windows::Win32::System::Memory::{GMEM_MOVEABLE, GlobalAlloc, GlobalLock, GlobalUnlock};
    const CF_UNICODETEXT: u32 = 13;
    let wide: Vec<u16> = text.encode_utf16().chain(std::iter::once(0)).collect();
    unsafe {
        if OpenClipboard(None).is_err() {
            return false;
        }
        let _ = EmptyClipboard();
        let ok = (|| {
            let mem: HGLOBAL = GlobalAlloc(GMEM_MOVEABLE, wide.len() * 2).ok()?;
            let p = GlobalLock(mem) as *mut u16;
            if p.is_null() {
                return None;
            }
            std::ptr::copy_nonoverlapping(wide.as_ptr(), p, wide.len());
            let _ = GlobalUnlock(mem);
            SetClipboardData(CF_UNICODETEXT, Some(HANDLE(mem.0))).ok()
        })()
        .is_some();
        let _ = CloseClipboard();
        ok
    }
}

/// Turn the agent screen on: install the driver the first time (Windows
/// asks for admin), set it to one monitor at 30 Hz on the main screen's GPU,
/// and check the compositor keeps up; if it doesn't, turn it off again and
/// remember why. Runs for a while (the admin prompt, the install, a few
/// seconds of measuring), so call it off the UI thread. Returns what
/// happened, for the user.
pub fn enable_screen() -> Result<String, String> {
    if BUSY.swap(true, Ordering::SeqCst) {
        return Err("Setup is already running.".into());
    }
    let result = enable_now();
    BUSY.store(false, Ordering::SeqCst);
    result
}

/// The user turned the agent screen off.
pub fn disable_screen() -> String {
    set_marker(SCREEN_OFF, true);
    monitor::apply_setting(false);
    "The agent screen is off. Agents can't open windows until it's on again.".into()
}

fn enable_now() -> Result<String, String> {
    if monitor::remote_session() {
        return Err(format!("The agent screen can't be turned on here: {REMOTE}"));
    }
    set_marker(SCREEN_OFF, false);
    set_marker(SCREEN_SLOW, false);
    // How fast the compositor presents without any agent screen (an older
    // version's may be on, and slowing things down), to compare with after.
    monitor::apply_setting(false);
    std::thread::sleep(Duration::from_secs(2));
    let before = monitor::frame_time(Duration::from_secs(3));
    write_driver_settings().map_err(|e| format!("Couldn't write the agent screen's settings: {e}"))?;
    if monitor::driver_installed() {
        // Pick up the settings (one monitor, 30 Hz, this GPU).
        monitor::driver_command("RELOAD_DRIVER");
        std::thread::sleep(Duration::from_secs(3));
    } else if !elevated("-Driver") {
        return Err("The agent screen's driver wasn't installed: Windows' permission prompt was declined, or the download failed. Nothing changed.".into());
    }
    monitor::apply_setting(true);
    if !monitor::installed() {
        monitor::apply_setting(false);
        return Err(if monitor::driver_running() {
            "The agent screen didn't come up. Try Set up… again.".into()
        } else {
            "Windows didn't start the agent screen's driver (Device Manager shows an error for Virtual Display Driver). Restarting the PC can help; then choose Set up… again.".into()
        });
    }
    // Let the display settle, then measure again.
    std::thread::sleep(Duration::from_secs(2));
    let after = monitor::frame_time(Duration::from_secs(5));
    if slowed(before, after) {
        monitor::apply_setting(false);
        let why = format!("the agent screen was turned off because Windows slowed down with it on (a frame took {after:.0} ms, {before:.0} ms without it).");
        let _ = std::fs::create_dir_all(support_dir());
        let _ = std::fs::write(marker(SCREEN_SLOW), &why);
        return Err(format!("The agent screen is off: {why} Agents can't open windows on this PC."));
    }
    Ok("The agent screen is on. Agents work there, out of your sight.".into())
}

/// Whether the compositor fell behind: frames take noticeably longer than
/// before, and longer than two refreshes of a 60 Hz screen.
fn slowed(before: f64, after: f64) -> bool {
    after > (before * 1.5).max(before + 8.0) && after > 34.0
}

const SETTINGS_DIR: &str = r"C:\VirtualDisplayDriver";

/// Whether the driver's settings are this version's (an older version's
/// asked for four monitors at 60 Hz on whichever GPU the driver picked).
fn driver_settings_current() -> bool {
    std::fs::read_to_string(PathBuf::from(SETTINGS_DIR).join("vdd_settings.xml")).is_ok_and(|s| s == driver_settings())
}

/// The driver reads its settings from C:\VirtualDisplayDriver, which any user
/// can write to.
fn write_driver_settings() -> std::io::Result<()> {
    let dir = PathBuf::from(SETTINGS_DIR);
    std::fs::create_dir_all(&dir)?;
    std::fs::write(dir.join("vdd_settings.xml"), driver_settings())
}

/// The driver's settings: one 1600x1000 monitor at 30 Hz, drawn on the
/// adapter that drives the user's main screen.
fn driver_settings() -> String {
    let gpu = render_adapter().unwrap_or_else(|| "default".into());
    format!(
        r#"<?xml version="1.0" encoding="utf-8"?>
<!-- Written by Background Computer Use. -->
<vdd_settings>
  <monitors><count>{count}</count></monitors>
  <gpu><friendlyname>{gpu}</friendlyname></gpu>
  <global><g_refresh_rate>{hz}</g_refresh_rate></global>
  <resolutions>
    <resolution><width>{w}</width><height>{h}</height><refresh_rate>{hz}</refresh_rate></resolution>
  </resolutions>
  <logging><SendLogsThroughPipe>true</SendLogsThroughPipe><logging>false</logging><debuglogging>false</debuglogging></logging>
  <colour><SDR10bit>false</SDR10bit><HDRPlus>false</HDRPlus><ColourFormat>RGB</ColourFormat></colour>
  <cursor><HardwareCursor>true</HardwareCursor><CursorMaxX>128</CursorMaxX><CursorMaxY>128</CursorMaxY><AlphaCursorSupport>true</AlphaCursorSupport><XorCursorSupportLevel>2</XorCursorSupportLevel></cursor>
  <edid><CustomEdid>false</CustomEdid><PreventSpoof>false</PreventSpoof><EdidCeaOverride>false</EdidCeaOverride></edid>
</vdd_settings>
"#,
        count = monitor::WANTED,
        gpu = xml_escape(&gpu),
        hz = monitor::REFRESH_HZ,
        w = monitor::WIDTH,
        h = monitor::HEIGHT,
    )
}

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

/// The GPU to draw the agent monitor on: the one driving the main screen,
/// if it's a GPU that renders (not a display-only adapter, like a VM's).
fn render_adapter() -> Option<String> {
    use windows::Win32::Graphics::Dxgi::{CreateDXGIFactory1, DXGI_ADAPTER_FLAG_SOFTWARE, IDXGIFactory1};
    let primary = monitor::primary_adapter()?;
    unsafe {
        let factory: IDXGIFactory1 = CreateDXGIFactory1().ok()?;
        let mut i = 0;
        while let Ok(adapter) = factory.EnumAdapters1(i) {
            i += 1;
            let Ok(desc) = adapter.GetDesc1() else { continue };
            if desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE.0 as u32 != 0 {
                continue;
            }
            let end = desc.Description.iter().position(|&c| c == 0).unwrap_or(desc.Description.len());
            if String::from_utf16_lossy(&desc.Description[..end]) == primary {
                return Some(primary);
            }
        }
    }
    None
}

/// install-monitor.ps1 with `args`, elevated: Windows shows its own admin
/// prompt. Returns whether it ran and succeeded.
fn elevated(args: &str) -> bool {
    let script = exe_dir().join("install-monitor.ps1");
    let params = HSTRING::from(format!("-NoProfile -ExecutionPolicy Bypass -File \"{}\" {args}", script.display()));
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
    } else {
        unsafe {
            let _ = RegDeleteKeyValueW(HKEY_CURRENT_USER, RUN_KEY, w!("BackgroundComputerUse"));
        }
    }
}

/// Where the installer puts the app, under %LOCALAPPDATA%\Programs.
const INSTALL_DIR_NAME: &str = "Background Computer Use";
const UNINSTALL_KEY: PCWSTR = w!(r"Software\Microsoft\Windows\CurrentVersion\Uninstall\BackgroundComputerUse");

/// Uninstall (from Settings > Apps): quit the running app, take any agent
/// monitor off the desktop, remove the shortcut, sign-in entry and uninstall
/// entry, then the app's folder once this process has exited. If the driver
/// or the keep-drawing task is installed, remove them too (Windows asks for
/// admin; skipped when silent).
pub fn uninstall(silent: bool) {
    if !silent {
        let answer = unsafe { MessageBoxW(None, w!("Uninstall Background Computer Use?"), w!("Background Computer Use"), MB_OKCANCEL | MB_ICONINFORMATION) };
        if answer != IDOK {
            return;
        }
    }
    quit_running();
    monitor::apply_setting(false);
    if !silent && (monitor::driver_installed() || keep_drawing_installed()) {
        elevated("-Remove");
    }
    set_start_at_sign_in(false);
    unsafe {
        let _ = windows::Win32::System::Registry::RegDeleteTreeW(HKEY_CURRENT_USER, UNINSTALL_KEY);
    }
    if let Some(start_menu) = std::env::var_os("APPDATA").map(PathBuf::from) {
        let _ = std::fs::remove_file(start_menu.join(r"Microsoft\Windows\Start Menu\Programs\Background Computer Use.lnk"));
    }
    let _ = std::fs::remove_dir_all(support_dir());
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

#[cfg(test)]
mod tests {
    use super::slowed;

    #[test]
    fn slowdown_needs_a_real_drop() {
        // 60 Hz, steady.
        assert!(!slowed(16.7, 16.8));
        // A little worse but still smooth.
        assert!(!slowed(16.7, 25.0));
        // Frames taking several refreshes: what an overloaded laptop showed.
        assert!(slowed(16.7, 60.0));
        // A machine that was already slow and stayed about the same.
        assert!(!slowed(40.0, 45.0));
        assert!(slowed(40.0, 80.0));
    }
}
