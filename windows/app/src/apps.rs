//! Finding apps and opening their windows on the agent monitor.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use windows::Win32::Foundation::{CloseHandle, HWND, RECT};
use windows::Win32::System::Com::{CLSCTX_INPROC_SERVER, CLSCTX_LOCAL_SERVER, CoCreateInstance, CoTaskMemFree, IPersistFile, STGM_READ};
use windows::Win32::System::Registry::{HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, RRF_RT_REG_SZ, RegGetValueW};
use windows::Win32::System::Threading::GetProcessId;
use windows::Win32::UI::Shell::{
    AO_NOERRORUI, ApplicationActivationManager, BHID_EnumItems, FOLDERID_AppsFolder, IApplicationActivationManager, IEnumShellItems, IShellItem, IShellLinkW,
    ITaskbarList, KF_FLAG_DEFAULT, SEE_MASK_FLAG_NO_UI, SEE_MASK_NOASYNC, SEE_MASK_NOCLOSEPROCESS, SHELLEXECUTEINFOW, SHGetKnownFolderItem, SIGDN_NORMALDISPLAY,
    SIGDN_PARENTRELATIVEPARSING, ShellExecuteExW, ShellLink, TaskbarList,
};
use windows::Win32::UI::WindowsAndMessaging::{
    GA_ROOTOWNER, GetAncestor, GetWindowPlacement, GetWindowRect, SPI_GETWORKAREA, SW_MINIMIZE, SW_SHOWMAXIMIZED, SW_SHOWMINIMIZED, SW_SHOWMINNOACTIVE,
    SW_SHOWNOACTIVATE, SWP_NOACTIVATE, SWP_NOSIZE, SWP_NOZORDER, SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS, SetWindowPlacement, SetWindowPos, SystemParametersInfoW,
    WINDOWPLACEMENT, WINDOWPLACEMENT_FLAGS,
};
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
    /// A packaged (Store) app's AppUserModelID, launched through the shell's
    /// activation manager, which says which process it started.
    pub aumid: Option<String>,
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
    App { launch: path.into(), exe: Some(exe_file(path)), path: Some(path.into()), name, aumid: None }
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
        // they open. A browser is started directly; other apps through the
        // shortcut, which may carry arguments they need.
        return Ok(match shortcut_target(&lnk) {
            Some(path) if crate::browser::is_browser(&path) => exe_app(&path, display),
            Some(path) => App { launch: lnk.to_string_lossy().into(), exe: Some(exe_file(&path)), path: Some(path), name: display, aumid: None },
            None => App { launch: lnk.to_string_lossy().into(), exe: None, path: None, name: display, aumid: None },
        });
    }
    // A packaged app (Calculator) has no program the shell can start by name.
    if !on_path(&format!("{wanted}.exe"))
        && let Some((aumid, display)) = packaged_app(&wanted)
    {
        return Ok(App { launch: format!(r"shell:AppsFolder\{aumid}"), exe: None, path: None, name: display, aumid: Some(aumid) });
    }
    // Let the shell try (PATH, system apps like notepad).
    Ok(App { launch: name.into(), exe: Some(format!("{wanted}.exe")), path: None, name: name.into(), aumid: None })
}

fn on_path(file: &str) -> bool {
    std::env::var_os("PATH").is_some_and(|p| std::env::split_paths(&p).any(|d| d.join(file).is_file()))
}

/// A packaged app by its Start menu name (lowercase): its AppUserModelID
/// and display name, from shell:AppsFolder.
fn packaged_app(wanted: &str) -> Option<(String, String)> {
    unsafe {
        let folder: IShellItem = SHGetKnownFolderItem(&FOLDERID_AppsFolder, KF_FLAG_DEFAULT, None).ok()?;
        let items: IEnumShellItems = folder.BindToHandler(None, &BHID_EnumItems).ok()?;
        let name = |item: &IShellItem, kind| {
            let p = item.GetDisplayName(kind).ok()?;
            let s = p.to_string().ok();
            CoTaskMemFree(Some(p.0 as *const _));
            s
        };
        loop {
            let mut batch = [None];
            let mut fetched = 0u32;
            if items.Next(&mut batch, Some(&mut fetched)).is_err() || fetched == 0 {
                return None;
            }
            let Some(item) = batch[0].take() else { return None };
            if name(&item, SIGDN_NORMALDISPLAY).is_some_and(|d| d.to_lowercase() == wanted)
                // Packaged apps' ids are "PackageFamilyName!App"; others are paths.
                && let Some(id) = name(&item, SIGDN_PARENTRELATIVEPARSING).filter(|id| id.contains('!'))
            {
                let display = name(&item, SIGDN_NORMALDISPLAY).unwrap_or_else(|| wanted.into());
                return Some((id, display));
            }
        }
    }
}

