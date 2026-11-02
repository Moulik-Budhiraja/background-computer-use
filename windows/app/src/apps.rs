//! Finding apps and opening their windows on the agent monitor.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use windows::Win32::Foundation::{HWND, RECT};
use windows::Win32::System::Com::{CLSCTX_INPROC_SERVER, CoCreateInstance};
use windows::Win32::System::Registry::{HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, RRF_RT_REG_SZ, RegGetValueW};
use windows::Win32::UI::Shell::{ITaskbarList, SEE_MASK_FLAG_NO_UI, SEE_MASK_NOASYNC, SHELLEXECUTEINFOW, ShellExecuteExW, TaskbarList};
use windows::Win32::UI::WindowsAndMessaging::{SW_SHOWNOACTIVATE, SWP_NOACTIVATE, SWP_NOZORDER, SetWindowPos};
use windows::core::{HSTRING, PCWSTR};

use crate::{guard, win};

/// An app the agent asked for, resolved to something we can launch and match windows against.
pub struct App {
    /// What to pass to ShellExecute: an exe path, a shortcut, or a bare name.
    pub launch: String,
    /// Lowercase executable file name ("msedge.exe"), when known, to tell its windows apart.
    pub exe: Option<String>,
    pub name: String,
}

fn exe_file(path: &str) -> String {
    Path::new(path).file_name().map(|f| f.to_string_lossy().to_lowercase()).unwrap_or_default()
}

fn stem(s: &str) -> String {
    s.to_lowercase().trim_end_matches(".exe").trim_end_matches(".lnk").to_string()
}

fn app_path(name: &str) -> Option<String> {
    let key = HSTRING::from(format!(r"Software\Microsoft\Windows\CurrentVersion\App Paths\{}.exe", stem(name)));
    for root in [HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE] {
        let mut buf = [0u16; 1024];
        let mut len = (buf.len() * 2) as u32;
        let ok = unsafe { RegGetValueW(root, &key, PCWSTR::null(), RRF_RT_REG_SZ, None, Some(buf.as_mut_ptr() as *mut _), Some(&mut len)) };
        if ok.is_ok() {
            let s = String::from_utf16_lossy(&buf[..(len as usize / 2).saturating_sub(1)]);
            return Some(s.trim_matches('"').to_string());
        }
    }
    None
}

fn start_menu_shortcut(name: &str) -> Option<PathBuf> {
    let wanted = stem(name);
    let roots = [
        std::env::var_os("APPDATA").map(|a| PathBuf::from(a).join(r"Microsoft\Windows\Start Menu\Programs")),
        std::env::var_os("ProgramData").map(|p| PathBuf::from(p).join(r"Microsoft\Windows\Start Menu\Programs")),
    ];
    fn walk(dir: &Path, wanted: &str, depth: usize) -> Option<PathBuf> {
        if depth > 4 {
            return None;
        }
        let entries = std::fs::read_dir(dir).ok()?;
        let mut subdirs = Vec::new();
        for e in entries.flatten() {
            let p = e.path();
            if p.is_dir() {
                subdirs.push(p);
            } else if p.extension().is_some_and(|x| x.eq_ignore_ascii_case("lnk")) && p.file_stem().is_some_and(|s| s.to_string_lossy().to_lowercase() == wanted) {
                return Some(p);
            }
        }
        subdirs.into_iter().find_map(|d| walk(&d, wanted, depth + 1))
    }
    roots.into_iter().flatten().find_map(|r| walk(&r, &wanted, 0))
}

/// Resolve "Helium", "Notepad", "notepad.exe" or a full path.
pub fn resolve(name: &str) -> Result<App, String> {
    let wanted = stem(name);
    if Path::new(name).is_absolute() && Path::new(name).exists() {
        return Ok(App { launch: name.into(), exe: Some(exe_file(name)), name: win::app_name_from_exe(&exe_file(name)) });
    }
    if let Some((browser, exe)) = win::default_browser()
        && (stem(&browser) == wanted || stem(&exe_file(&exe)) == wanted || browser.to_lowercase().starts_with(&wanted))
    {
        return Ok(App { launch: exe.clone(), exe: Some(exe_file(&exe)), name: browser });
    }
    // A running app: launch its executable again.
    for hwnd in win::top_level_windows().into_iter().filter(|h| win::is_app_window(*h)) {
        let pid = win::pid_tid(hwnd).0;
        if let Some(path) = win::exe_path(pid)
            && (stem(&exe_file(&path)) == wanted || win::app_name(pid).to_lowercase() == wanted)
        {
            return Ok(App { launch: path.clone(), exe: Some(exe_file(&path)), name: win::app_name(pid) });
        }
    }
    if let Some(path) = app_path(name) {
        return Ok(App { exe: Some(exe_file(&path)), name: win::app_name_from_exe(&exe_file(&path)), launch: path });
    }
    if let Some(lnk) = start_menu_shortcut(name) {
        let display = lnk.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_else(|| name.into());
        return Ok(App { launch: lnk.to_string_lossy().into(), exe: None, name: display });
    }
    // Let the shell try (PATH, system apps like notepad).
    Ok(App { launch: name.into(), exe: Some(format!("{wanted}.exe")), name: name.into() })
}

