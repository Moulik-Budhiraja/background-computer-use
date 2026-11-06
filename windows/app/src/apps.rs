//! Finding apps and opening their windows on the agent monitor.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use windows::Win32::Foundation::{CloseHandle, HWND, RECT};
use windows::Win32::System::Com::{CLSCTX_INPROC_SERVER, CoCreateInstance, IPersistFile, STGM_READ};
use windows::Win32::System::Registry::{HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, RRF_RT_REG_SZ, RegGetValueW};
use windows::Win32::System::Threading::GetProcessId;
use windows::Win32::UI::Shell::{
    IShellLinkW, ITaskbarList, SEE_MASK_FLAG_NO_UI, SEE_MASK_NOASYNC, SEE_MASK_NOCLOSEPROCESS, SHELLEXECUTEINFOW, ShellExecuteExW, ShellLink, TaskbarList,
};
use windows::Win32::UI::WindowsAndMessaging::SW_SHOWNOACTIVATE;
use windows::core::{HSTRING, Interface, PCWSTR};

use crate::{guard, monitor, offscreen, win};

/// An app the agent asked for, resolved to something we can launch and match windows against.
pub struct App {
    /// What to pass to ShellExecute: an exe path, a shortcut, or a bare name.
    pub launch: String,
    /// Lowercase executable file name ("msedge.exe"), when known, to tell its windows apart.
    pub exe: Option<String>,
    /// The executable's full path, when known (for the browser checks).
    pub path: Option<String>,
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

/// A shortcut's target, when it's a program on disk.
fn shortcut_target(lnk: &Path) -> Option<String> {
    unsafe {
        let link: IShellLinkW = CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER).ok()?;
        link.cast::<IPersistFile>().ok()?.Load(&HSTRING::from(lnk.as_os_str()), STGM_READ).ok()?;
        let mut buf = [0u16; 1024];
        link.GetPath(&mut buf, std::ptr::null_mut(), 0).ok()?;
        let path = String::from_utf16_lossy(&buf[..buf.iter().position(|c| *c == 0).unwrap_or(0)]);
        (path.to_lowercase().ends_with(".exe") && Path::new(&path).exists()).then_some(path)
    }
}

fn exe_app(path: &str, name: String) -> App {
    App { launch: path.into(), exe: Some(exe_file(path)), path: Some(path.into()), name }
}

/// Resolve "Helium", "Notepad", "notepad.exe" or a full path.
pub fn resolve(name: &str) -> Result<App, String> {
    let wanted = stem(name);
    if Path::new(name).is_absolute() && Path::new(name).exists() {
        return Ok(exe_app(name, win::app_name_from_exe(&exe_file(name))));
    }
    if let Some((browser, exe)) = win::default_browser()
        && (stem(&browser) == wanted || stem(&exe_file(&exe)) == wanted || browser.to_lowercase().starts_with(&wanted))
    {
        return Ok(exe_app(&exe, browser));
    }
    // A running app: launch its executable again.
    for hwnd in win::top_level_windows().into_iter().filter(|h| win::is_app_window(*h)) {
        let pid = win::pid_tid(hwnd).0;
        if let Some(path) = win::exe_path(pid)
            && (stem(&exe_file(&path)) == wanted || win::app_name(pid).to_lowercase() == wanted)
        {
            return Ok(exe_app(&path, win::app_name(pid)));
        }
    }
    if let Some(path) = app_path(name) {
        return Ok(exe_app(&path, win::app_name_from_exe(&exe_file(&path))));
    }
    if let Some(lnk) = start_menu_shortcut(name) {
        let display = lnk.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_else(|| name.into());
        // Knowing the program tells its windows apart and catches them as
        // they open. A browser is started directly, so it can be given the
        // switch it may need (browser.rs); other apps through the shortcut,
        // which may carry arguments they need.
        return Ok(match shortcut_target(&lnk) {
            Some(path) if crate::browser::is_browser(&path) => exe_app(&path, display),
            Some(path) => App { launch: lnk.to_string_lossy().into(), exe: Some(exe_file(&path)), path: Some(path), name: display },
            None => App { launch: lnk.to_string_lossy().into(), exe: None, path: None, name: display },
        });
    }
    // Let the shell try (PATH, system apps like notepad).
    Ok(App { launch: name.into(), exe: Some(format!("{wanted}.exe")), path: None, name: name.into() })
}