/// Start a packaged app. Returns the process it started (or the running one it activated).
fn activate(aumid: &str) -> Result<u32, String> {
    unsafe {
        let manager: IApplicationActivationManager =
            CoCreateInstance(&ApplicationActivationManager, None, CLSCTX_LOCAL_SERVER).map_err(|e| format!("couldn't start {aumid}: {e}"))?;
        manager.ActivateApplication(&HSTRING::from(aumid), &HSTRING::new(), AO_NOERRORUI).map_err(|e| format!("couldn't start {aumid}: {e}"))
    }
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

/// Whether `hwnd` is a window of `app`. With no program to compare (a
/// packaged app, a shortcut to something that isn't an exe), only windows of
/// the processes the launch started, and of their children, count; a UWP
/// app's frame belongs to ApplicationFrameHost.exe and holds the app's window.
fn matches(app: &App, hwnd: HWND, launched: &[u32]) -> bool {
    let pid = win::pid_tid(hwnd).0;
    match (&app.path, &app.exe) {
        // Helium and Chrome are both chrome.exe: compare paths when known.
        (Some(path), _) => win::exe_path(pid).is_some_and(|p| p.eq_ignore_ascii_case(path)),
        (None, Some(exe)) => win::exe_name(pid).to_lowercase() == *exe,
        (None, None) if launched.is_empty() => false,
        (None, None) => {
            let parents = win::parents();
            win::descends_from(pid, launched, &parents)
                || (win::exe_name(pid).eq_ignore_ascii_case("applicationframehost.exe")
                    && win::child_pids(hwnd).iter().any(|c| win::descends_from(*c, launched, &parents)))
        }
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

/// The primary monitor's work area (without the taskbar).
fn primary_work_area() -> RECT {
    let mut r = RECT::default();
    unsafe {
        let _ = SystemParametersInfoW(SPI_GETWORKAREA, 0, Some(&mut r as *mut _ as *mut _), SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0));
    }
    r
}

pub fn placement(hwnd: HWND) -> WINDOWPLACEMENT {
    let mut wp = WINDOWPLACEMENT { length: size_of::<WINDOWPLACEMENT>() as u32, ..Default::default() };
    unsafe {
        let _ = GetWindowPlacement(hwnd, &mut wp);
    }
    wp
}

/// Move a window onto the middle of the user's main screen without
/// activating it, with the dialogs and menus it has open (an unsaved-changes
/// prompt, say), and give it its taskbar button back. A minimized window
/// stays minimized and comes back there.
pub fn to_user_screen(hwnd: HWND) {
    let work = primary_work_area();
    let mut wp = placement(hwnd);
    let iconic = win::is_minimized(hwnd);
    let before = win::frame(hwnd);
    let size = if iconic || win::is_maximized(hwnd) { wp.rcNormalPosition } else { before };
    let (w, h) = ((size.right - size.left).min(work.right - work.left), (size.bottom - size.top).min(work.bottom - work.top));
    let x = work.left + (work.right - work.left - w) / 2;
    let y = work.top + (work.bottom - work.top - h) / 2;
    unsafe {
        if iconic || win::is_maximized(hwnd) {
            wp.flags = WINDOWPLACEMENT_FLAGS(0);
            wp.showCmd = if iconic { SW_SHOWMINNOACTIVE.0 as u32 } else { SW_SHOWNOACTIVATE.0 as u32 };
            wp.rcNormalPosition = RECT { left: x, top: y, right: x + w, bottom: y + h };
            let _ = SetWindowPlacement(hwnd, &wp);
        } else {
            let _ = SetWindowPos(hwnd, None, x, y, w, h, SWP_NOZORDER | SWP_NOACTIVATE);
        }
    }
    if !iconic {
        let after = win::frame(hwnd);
        let (dx, dy) = (after.left - before.left, after.top - before.top);
        for owned in win::top_level_windows() {
            if owned != hwnd && win::is_visible(owned) && unsafe { GetAncestor(owned, GA_ROOTOWNER) } == hwnd {
                let mut r = RECT::default();
                unsafe {
                    let _ = GetWindowRect(owned, &mut r);
                    let _ = SetWindowPos(owned, None, r.left + dx, r.top + dy, 0, 0, SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOSIZE);
                }
            }
        }
    }
    show_in_taskbar(hwnd);
}

/// Put a borrowed window back exactly as it was: where, and maximized or
/// minimized. Only a maximized one can't be shown without activating it, so
/// the focus guard hands the foreground back if it takes it.
pub fn put_back(hwnd: HWND, home: &WINDOWPLACEMENT) {
    let mut wp = *home;
    wp.length = size_of::<WINDOWPLACEMENT>() as u32;
    let maximized = home.showCmd == SW_SHOWMAXIMIZED.0 as u32;
    wp.showCmd = match home.showCmd {
        c if c == SW_SHOWMAXIMIZED.0 as u32 => c,
        c if c == SW_SHOWMINIMIZED.0 as u32 || c == SW_MINIMIZE.0 as u32 || c == SW_SHOWMINNOACTIVE.0 as u32 => SW_SHOWMINNOACTIVE.0 as u32,
        _ => SW_SHOWNOACTIVATE.0 as u32,
    };
    let pid = win::pid_tid(hwnd).0;
    if maximized {
        guard::begin_action(pid);
    }
    unsafe {
        let _ = SetWindowPlacement(hwnd, &wp);
    }
    if maximized {
        let _ = guard::end_action(pid);
    }
    show_in_taskbar(hwnd);
}

/// Open a new window of `app` on the agent monitor. Returns the window and
/// notes on what happened.
///
/// The app's new windows are caught as it creates and shows them (see
/// offscreen.rs), so they don't show on the user's screen; the loop here
/// only finds which window is the agent's.
pub fn open(app: &App, monitor: RECT, index: usize) -> Result<(HWND, Vec<String>), String> {
    let known: HashSet<usize> = win::top_level_windows().into_iter().map(|h| h.0 as usize).collect();
    let mut notes = Vec::new();
    let t = Instant::now();
    // Activations by the app's running process count as the agent's from now on.
    // Its running processes: any with a window, even hidden (a browser kept
    // running in the background shows none, and opens the new window).
    let running: Vec<u32> = win::top_level_windows()
        .into_iter()
        .filter(|h| app.exe.is_some() && matches(app, *h, &[]))
        .map(|h| win::pid_tid(h).0)
        .collect::<HashSet<_>>()
        .into_iter()
        .collect();
    for pid in &running {
        guard::begin_action(*pid);
    }
    let mut opening = offscreen::begin_open(&running, app.path.as_deref().or(app.exe.as_deref()), monitor, index);
    let result = (|| {
        let started = match &app.aumid {
            Some(aumid) => Some(activate(aumid)?).filter(|p| *p != 0),
            None => launch(&app.launch, None)?,
        };
        if let Some(pid) = started {
            opening.add_pid(pid);
        }
        let launched: Vec<u32> = started.into_iter().collect();
        if app.exe.is_none() && launched.is_empty() {
            return Err(format!(
                "started {}, but couldn't tell which window is its new one. If it opened on the user's screen, use list_windows and borrow_window.",
                app.name
            ));
        }
        let deadline = t + Duration::from_secs(15);
        let mut found: Option<(HWND, Instant)> = None;
        loop {
            if let Some((hwnd, since)) = found {
                // offscreen.rs keeps it on the monitor from here; this is a backstop.
                // A window that opened maximized was only moved from inside
                // the app (restoring it there crashes Chromium, see
                // bcu_hook::place): restore it from here, once it's shown, or
                // Windows can maximize it back onto the user's screen.
                if (!on_monitor(hwnd, &monitor) || win::is_maximized(hwnd)) && !win::is_minimized(hwnd) {
                    place(hwnd, monitor, index);
                }
                if since.elapsed() > Duration::from_millis(500) {
                    // An app running as administrator ignores this app's
                    // moves and input (UIPI): say so rather than hand the agent a window it can't use.
                    let pid = win::pid_tid(hwnd).0;
                    if win::above_us(pid) || (!on_monitor(hwnd, &monitor) && !win::is_minimized(hwnd)) {
                        guard::remove_agent_window(hwnd);
                        if win::exists(hwnd) && win::is_visible(hwnd) {
                            show_in_taskbar(hwnd);
                        }
                        return Err(format!(
                            "{} opened a window, but it {}, so Windows doesn't let this app move it or send it input. It's on the user's screen.",
                            app.name,
                            if win::above_us(pid) { "runs as administrator" } else { "wouldn't move onto your monitor" }
                        ));
                    }
                    return Ok(hwnd);
                }
            } else if Instant::now() > deadline {
                return Err(format!(
                    "{} didn't open a new window within 15 s. If it's a single-window app, use borrow_window with one of its windows from list_windows.",
                    app.name
                ));
            } else {
                for hwnd in win::top_level_windows() {
                    if known.contains(&(hwnd.0 as usize)) || !win::is_app_window(hwnd) || !matches(app, hwnd, &launched) {
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