fn launch(target: &str) -> Result<(), String> {
    let file = HSTRING::from(target);
    let mut info = SHELLEXECUTEINFOW {
        cbSize: size_of::<SHELLEXECUTEINFOW>() as u32,
        fMask: SEE_MASK_FLAG_NO_UI | SEE_MASK_NOASYNC,
        lpFile: PCWSTR(file.as_ptr()),
        nShow: SW_SHOWNOACTIVATE.0,
        ..Default::default()
    };
    unsafe { ShellExecuteExW(&mut info) }.map_err(|e| format!("couldn't start {target}: {e}"))
}

fn matches(app: &App, hwnd: HWND) -> bool {
    match &app.exe {
        Some(exe) => win::exe_name(win::pid_tid(hwnd).0).to_lowercase() == *exe,
        None => true,
    }
}

/// Where the n-th agent window goes on the monitor, keeping its size if it fits.
pub fn place(hwnd: HWND, monitor: RECT, n: usize) {
    let f = win::frame(hwnd);
    let mw = monitor.right - monitor.left;
    let mh = monitor.bottom - monitor.top;
    let w = (f.right - f.left).clamp(400, mw - 40);
    let h = (f.bottom - f.top).clamp(300, mh - 40);
    let step = (n % 6) as i32 * 30;
    let x = (monitor.left + 20 + step).min(monitor.right - w);
    let y = (monitor.top + 20 + step).min(monitor.bottom - h);
    unsafe {
        let _ = SetWindowPos(hwnd, None, x, y, w, h, SWP_NOZORDER | SWP_NOACTIVATE);
    }
}

fn on_monitor(hwnd: HWND, monitor: &RECT) -> bool {
    let f = win::frame(hwnd);
    f.left >= monitor.left - 8 && f.top >= monitor.top - 8 && f.right <= monitor.right + 8 && f.bottom <= monitor.bottom + 8
}

/// Remove the window's taskbar button, so the user doesn't see the agent's windows there.
pub fn hide_from_taskbar(hwnd: HWND) {
    unsafe {
        if let Ok(list) = CoCreateInstance::<_, ITaskbarList>(&TaskbarList, None, CLSCTX_INPROC_SERVER) {
            let _ = list.HrInit();
            let _ = list.DeleteTab(hwnd);
        }
    }
}

/// Put the window's taskbar button back (borrowed windows going home, handoffs).
pub fn show_in_taskbar(hwnd: HWND) {
    unsafe {
        if let Ok(list) = CoCreateInstance::<_, ITaskbarList>(&TaskbarList, None, CLSCTX_INPROC_SERVER) {
            let _ = list.HrInit();
            let _ = list.AddTab(hwnd);
        }
    }
}

/// Open a new window of `app` and move it to the agent monitor as soon as it shows.
/// Returns the window and notes on what happened.
pub fn open(app: &App, monitor: RECT, index: usize) -> Result<(HWND, Vec<String>), String> {
    let known: HashSet<usize> = win::top_level_windows().into_iter().map(|h| h.0 as usize).collect();
    let mut notes = Vec::new();
    let t = Instant::now();
    // Activations by the app's running process count as the agent's from now on.
    let running: Vec<u32> = win::top_level_windows()
        .into_iter()
        .filter(|h| win::is_app_window(*h) && matches(app, *h) && app.exe.is_some())
        .map(|h| win::pid_tid(h).0)
        .collect::<HashSet<_>>()
        .into_iter()
        .collect();
    for pid in &running {
        guard::begin_action(*pid);
    }
    let result = (|| {
        launch(&app.launch)?;
        let deadline = t + Duration::from_secs(15);
        let mut found: Option<(HWND, Instant)> = None;
        loop {
            if let Some((hwnd, since)) = found {
                // Chromium shows a new window and then resets its position: keep
                // putting it back for a moment.
                if !on_monitor(hwnd, &monitor) {
                    place(hwnd, monitor, index);
                }
                if since.elapsed() > Duration::from_millis(1500) {
                    return Ok(hwnd);
                }
            } else if Instant::now() > deadline {
                return Err(format!(
                    "{} didn't open a new window within 15 s. If it's a single-window app, use borrow_window with one of its windows from list_windows.",
                    app.name
                ));
            } else {
                for hwnd in win::top_level_windows() {
                    if known.contains(&(hwnd.0 as usize)) || !win::is_app_window(hwnd) || !matches(app, hwnd) {
                        continue;
                    }
                    guard::add_agent_window(hwnd);
                    let pid = win::pid_tid(hwnd).0;
                    guard::begin_action(pid);
                    let was_visible_at = win::frame(hwnd);
                    place(hwnd, monitor, index);
                    hide_from_taskbar(hwnd);
                    if win::foreground() == hwnd {
                        guard::give_back("a new window activated itself");
                    }
                    notes.push(format!(
                        "the window appeared after {:.0} ms at ({},{}) and was moved to your monitor",
                        t.elapsed().as_secs_f64() * 1000.0,
                        was_visible_at.left,
                        was_visible_at.top
                    ));
                    found = Some((hwnd, Instant::now()));
                    break;
                }
            }
            std::thread::sleep(Duration::from_millis(4));
        }
    })();
    for pid in &running {
        if let Some(n) = guard::end_action(*pid) {
            notes.push(n);
        }
    }
    if let Ok(hwnd) = &result
        && let Some(n) = guard::end_action(win::pid_tid(*hwnd).0)
    {
        notes.push(n);
    }
    result.map(|h| (h, notes))
}