/// Start `target`, with `args` if given. Returns the process it started, if
/// the shell says (not for apps it hands to a running process or a broker).
pub fn launch(target: &str, args: Option<&str>) -> Result<Option<u32>, String> {
    let file = HSTRING::from(target);
    let params = args.map(HSTRING::from);
    let mut info = SHELLEXECUTEINFOW {
        cbSize: size_of::<SHELLEXECUTEINFOW>() as u32,
        fMask: SEE_MASK_FLAG_NO_UI | SEE_MASK_NOASYNC | SEE_MASK_NOCLOSEPROCESS,
        lpFile: PCWSTR(file.as_ptr()),
        lpParameters: params.as_ref().map_or(PCWSTR::null(), |p| PCWSTR(p.as_ptr())),
        nShow: SW_SHOWNOACTIVATE.0,
        ..Default::default()
    };
    unsafe { ShellExecuteExW(&mut info) }.map_err(|e| format!("couldn't start {target}: {e}"))?;
    if info.hProcess.is_invalid() {
        return Ok(None);
    }
    let pid = unsafe { GetProcessId(info.hProcess) };
    unsafe {
        let _ = CloseHandle(info.hProcess);
    }
    Ok((pid != 0).then_some(pid))
}

fn matches(app: &App, hwnd: HWND) -> bool {
    match (&app.path, &app.exe) {
        // Helium and Chrome are both chrome.exe: compare paths when known.
        (Some(path), _) => win::exe_path(win::pid_tid(hwnd).0).is_some_and(|p| p.eq_ignore_ascii_case(path)),
        (None, Some(exe)) => win::exe_name(win::pid_tid(hwnd).0).to_lowercase() == *exe,
        (None, None) => true,
    }
}

/// Put the n-th agent window on the monitor, keeping its size if it fits.
/// A maximized window is restored into place, without activating it.
pub fn place(hwnd: HWND, monitor: RECT, n: usize) {
    bcu_hook::place(hwnd, monitor, n as u32, bcu_hook::From::Outside);
}

pub fn on_monitor(hwnd: HWND, monitor: &RECT) -> bool {
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

/// Open a new window of `app` on the agent monitor. `args` go to the app if
/// it starts now (a browser that isn't running yet). Returns the window and
/// notes on what happened.
///
/// The app's new windows are caught as it creates and shows them (see
/// offscreen.rs), so they don't show on the user's screen; the loop here
/// only finds which window is the agent's.
pub fn open(app: &App, monitor: RECT, index: usize, args: Option<&str>) -> Result<(HWND, Vec<String>), String> {
    let known: HashSet<usize> = win::top_level_windows().into_iter().map(|h| h.0 as usize).collect();
    let mut notes = Vec::new();
    let t = Instant::now();
    // Activations by the app's running process count as the agent's from now on.
    // Its running processes: any with a window, even hidden (a browser kept
    // running in the background shows none, and opens the new window).
    let running: Vec<u32> = win::top_level_windows()
        .into_iter()
        .filter(|h| app.exe.is_some() && matches(app, *h))
        .map(|h| win::pid_tid(h).0)
        .collect::<HashSet<_>>()
        .into_iter()
        .collect();
    for pid in &running {
        guard::begin_action(*pid);
    }
    let mut opening = offscreen::begin_open(&running, app.path.as_deref().or(app.exe.as_deref()), monitor, index);
    let result = (|| {
        if let Some(pid) = launch(&app.launch, args)? {
            opening.add_pid(pid);
        }
        let deadline = t + Duration::from_secs(15);
        let mut found: Option<(HWND, Instant)> = None;
        loop {
            if let Some((hwnd, since)) = found {
                // offscreen.rs keeps it on the monitor from here; this is a backstop.
                if !on_monitor(hwnd, &monitor) && !win::is_minimized(hwnd) {
                    place(hwnd, monitor, index);
                }
                if since.elapsed() > Duration::from_millis(500) {
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
                    guard::add_agent_window(hwnd, monitor, index);
                    let pid = win::pid_tid(hwnd).0;
                    guard::begin_action(pid);
                    let at = win::frame(hwnd);
                    if !on_monitor(hwnd, &monitor) {
                        place(hwnd, monitor, index);
                    }
                    hide_from_taskbar(hwnd);
                    if win::foreground() == hwnd {
                        guard::give_back("a new window activated itself");
                    }
                    let ms = t.elapsed().as_secs_f64() * 1000.0;
                    notes.push(if monitor::on_user_screen(&at) {
                        format!("the window appeared after {ms:.0} ms on the user's screen at ({},{}) and was moved to your monitor", at.left, at.top)
                    } else {
                        format!("the window opened on your monitor after {ms:.0} ms")
                    });
                    found = Some((hwnd, Instant::now()));
                    break;
                }
            }
            std::thread::sleep(Duration::from_millis(4));
        }
    })();
    drop(opening);
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
