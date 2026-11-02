//! bcu-probe: measures what Windows allows for background computer use.
//!
//! Each subcommand answers one question the Windows app depends on, and
//! prints what happened (timings, whether focus moved, whether text landed).
//! Run it in a test VM, never against someone's live session.

use std::error::Error;
use std::time::{Duration, Instant};

use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Dwm::*;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::Storage::Xps::{PRINT_WINDOW_FLAGS, PrintWindow};
use windows::Win32::System::Com::*;
use windows::Win32::System::Threading::*;
use windows::Win32::UI::Accessibility::*;
use windows::Win32::UI::HiDpi::*;
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::Shell::*;
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::Win32::System::SystemServices::{MK_LBUTTON, MK_RBUTTON};
use windows::core::{BOOL, BSTR, HSTRING, PCWSTR};

type R<T = ()> = Result<T, Box<dyn Error>>;

const USAGE: &str = "\
usage: bcu-probe <command> [args]
  monitors                          list monitors
  monitor-pos <device> <x> <y>      move a monitor (e.g. DISPLAY2) in the desktop layout
  steal-restore <agent> <user> <method> [element]
                                    UIA-invoke <element> (default Increment) in <agent> while <user> is in
                                    front; if the agent takes the foreground, give it back with <method>:
                                    plain, attach, switch, uiafocus, alt, hide, or all (first that works)
  get-text <hwnd>                   WM_GETTEXT from the window's edit control (Notepad's text)
  find <filter>                     print the first visible titled window matching <filter> (for scripts)
  fg <hwnd>                         make <hwnd> the foreground window
  uia-grep <hwnd> <text>            print every element whose name contains <text>
  post-click-name <hwnd> <name>     post a left click at the center of the first element named <name>
  windows [filter]                  list visible top-level windows (hwnd, pid, exe, title, rect, cloaked)
  fg-watch <secs>                   log every foreground change
  uia-dump <hwnd> [max]             UI Automation tree (cached, one round trip) with timings
  uia-invoke <hwnd> <name>          Invoke the first element whose name contains <name>
  uia-setvalue <hwnd> <name> <text> ValuePattern.SetValue on the first match
  uia-value <hwnd> <name>           read ValuePattern.Value of the first match
  uia-focus <hwnd> <name>           SetFocus on the first match (does it take the foreground?)
  post-chars <hwnd> <text>          post WM_CHAR to the window's focused child
  post-key <hwnd> <key> [mods] [--state]
                                    post WM_KEYDOWN/UP; mods like ctrl,shift,alt; --state also sets the
                                    target thread's key state (AttachThreadInput + SetKeyboardState)
  post-click <hwnd> <x> <y> [right] post mouse messages at client point x,y
  swap <hwnd> <hold_ms> [--film]    make <hwnd> foreground, hold, give it back; --film watches the old
                                    foreground window's pixels for changes meanwhile
  capture <hwnd> <out.png>          PrintWindow(PW_RENDERFULLCONTENT) to a PNG
  frames <hwnd> <n> <ms>            capture n frames <ms> apart, report which changed (does it keep drawing?)
  move <hwnd> <x> <y> [w] [h]       SetWindowPos without activating
  launch <exe> [args...] [--to x,y] start a process without activating it; log new windows and focus
                                    changes for 3 s, moving each new window to x,y as soon as it shows
  type-into <hwnd> <text> [ms]      SendInput-type into <hwnd> as if the user typed (makes it foreground)
  tray-rect                         screen rect of the app's tray icon: x y w h
  mouse <x> <y> [left|right]        move the real cursor to screen x,y and click, as the user would
  tap <key>                         press and release a key with SendInput, as the user would
";

fn main() {
    unsafe {
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }
    if let Err(e) = run() {
        eprintln!("bcu-probe: {e}");
        std::process::exit(2);
    }
}

fn run() -> R {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some(cmd) = args.first() else {
        print!("{USAGE}");
        std::process::exit(1);
    };
    let rest = &args[1..];
    match cmd.as_str() {
        "monitors" => monitors(),
        "find" => find(arg(rest, 0)?),
        "get-text" => get_text(hwnd_arg(rest, 0)?),
        "steal-restore" => steal_restore(
            hwnd_arg(rest, 0)?,
            hwnd_arg(rest, 1)?,
            arg(rest, 2)?,
            rest.get(3).map(String::as_str).unwrap_or("Increment"),
        ),
        "monitor-pos" => {
            let d = arg(rest, 0)?;
            let device = if d.starts_with(r"\\") { d.to_string() } else { format!(r"\\.\{d}") };
            monitor_pos(&device, num(rest, 1)? as i32, num(rest, 2)? as i32)
        }
        "fg" => {
            let hwnd = hwnd_arg(rest, 0)?;
            let ok = set_foreground(hwnd);
            println!("{}", if ok { "foreground set" } else { "REFUSED" });
            Ok(())
        }
        "uia-grep" => uia_grep(hwnd_arg(rest, 0)?, arg(rest, 1)?),
        "post-click-name" => post_click_name(hwnd_arg(rest, 0)?, arg(rest, 1)?),
        "windows" => windows_list(rest.first().map(String::as_str)),
        "fg-watch" => fg_watch(num(rest, 0)? as u64),
        "uia-dump" => uia_dump(hwnd_arg(rest, 0)?, rest.get(1).map(|s| s.parse()).transpose()?.unwrap_or(400)),
        "uia-invoke" => uia_on_match(hwnd_arg(rest, 0)?, arg(rest, 1)?, UiaOp::Invoke),
        "uia-setvalue" => uia_on_match(hwnd_arg(rest, 0)?, arg(rest, 1)?, UiaOp::SetValue(arg(rest, 2)?.to_string())),
        "uia-value" => uia_on_match(hwnd_arg(rest, 0)?, arg(rest, 1)?, UiaOp::GetValue),
        "uia-focus" => uia_on_match(hwnd_arg(rest, 0)?, arg(rest, 1)?, UiaOp::Focus),
        "post-chars" => post_chars(hwnd_arg(rest, 0)?, arg(rest, 1)?),
        "post-key" => {
            let state = rest.iter().any(|a| a == "--state");
            let mods = rest.get(2).filter(|m| !m.starts_with("--")).map(String::as_str).unwrap_or("");
            post_key(hwnd_arg(rest, 0)?, arg(rest, 1)?, mods, state)
        }
        "post-click" => post_click(
            hwnd_arg(rest, 0)?,
            num(rest, 1)? as i32,
            num(rest, 2)? as i32,
            rest.get(3).is_some_and(|b| b == "right"),
        ),
        "swap" => swap(hwnd_arg(rest, 0)?, num(rest, 1)? as u64, rest.iter().any(|a| a == "--film")),
        "capture" => capture_cmd(hwnd_arg(rest, 0)?, arg(rest, 1)?),
        "frames" => frames(hwnd_arg(rest, 0)?, num(rest, 1)? as usize, num(rest, 2)? as u64),
        "move" => move_window(
            hwnd_arg(rest, 0)?,
            num(rest, 1)? as i32,
            num(rest, 2)? as i32,
            rest.get(3).map(|s| s.parse()).transpose()?,
            rest.get(4).map(|s| s.parse()).transpose()?,
        ),
        "launch" => launch(rest),
        "type-into" => type_into(
            hwnd_arg(rest, 0)?,
            arg(rest, 1)?,
            rest.get(2).map(|s| s.parse()).transpose()?.unwrap_or(30),
        ),
        "tray-rect" => tray_rect(),
        "mouse" => mouse(num(rest, 0)? as i32, num(rest, 1)? as i32, rest.get(2).map(String::as_str)),
        "tap" => tap(vk_for(arg(rest, 0)?)?),
        _ => {
            print!("{USAGE}");
            std::process::exit(1);
        }
    }
}

// ---------- argument helpers ----------

fn arg<'a>(args: &'a [String], i: usize) -> R<&'a str> {
    args.get(i).map(String::as_str).ok_or_else(|| format!("missing argument {}", i + 1).into())
}

fn num(args: &[String], i: usize) -> R<f64> {
    Ok(arg(args, i)?.parse::<f64>()?)
}

/// Accepts decimal or 0x-prefixed hex window handles.
fn hwnd_arg(args: &[String], i: usize) -> R<HWND> {
    let s = arg(args, i)?;
    let v = if let Some(hex) = s.strip_prefix("0x") { isize::from_str_radix(hex, 16)? } else { s.parse::<isize>()? };
    let hwnd = HWND(v as *mut _);
    if !unsafe { IsWindow(Some(hwnd)) }.as_bool() {
        return Err(format!("{s} is not a window").into());
    }
    Ok(hwnd)
}

fn h(hwnd: HWND) -> String {
    format!("0x{:x}", hwnd.0 as usize)
}

// ---------- window info ----------

fn window_title(hwnd: HWND) -> String {
    let mut buf = [0u16; 512];
    let n = unsafe { GetWindowTextW(hwnd, &mut buf) };
    String::from_utf16_lossy(&buf[..n.max(0) as usize])
}

fn class_name(hwnd: HWND) -> String {
    let mut buf = [0u16; 256];
    let n = unsafe { GetClassNameW(hwnd, &mut buf) };
    String::from_utf16_lossy(&buf[..n.max(0) as usize])
}

fn window_pid_tid(hwnd: HWND) -> (u32, u32) {
    let mut pid = 0u32;
    let tid = unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)) };
    (pid, tid)
}

fn exe_name(pid: u32) -> String {
    unsafe {
        let Ok(process) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else {
            return "?".into();
        };
        let mut buf = [0u16; 1024];
        let mut len = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(process, PROCESS_NAME_WIN32, windows::core::PWSTR(buf.as_mut_ptr()), &mut len);
        let _ = CloseHandle(process);
        if ok.is_err() {
            return "?".into();
        }
        let path = String::from_utf16_lossy(&buf[..len as usize]);
        path.rsplit('\\').next().unwrap_or(&path).to_string()
    }
}

fn window_rect(hwnd: HWND) -> RECT {
    let mut r = RECT::default();
    unsafe {
        // The visible frame, without the invisible resize borders.
        if DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, &mut r as *mut _ as *mut _, size_of::<RECT>() as u32).is_err() {
            let _ = GetWindowRect(hwnd, &mut r);
        }
    }
    r
}

fn is_cloaked(hwnd: HWND) -> bool {
    let mut cloaked = 0u32;
    unsafe {
        let _ = DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &mut cloaked as *mut _ as *mut _, 4);
    }
    cloaked != 0
}

fn describe(hwnd: HWND) -> String {
    if hwnd.0.is_null() {
        return "(none)".into();
    }
    let (pid, _) = window_pid_tid(hwnd);
    format!("{} {} pid {} \"{}\" [{}]", h(hwnd), exe_name(pid), pid, window_title(hwnd), class_name(hwnd))
}

fn foreground() -> HWND {
    unsafe { GetForegroundWindow() }
}

fn ms(since: Instant) -> f64 {
    since.elapsed().as_secs_f64() * 1000.0
}

// ---------- monitors / windows ----------

fn monitors() -> R {
    unsafe extern "system" fn each(m: HMONITOR, _: HDC, _: *mut RECT, _: LPARAM) -> BOOL {
        let mut info = MONITORINFOEXW::default();
        info.monitorInfo.cbSize = size_of::<MONITORINFOEXW>() as u32;
        unsafe {
            let _ = GetMonitorInfoW(m, &mut info as *mut _ as *mut MONITORINFO);
        }
        let r = info.monitorInfo.rcMonitor;
        let name = String::from_utf16_lossy(&info.szDevice).trim_end_matches('\0').to_string();
        let primary = info.monitorInfo.dwFlags & MONITORINFOF_PRIMARY != 0;
        let mut dx = 0;
        let mut dy = 0;
        unsafe {
            let _ = windows::Win32::UI::HiDpi::GetDpiForMonitor(m, MDT_EFFECTIVE_DPI, &mut dx, &mut dy);
        }
        println!(
            "{name} {}x{} at ({},{}) dpi {dx}{}",
            r.right - r.left,
            r.bottom - r.top,
            r.left,
            r.top,
            if primary { " primary" } else { "" }
        );
        true.into()
    }
    unsafe {
        let _ = EnumDisplayMonitors(None, None, Some(each), LPARAM(0));
    }
    Ok(())
}

fn monitor_pos(device: &str, x: i32, y: i32) -> R {
    let name = HSTRING::from(device);
    let mut dm = DEVMODEW { dmSize: size_of::<DEVMODEW>() as u16, ..Default::default() };
    unsafe {
        if !EnumDisplaySettingsW(PCWSTR(name.as_ptr()), ENUM_CURRENT_SETTINGS, &mut dm).as_bool() {
            return Err(format!("no display settings for {device}").into());
        }
        dm.Anonymous1.Anonymous2.dmPosition = POINTL { x, y };
        dm.dmFields = DM_POSITION;
        let r = ChangeDisplaySettingsExW(PCWSTR(name.as_ptr()), Some(&dm), None, CDS_UPDATEREGISTRY | CDS_NORESET, None);
        println!("stage {device} at ({x},{y}): {r:?}");
        let r = ChangeDisplaySettingsExW(PCWSTR::null(), None, None, CDS_TYPE(0), None);
        println!("apply: {r:?}");
    }
    std::thread::sleep(Duration::from_millis(500));
    monitors()
}

fn top_level_windows() -> Vec<HWND> {
    unsafe extern "system" fn each(hwnd: HWND, out: LPARAM) -> BOOL {
        let list = unsafe { &mut *(out.0 as *mut Vec<HWND>) };
        list.push(hwnd);
        true.into()
    }
    let mut list: Vec<HWND> = Vec::new();
    unsafe {
        let _ = EnumWindows(Some(each), LPARAM(&mut list as *mut _ as isize));
    }
    list
}

fn windows_list(filter: Option<&str>) -> R {
    let fg = foreground();
    for hwnd in top_level_windows() {
        if !unsafe { IsWindowVisible(hwnd) }.as_bool() {
            continue;
        }
        let title = window_title(hwnd);
        let (pid, _) = window_pid_tid(hwnd);
        let exe = exe_name(pid);
        if let Some(f) = filter {
            let f = f.to_lowercase();
            if !title.to_lowercase().contains(&f) && !exe.to_lowercase().contains(&f) {
                continue;
            }
        } else if title.is_empty() {
            continue;
        }
        let r = window_rect(hwnd);
        println!(
            "{} {exe} pid {pid} \"{title}\" [{}] {}x{} at ({},{}){}{}",
            h(hwnd),
            class_name(hwnd),
            r.right - r.left,
            r.bottom - r.top,
            r.left,
            r.top,
            if is_cloaked(hwnd) { " cloaked" } else { "" },
            if hwnd == fg { " FOREGROUND" } else { "" },
        );
    }
    Ok(())
}

fn get_text(hwnd: HWND) -> R {
    // The deepest edit-like child: RichEdit (Notepad), Edit.
    unsafe extern "system" fn each(child: HWND, out: LPARAM) -> BOOL {
        let found = unsafe { &mut *(out.0 as *mut Option<HWND>) };
        let class = class_name(child).to_lowercase();
        if class.contains("richedit") || class == "edit" {
            *found = Some(child);
            return false.into();
        }
        true.into()
    }
    let mut found: Option<HWND> = None;
    unsafe {
        let _ = EnumChildWindows(Some(hwnd), Some(each), LPARAM(&mut found as *mut _ as isize));
    }
    let edit = found.ok_or("no edit control in that window")?;
    let len = unsafe { SendMessageW(edit, WM_GETTEXTLENGTH, None, None) }.0 as usize;
    let mut buf = vec![0u16; len + 1];
    let n = unsafe { SendMessageW(edit, WM_GETTEXT, Some(WPARAM(buf.len())), Some(LPARAM(buf.as_mut_ptr() as isize))) }.0 as usize;
    println!("text ({n} chars): {:?}", String::from_utf16_lossy(&buf[..n]));
    Ok(())
}

fn find(filter: &str) -> R {
    let f = filter.to_lowercase();
    for hwnd in top_level_windows() {
        if !unsafe { IsWindowVisible(hwnd) }.as_bool() || is_cloaked(hwnd) {
            continue;
        }
        let title = window_title(hwnd);
        if title.is_empty() {
            continue;
        }
        let exe = exe_name(window_pid_tid(hwnd).0);
        if title.to_lowercase().contains(&f) || exe.to_lowercase().contains(&f) {
            println!("{}", h(hwnd));
            return Ok(());
        }
    }
    Err(format!("no window matching {filter}").into())
}

// ---------- foreground watching ----------

static START: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();

unsafe extern "system" fn on_win_event(
    _hook: HWINEVENTHOOK,
    event: u32,
    hwnd: HWND,
    id_object: i32,
    _id_child: i32,
    _thread: u32,
    _time: u32,
) {
    let t = START.get().map(|s| ms(*s)).unwrap_or(0.0);
    match event {
        EVENT_SYSTEM_FOREGROUND => println!("{t:8.1} ms  foreground -> {}", describe(hwnd)),
        EVENT_OBJECT_CREATE if id_object == OBJID_WINDOW.0 => {
            if unsafe { GetAncestor(hwnd, GA_ROOT) } == hwnd && unsafe { GetParent(hwnd) }.map(|p| p.0.is_null()).unwrap_or(true) {
                let visible = unsafe { IsWindowVisible(hwnd) }.as_bool();
                println!("{t:8.1} ms  created {} visible={visible}", describe(hwnd));
                if let Some((x, y)) = *MOVE_NEW_TO.lock().unwrap() {
                    unsafe {
                        let _ = SetWindowPos(hwnd, None, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
                    }
                }
            }
        }
        EVENT_OBJECT_SHOW if id_object == OBJID_WINDOW.0 => {
            if unsafe { GetAncestor(hwnd, GA_ROOT) } == hwnd && !window_title(hwnd).is_empty() {
                let r = window_rect(hwnd);
                println!("{t:8.1} ms  shown {} at ({},{})", describe(hwnd), r.left, r.top);
                if let Some((x, y)) = *MOVE_NEW_TO.lock().unwrap() {
                    let moved = Instant::now();
                    unsafe {
                        let _ = SetWindowPos(hwnd, None, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
                    }
                    println!("{t:8.1} ms  moved it to ({x},{y}) in {:.1} ms", ms(moved));
                }
            }
        }
        _ => {}
    }
}

static MOVE_NEW_TO: std::sync::Mutex<Option<(i32, i32)>> = std::sync::Mutex::new(None);

/// Out-of-context WinEvent hooks are delivered through this thread's message queue.
fn pump_for(duration: Duration) {
    let end = Instant::now() + duration;
    unsafe {
        let mut msg = MSG::default();
        while Instant::now() < end {
            while PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE).as_bool() {
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
            std::thread::sleep(Duration::from_millis(1));
        }
    }
}

fn hook(min: u32, max: u32) -> HWINEVENTHOOK {
    unsafe { SetWinEventHook(min, max, None, Some(on_win_event), 0, 0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS) }
}

fn fg_watch(secs: u64) -> R {
    START.get_or_init(Instant::now);
    println!("foreground now: {}", describe(foreground()));
    let hk = hook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND);
    pump_for(Duration::from_secs(secs));
    unsafe {
        let _ = UnhookWinEvent(hk);
    }
    Ok(())
}

// ---------- UI Automation ----------

fn uia() -> R<IUIAutomation> {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        Ok(CoCreateInstance(&CUIAutomation8, None, CLSCTX_INPROC_SERVER)?)
    }
}

struct Node {
    element: IUIAutomationElement,
    control_type: i32,
    name: String,
    automation_id: String,
    rect: RECT,
    offscreen: bool,
    focused: bool,
    patterns: Vec<&'static str>,
}

const PATTERNS: [(UIA_PROPERTY_ID, &str); 7] = [
    (UIA_IsInvokePatternAvailablePropertyId, "invoke"),
    (UIA_IsValuePatternAvailablePropertyId, "value"),
    (UIA_IsTogglePatternAvailablePropertyId, "toggle"),
    (UIA_IsExpandCollapsePatternAvailablePropertyId, "expand"),
    (UIA_IsSelectionItemPatternAvailablePropertyId, "select"),
    (UIA_IsScrollPatternAvailablePropertyId, "scroll"),
    (UIA_IsTextPatternAvailablePropertyId, "text"),
];

/// Every element under the window in one cross-process call (FindAllBuildCache).
fn uia_nodes(auto: &IUIAutomation, hwnd: HWND) -> R<Vec<Node>> {
    unsafe {
        let root = auto.ElementFromHandle(hwnd)?;
        let cache = auto.CreateCacheRequest()?;
        for p in [
            UIA_ControlTypePropertyId,
            UIA_NamePropertyId,
            UIA_AutomationIdPropertyId,
            UIA_BoundingRectanglePropertyId,
            UIA_IsOffscreenPropertyId,
            UIA_HasKeyboardFocusPropertyId,
        ] {
            cache.AddProperty(p)?;
        }
        for (p, _) in PATTERNS {
            cache.AddProperty(p)?;
        }
        let condition = auto.ControlViewCondition()?;
        let found = root.FindAllBuildCache(TreeScope_Descendants, &condition, &cache)?;
        let n = found.Length()?;
        let mut out = Vec::with_capacity(n as usize);
        for i in 0..n {
            let e = found.GetElement(i)?;
            let mut patterns = Vec::new();
            for (p, label) in PATTERNS {
                if let Ok(v) = e.GetCachedPropertyValue(p)
                    && bool::try_from(&v).unwrap_or(false)
                {
                    patterns.push(label);
                }
            }
            out.push(Node {
                control_type: e.CachedControlType().map(|c| c.0).unwrap_or(0),
                name: e.CachedName().map(|s| s.to_string()).unwrap_or_default(),
                automation_id: e.CachedAutomationId().map(|s| s.to_string()).unwrap_or_default(),
                rect: e.CachedBoundingRectangle().unwrap_or_default(),
                offscreen: e.CachedIsOffscreen().map(|b| b.as_bool()).unwrap_or(false),
                focused: e.CachedHasKeyboardFocus().map(|b| b.as_bool()).unwrap_or(false),
                patterns,
                element: e,
            });
        }
        Ok(out)
    }
}

#[allow(non_upper_case_globals)]
fn control_type_name(id: i32) -> &'static str {
    match UIA_CONTROLTYPE_ID(id) {
        UIA_ButtonControlTypeId => "button",
        UIA_CheckBoxControlTypeId => "checkbox",
        UIA_ComboBoxControlTypeId => "combobox",
        UIA_DocumentControlTypeId => "document",
        UIA_EditControlTypeId => "edit",
        UIA_GroupControlTypeId => "group",
        UIA_HyperlinkControlTypeId => "link",
        UIA_ImageControlTypeId => "image",
        UIA_ListControlTypeId => "list",
        UIA_ListItemControlTypeId => "listitem",
        UIA_MenuControlTypeId => "menu",
        UIA_MenuBarControlTypeId => "menubar",
        UIA_MenuItemControlTypeId => "menuitem",
        UIA_PaneControlTypeId => "pane",
        UIA_RadioButtonControlTypeId => "radio",
        UIA_ScrollBarControlTypeId => "scrollbar",
        UIA_TabControlTypeId => "tabs",
        UIA_TabItemControlTypeId => "tab",
        UIA_TextControlTypeId => "text",
        UIA_TitleBarControlTypeId => "titlebar",
        UIA_ToolBarControlTypeId => "toolbar",
        UIA_TreeItemControlTypeId => "treeitem",
        UIA_WindowControlTypeId => "window",
        UIA_CustomControlTypeId => "custom",
        _ => "other",
    }
}

fn uia_dump(hwnd: HWND, max: usize) -> R {
    let auto = uia()?;
    let fg_before = foreground();
    // Chromium builds its full tree only once a UIA client has asked, so read twice.
    for pass in 1..=2 {
        let t = Instant::now();
        let nodes = uia_nodes(&auto, hwnd)?;
        println!("pass {pass}: {} elements in {:.1} ms", nodes.len(), ms(t));
        if pass == 2 {
            for n in nodes.iter().take(max) {
                println!(
                    "  {:9} \"{}\"{} {}x{} at ({},{}){}{}{}",
                    control_type_name(n.control_type),
                    n.name.chars().take(80).collect::<String>(),
                    if n.automation_id.is_empty() { String::new() } else { format!(" id={}", n.automation_id) },
                    n.rect.right - n.rect.left,
                    n.rect.bottom - n.rect.top,
                    n.rect.left,
                    n.rect.top,
                    if n.patterns.is_empty() { String::new() } else { format!(" [{}]", n.patterns.join(",")) },
                    if n.offscreen { " offscreen" } else { "" },
                    if n.focused { " FOCUSED" } else { "" },
                );
            }
        }
        if pass == 1 {
            std::thread::sleep(Duration::from_millis(800));
        }
    }
    report_fg(fg_before);
    Ok(())
}

enum UiaOp {
    Invoke,
    SetValue(String),
    GetValue,
    Focus,
}

fn uia_on_match(hwnd: HWND, name: &str, op: UiaOp) -> R {
    let auto = uia()?;
    let _ = uia_nodes(&auto, hwnd)?; // wake Chromium's tree
    std::thread::sleep(Duration::from_millis(300));
    let nodes = uia_nodes(&auto, hwnd)?;
    let needle = name.to_lowercase();
    let wanted = match op {
        UiaOp::Invoke => Some("invoke"),
        UiaOp::SetValue(_) | UiaOp::GetValue => Some("value"),
        UiaOp::Focus => None,
    };
    let node = nodes
        .iter()
        .find(|n| {
            (n.name.to_lowercase().contains(&needle) || n.automation_id.to_lowercase() == needle)
                && wanted.is_none_or(|p| n.patterns.contains(&p))
        })
        .ok_or("no matching element with that pattern")?;
    println!("element: {} \"{}\"", control_type_name(node.control_type), node.name);
    let fg_before = foreground();
    let t = Instant::now();
    unsafe {
        match op {
            UiaOp::Invoke => {
                let p: IUIAutomationInvokePattern = node.element.GetCurrentPatternAs(UIA_InvokePatternId)?;
                p.Invoke()?;
                println!("invoked in {:.1} ms", ms(t));
            }
            UiaOp::SetValue(text) => {
                let p: IUIAutomationValuePattern = node.element.GetCurrentPatternAs(UIA_ValuePatternId)?;
                p.SetValue(&BSTR::from(text.as_str()))?;
                println!("set in {:.1} ms; value now \"{}\"", ms(t), p.CurrentValue()?);
            }
            UiaOp::GetValue => {
                let p: IUIAutomationValuePattern = node.element.GetCurrentPatternAs(UIA_ValuePatternId)?;
                println!("value \"{}\"", p.CurrentValue()?);
            }
            UiaOp::Focus => {
                node.element.SetFocus()?;
                println!("focused in {:.1} ms", ms(t));
            }
        }
    }
    std::thread::sleep(Duration::from_millis(300));
    report_fg(fg_before);
    Ok(())
}

fn uia_grep(hwnd: HWND, text: &str) -> R {
    let auto = uia()?;
    let _ = uia_nodes(&auto, hwnd)?;
    std::thread::sleep(Duration::from_millis(200));
    let needle = text.to_lowercase();
    let mut found = 0;
    for n in uia_nodes(&auto, hwnd)? {
        if n.name.to_lowercase().contains(&needle) {
            found += 1;
            println!("  {} \"{}\"{}", control_type_name(n.control_type), n.name.replace('\n', " | ").chars().take(600).collect::<String>(), if n.focused { " FOCUSED" } else { "" });
        }
    }
    if found == 0 {
        println!("  (no element named like {text:?})");
    }
    Ok(())
}

fn post_click_name(hwnd: HWND, name: &str) -> R {
    let auto = uia()?;
    let _ = uia_nodes(&auto, hwnd)?;
    std::thread::sleep(Duration::from_millis(200));
    let needle = name.to_lowercase();
    let nodes = uia_nodes(&auto, hwnd)?;
    let n = nodes.iter().find(|n| n.name.to_lowercase().contains(&needle)).ok_or("no element with that name")?;
    let mut p = POINT { x: (n.rect.left + n.rect.right) / 2, y: (n.rect.top + n.rect.bottom) / 2 };
    unsafe {
        let _ = ScreenToClient(hwnd, &mut p);
    }
    println!("element {} \"{}\" center at client ({},{})", control_type_name(n.control_type), n.name, p.x, p.y);
    post_click(hwnd, p.x, p.y, false)
}

fn report_fg(before: HWND) {
    let after = foreground();
    if after == before {
        println!("foreground unchanged: {}", describe(after));
    } else {
        println!("FOREGROUND CHANGED: {} -> {}", describe(before), describe(after));
    }
}

// ---------- posted input ----------

/// The child that has keyboard focus in the window's thread, or the window itself.
fn focus_target(hwnd: HWND) -> HWND {
    let (_, tid) = window_pid_tid(hwnd);
    let mut info = GUITHREADINFO { cbSize: size_of::<GUITHREADINFO>() as u32, ..Default::default() };
    unsafe {
        if GetGUIThreadInfo(tid, &mut info).is_ok() && !info.hwndFocus.0.is_null() {
            return info.hwndFocus;
        }
    }
    hwnd
}

fn post_chars(hwnd: HWND, text: &str) -> R {
    let target = focus_target(hwnd);
    println!("target: {}", describe(target));
    let fg_before = foreground();
    let t = Instant::now();
    for unit in text.replace("\\n", "\r").encode_utf16() {
        unsafe { PostMessageW(Some(target), WM_CHAR, WPARAM(unit as usize), LPARAM(1))? };
    }
    println!("posted {} chars in {:.1} ms", text.chars().count(), ms(t));
    std::thread::sleep(Duration::from_millis(300));
    report_fg(fg_before);
    Ok(())
}

fn vk_for(key: &str) -> R<VIRTUAL_KEY> {
    let k = key.to_lowercase();
    Ok(match k.as_str() {
        "return" | "enter" => VK_RETURN,
        "tab" => VK_TAB,
        "space" => VK_SPACE,
        "escape" | "esc" => VK_ESCAPE,
        "delete" | "backspace" => VK_BACK,
        "forward_delete" => VK_DELETE,
        "up" => VK_UP,
        "down" => VK_DOWN,
        "left" => VK_LEFT,
        "right" => VK_RIGHT,
        "home" => VK_HOME,
        "end" => VK_END,
        "page_up" => VK_PRIOR,
        "page_down" => VK_NEXT,
        _ if k.len() == 1 => {
            let c = k.chars().next().unwrap();
            if c.is_ascii_alphanumeric() {
                VIRTUAL_KEY(c.to_ascii_uppercase() as u16)
            } else {
                let scan = unsafe { VkKeyScanW(c as u16) };
                if scan == -1 {
                    return Err(format!("no key for {c:?}").into());
                }
                VIRTUAL_KEY((scan & 0xff) as u16)
            }
        }
        _ if k.starts_with('f') && k[1..].parse::<u16>().is_ok_and(|n| (1..=12).contains(&n)) => {
            VIRTUAL_KEY(VK_F1.0 + k[1..].parse::<u16>().unwrap() - 1)
        }
        _ => return Err(format!("unknown key {key}").into()),
    })
}

fn key_lparam(vk: VIRTUAL_KEY, up: bool) -> LPARAM {
    let scan = unsafe { MapVirtualKeyW(vk.0 as u32, MAPVK_VK_TO_VSC) };
    let extended = matches!(
        vk,
        VK_UP | VK_DOWN | VK_LEFT | VK_RIGHT | VK_HOME | VK_END | VK_PRIOR | VK_NEXT | VK_DELETE | VK_INSERT
    );
    let mut l: u32 = 1 | (scan << 16);
    if extended {
        l |= 1 << 24;
    }
    if up {
        l |= (1 << 30) | (1 << 31);
    }
    LPARAM(l as i32 as isize)
}

fn post_key(hwnd: HWND, key: &str, mods: &str, set_state: bool) -> R {
    let target = focus_target(hwnd);
    let vk = vk_for(key)?;
    let modifier_keys: Vec<VIRTUAL_KEY> = mods
        .split(',')
        .filter(|m| !m.is_empty())
        .map(|m| match m {
            "ctrl" | "control" => Ok(VK_CONTROL),
            "shift" => Ok(VK_SHIFT),
            "alt" | "option" => Ok(VK_MENU),
            "win" => Ok(VK_LWIN),
            other => Err(format!("unknown modifier {other}")),
        })
        .collect::<Result<_, _>>()?;
    println!("target: {}", describe(target));
    let fg_before = foreground();
    let (_, target_tid) = window_pid_tid(target);
    let my_tid = unsafe { GetCurrentThreadId() };
    let mut saved = [0u8; 256];
    let t = Instant::now();
    unsafe {
        if set_state {
            // Share the target thread's input state, then mark the modifiers down in it,
            // so GetKeyState in the target sees them while it handles the posted keys.
            AttachThreadInput(my_tid, target_tid, true).ok()?;
            GetKeyboardState(&mut saved)?;
            let mut state = saved;
            for m in &modifier_keys {
                state[m.0 as usize] |= 0x80;
                let side = match *m {
                    VK_CONTROL => VK_LCONTROL,
                    VK_SHIFT => VK_LSHIFT,
                    VK_MENU => VK_LMENU,
                    other => other,
                };
                state[side.0 as usize] |= 0x80;
            }
            SetKeyboardState(&state)?;
        }
        let alt = modifier_keys.contains(&VK_MENU);
        let (down_msg, up_msg) = if alt { (WM_SYSKEYDOWN, WM_SYSKEYUP) } else { (WM_KEYDOWN, WM_KEYUP) };
        for m in &modifier_keys {
            PostMessageW(Some(target), down_msg, WPARAM(m.0 as usize), key_lparam(*m, false))?;
        }
        PostMessageW(Some(target), down_msg, WPARAM(vk.0 as usize), key_lparam(vk, false))?;
        PostMessageW(Some(target), up_msg, WPARAM(vk.0 as usize), key_lparam(vk, true))?;
        for m in modifier_keys.iter().rev() {
            PostMessageW(Some(target), up_msg, WPARAM(m.0 as usize), key_lparam(*m, true))?;
        }
        if set_state {
            std::thread::sleep(Duration::from_millis(80));
            SetKeyboardState(&saved)?;
            AttachThreadInput(my_tid, target_tid, false).ok()?;
        }
    }
    println!("posted in {:.1} ms", ms(t));
    std::thread::sleep(Duration::from_millis(300));
    report_fg(fg_before);
    Ok(())
}

fn post_click(hwnd: HWND, x: i32, y: i32, right: bool) -> R {
    // Find the deepest child under the point, and convert to its client coordinates.
    let mut pt = POINT { x, y };
    let mut target = hwnd;
    unsafe {
        let mut screen = pt;
        let _ = ClientToScreen(hwnd, &mut screen);
        loop {
            let mut local = screen;
            let _ = ScreenToClient(target, &mut local);
            let child = ChildWindowFromPointEx(target, local, CWP_SKIPINVISIBLE | CWP_SKIPTRANSPARENT);
            if child.0.is_null() || child == target {
                pt = local;
                break;
            }
            target = child;
        }
    }
    println!("target: {} at ({},{})", describe(target), pt.x, pt.y);
    let fg_before = foreground();
    let lp = LPARAM((((pt.y as u32 & 0xffff) << 16) | (pt.x as u32 & 0xffff)) as isize);
    let (down, up, mk) = if right { (WM_RBUTTONDOWN, WM_RBUTTONUP, MK_RBUTTON) } else { (WM_LBUTTONDOWN, WM_LBUTTONUP, MK_LBUTTON) };
    unsafe {
        PostMessageW(Some(target), WM_MOUSEMOVE, WPARAM(0), lp)?;
        PostMessageW(Some(target), down, WPARAM(mk.0 as usize), lp)?;
        PostMessageW(Some(target), up, WPARAM(0), lp)?;
    }
    std::thread::sleep(Duration::from_millis(300));
    report_fg(fg_before);
    Ok(())
}

// ---------- foreground swap ----------

/// SetForegroundWindow is refused unless the caller may set the foreground; joining the
/// current foreground thread's input queue for the call is the usual way around it.
fn set_foreground(target: HWND) -> bool {
    unsafe {
        if SetForegroundWindow(target).as_bool() && foreground() == target {
            return true;
        }
        SwitchToThisWindow(target, true);
        std::thread::sleep(Duration::from_millis(30));
        if foreground() == target {
            return true;
        }
        // UI Automation lets the app it focuses take the foreground.
        if let Ok(auto) = uia()
            && let Ok(e) = auto.ElementFromHandle(target)
        {
            let _ = e.SetFocus();
            std::thread::sleep(Duration::from_millis(50));
            if foreground() == target {
                return true;
            }
        }
        let fg = foreground();
        let (_, fg_tid) = window_pid_tid(fg);
        let my_tid = GetCurrentThreadId();
        let attached = fg_tid != my_tid && AttachThreadInput(my_tid, fg_tid, true).as_bool();
        let _ = SetForegroundWindow(target);
        if attached {
            let _ = AttachThreadInput(my_tid, fg_tid, false);
        }
        foreground() == target
    }
}

fn swap(hwnd: HWND, hold_ms: u64, film: bool) -> R {
    let user = foreground();
    println!("user foreground: {}", describe(user));
    let filmer = film.then(|| {
        let user_raw = user.0 as usize;
        let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let stop2 = stop.clone();
        let thread = std::thread::spawn(move || film_window(HWND(user_raw as *mut _), &stop2));
        std::thread::sleep(Duration::from_millis(200));
        (stop, thread)
    });
    let t = Instant::now();
    let took = set_foreground(hwnd);
    let t_in = ms(t);
    std::thread::sleep(Duration::from_millis(hold_ms));
    let t2 = Instant::now();
    let back = set_foreground(user);
    println!(
        "to agent: {} in {t_in:.1} ms; back to user: {} in {:.1} ms; total {:.1} ms",
        if took { "ok" } else { "REFUSED" },
        if back { "ok" } else { "REFUSED" },
        ms(t2),
        ms(t)
    );
    if let Some((stop, thread)) = filmer {
        std::thread::sleep(Duration::from_millis(300));
        stop.store(true, std::sync::atomic::Ordering::Relaxed);
        let (frames, changed) = thread.join().unwrap();
        println!("filmed the user's window: {frames} frames, {changed} differed from the first");
    }
    report_fg(user);
    Ok(())
}

/// Grab what's on screen over the window (what the user sees) until stopped.
fn film_window(hwnd: HWND, stop: &std::sync::atomic::AtomicBool) -> (usize, usize) {
    let mut first: Option<Vec<u8>> = None;
    let (mut frames, mut changed) = (0, 0);
    while !stop.load(std::sync::atomic::Ordering::Relaxed) {
        let r = window_rect(hwnd);
        if let Ok(px) = grab_screen(r) {
            frames += 1;
            match &first {
                None => first = Some(px),
                Some(f) if *f != px => changed += 1,
                _ => {}
            }
        }
        std::thread::sleep(Duration::from_millis(4));
    }
    (frames, changed)
}

// ---------- taking the foreground back ----------

fn wait_for_fg(target: HWND, max_ms: u64) -> Option<f64> {
    let t = Instant::now();
    while t.elapsed() < Duration::from_millis(max_ms) {
        if foreground() == target || window_pid_tid(foreground()).0 == window_pid_tid(target).0 {
            return Some(ms(t));
        }
        std::thread::sleep(Duration::from_micros(500));
    }
    None
}

fn restore_with(method: &str, user: HWND, agent: HWND, user_focus: Option<&IUIAutomationElement>) -> bool {
    unsafe {
        match method {
            "plain" => {
                let _ = SetForegroundWindow(user);
            }
            "attach" => {
                let (_, fg_tid) = window_pid_tid(foreground());
                let my = GetCurrentThreadId();
                let attached = AttachThreadInput(my, fg_tid, true).as_bool();
                let _ = BringWindowToTop(user);
                let _ = SetForegroundWindow(user);
                if attached {
                    let _ = AttachThreadInput(my, fg_tid, false);
                }
            }
            "switch" => SwitchToThisWindow(user, true),
            "uiafocus" => {
                if let Some(e) = user_focus {
                    let _ = e.SetFocus();
                }
            }
            "alt" => {
                // Windows lets a process set the foreground while ALT is down.
                let key = |flags| INPUT {
                    r#type: INPUT_KEYBOARD,
                    Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: VK_MENU, wScan: 0, dwFlags: flags, time: 0, dwExtraInfo: 0 } },
                };
                SendInput(&[key(KEYBD_EVENT_FLAGS(0))], size_of::<INPUT>() as i32);
                let _ = SetForegroundWindow(user);
                SendInput(&[key(KEYEVENTF_KEYUP)], size_of::<INPUT>() as i32);
            }
            "hide" => {
                // Put the user's window right under the agent's, then hide the agent's
                // for a moment: Windows activates the next window in z-order.
                let _ = SetWindowPos(user, Some(agent), 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
                let _ = ShowWindow(agent, SW_HIDE);
                let _ = ShowWindow(agent, SW_SHOWNOACTIVATE);
            }
            _ => {}
        }
    }
    let t = Instant::now();
    while t.elapsed() < Duration::from_millis(150) {
        if foreground() == user {
            return true;
        }
        std::thread::sleep(Duration::from_millis(1));
    }
    false
}

fn steal_restore(agent: HWND, user: HWND, method: &str, element: &str) -> R {
    let auto = uia()?;
    let _ = uia_nodes(&auto, agent)?;
    std::thread::sleep(Duration::from_millis(200));
    let nodes = uia_nodes(&auto, agent)?;
    let needle = element.to_lowercase();
    let node = nodes
        .iter()
        .find(|n| n.name.to_lowercase().contains(&needle) && n.patterns.contains(&"invoke"))
        .ok_or("no invokable element with that name")?;
    if foreground() != user {
        println!("user window isn't in front ({}); trying to bring it forward first", describe(foreground()));
        for m in ["plain", "attach", "switch", "alt"] {
            if restore_with(m, user, agent, None) {
                println!("  brought forward with {m}");
                break;
            }
        }
    }
    println!("before: {}", describe(foreground()));
    let user_focus = unsafe { auto.GetFocusedElement().ok() };
    let t = Instant::now();
    unsafe {
        let p: IUIAutomationInvokePattern = node.element.GetCurrentPatternAs(UIA_InvokePatternId)?;
        p.Invoke()?;
    }
    let invoked = ms(t);
    match wait_for_fg(agent, 400) {
        None => {
            println!("invoke took {invoked:.1} ms; the agent did NOT take the foreground within 400 ms");
            report_fg(user);
            return Ok(());
        }
        Some(at) => println!("invoke took {invoked:.1} ms; agent took the foreground {at:.1} ms later: {}", describe(foreground())),
    }
    let methods: Vec<&str> = if method == "all" { vec!["plain", "attach", "switch", "uiafocus", "hide", "alt"] } else { vec![method] };
    for m in methods {
        let t = Instant::now();
        let ok = restore_with(m, user, agent, user_focus.as_ref());
        println!("  {m}: {} in {:.1} ms (foreground now {})", if ok { "RESTORED" } else { "failed" }, ms(t), describe(foreground()));
        if ok {
            break;
        }
    }
    Ok(())
}

// ---------- capture ----------

struct Bitmap {
    width: i32,
    height: i32,
    bgra: Vec<u8>,
}

fn dib(dc: HDC, w: i32, h: i32) -> R<(HBITMAP, *mut u8)> {
    let info = BITMAPINFO {
        bmiHeader: BITMAPINFOHEADER {
            biSize: size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: w,
            biHeight: -h,
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        },
        ..Default::default()
    };
    let mut bits = std::ptr::null_mut();
    let bmp = unsafe { CreateDIBSection(Some(dc), &info, DIB_RGB_COLORS, &mut bits, None, 0)? };
    Ok((bmp, bits as *mut u8))
}

fn print_window(hwnd: HWND) -> R<Bitmap> {
    unsafe {
        let mut r = RECT::default();
        GetWindowRect(hwnd, &mut r)?;
        let (w, hgt) = (r.right - r.left, r.bottom - r.top);
        if w <= 0 || hgt <= 0 {
            return Err("window has no size".into());
        }
        let screen = GetDC(None);
        let mem = CreateCompatibleDC(Some(screen));
        let (bmp, bits) = dib(screen, w, hgt)?;
        let old = SelectObject(mem, bmp.into());
        // PW_RENDERFULLCONTENT (2) captures DirectComposition content (Chromium, UWP).
        let ok = PrintWindow(hwnd, mem, PRINT_WINDOW_FLAGS(2)).as_bool();
        let bgra = std::slice::from_raw_parts(bits, (w * hgt * 4) as usize).to_vec();
        SelectObject(mem, old);
        let _ = DeleteObject(bmp.into());
        let _ = DeleteDC(mem);
        ReleaseDC(None, screen);
        if !ok {
            return Err("PrintWindow failed".into());
        }
        Ok(Bitmap { width: w, height: hgt, bgra })
    }
}

fn grab_screen(r: RECT) -> R<Vec<u8>> {
    unsafe {
        let (w, hgt) = (r.right - r.left, r.bottom - r.top);
        let screen = GetDC(None);
        let mem = CreateCompatibleDC(Some(screen));
        let (bmp, bits) = dib(screen, w, hgt)?;
        let old = SelectObject(mem, bmp.into());
        BitBlt(mem, 0, 0, w, hgt, Some(screen), r.left, r.top, SRCCOPY)?;
        let px = std::slice::from_raw_parts(bits, (w * hgt * 4) as usize).to_vec();
        SelectObject(mem, old);
        let _ = DeleteObject(bmp.into());
        let _ = DeleteDC(mem);
        ReleaseDC(None, screen);
        Ok(px)
    }
}

fn write_png(path: &str, bmp: &Bitmap) -> R {
    let file = std::io::BufWriter::new(std::fs::File::create(path)?);
    let mut enc = png::Encoder::new(file, bmp.width as u32, bmp.height as u32);
    enc.set_color(png::ColorType::Rgba);
    enc.set_depth(png::BitDepth::Eight);
    let mut writer = enc.write_header()?;
    let mut rgba = bmp.bgra.clone();
    for px in rgba.chunks_exact_mut(4) {
        px.swap(0, 2);
        px[3] = 255;
    }
    writer.write_image_data(&rgba)?;
    Ok(())
}

fn black_fraction(bmp: &Bitmap) -> f64 {
    let n = bmp.bgra.len() / 4;
    let black = bmp.bgra.chunks_exact(4).filter(|p| p[0] < 8 && p[1] < 8 && p[2] < 8).count();
    black as f64 / n.max(1) as f64
}

fn capture_cmd(hwnd: HWND, out: &str) -> R {
    let t = Instant::now();
    let bmp = print_window(hwnd)?;
    let took = ms(t);
    write_png(out, &bmp)?;
    println!(
        "{}x{} in {took:.1} ms, {:.0}% black, saved {out}",
        bmp.width,
        bmp.height,
        black_fraction(&bmp) * 100.0
    );
    Ok(())
}

fn frames(hwnd: HWND, n: usize, interval: u64) -> R {
    let r = window_rect(hwnd);
    println!("window at ({},{}), cloaked: {}", r.left, r.top, is_cloaked(hwnd));
    let mut prev: Option<Vec<u8>> = None;
    for i in 0..n {
        let t = Instant::now();
        let bmp = print_window(hwnd)?;
        let took = ms(t);
        let changed = prev.as_ref().map(|p| *p != bmp.bgra);
        println!(
            "frame {i}: {took:.1} ms, {:.0}% black{}",
            black_fraction(&bmp) * 100.0,
            match changed {
                Some(true) => ", changed",
                Some(false) => ", SAME as previous",
                None => "",
            }
        );
        if i == n - 1 {
            write_png(&format!("frames-last-{}.png", h(hwnd)), &bmp)?;
        }
        prev = Some(bmp.bgra);
        std::thread::sleep(Duration::from_millis(interval));
    }
    Ok(())
}

fn move_window(hwnd: HWND, x: i32, y: i32, w: Option<i32>, hgt: Option<i32>) -> R {
    let fg_before = foreground();
    let mut flags = SWP_NOZORDER | SWP_NOACTIVATE;
    if w.is_none() {
        flags |= SWP_NOSIZE;
    }
    unsafe { SetWindowPos(hwnd, None, x, y, w.unwrap_or(0), hgt.unwrap_or(0), flags)? };
    std::thread::sleep(Duration::from_millis(200));
    let r = window_rect(hwnd);
    println!("now {}x{} at ({},{})", r.right - r.left, r.bottom - r.top, r.left, r.top);
    report_fg(fg_before);
    Ok(())
}

// ---------- launching ----------

fn launch(rest: &[String]) -> R {
    let mut to = None;
    let mut parts: Vec<&str> = Vec::new();
    let mut i = 0;
    while i < rest.len() {
        if rest[i] == "--to" {
            let xy = arg(rest, i + 1)?;
            let (x, y) = xy.split_once(',').ok_or("--to x,y")?;
            to = Some((x.parse()?, y.parse()?));
            i += 2;
        } else {
            parts.push(&rest[i]);
            i += 1;
        }
    }
    let exe = *parts.first().ok_or("missing exe")?;
    let params = parts[1..].join(" ");
    *MOVE_NEW_TO.lock().unwrap() = to;
    START.get_or_init(Instant::now);
    println!("foreground before: {}", describe(foreground()));
    let hk_fg = hook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND);
    let hk_show = hook(EVENT_OBJECT_CREATE, EVENT_OBJECT_SHOW);
    let exe_w = HSTRING::from(exe);
    let params_w = HSTRING::from(params.as_str());
    let mut info = SHELLEXECUTEINFOW {
        cbSize: size_of::<SHELLEXECUTEINFOW>() as u32,
        fMask: SEE_MASK_NOCLOSEPROCESS | SEE_MASK_FLAG_NO_UI,
        lpFile: PCWSTR(exe_w.as_ptr()),
        lpParameters: if params.is_empty() { PCWSTR::null() } else { PCWSTR(params_w.as_ptr()) },
        nShow: SW_SHOWNOACTIVATE.0,
        ..Default::default()
    };
    unsafe { ShellExecuteExW(&mut info)? };
    println!("{:8.1} ms  launched {exe}", ms(*START.get().unwrap()));
    pump_for(Duration::from_secs(3));
    unsafe {
        let _ = UnhookWinEvent(hk_fg);
        let _ = UnhookWinEvent(hk_show);
        if !info.hProcess.is_invalid() {
            let _ = CloseHandle(info.hProcess);
        }
    }
    println!("foreground after: {}", describe(foreground()));
    Ok(())
}

// ---------- simulated user ----------

fn type_into(hwnd: HWND, text: &str, gap_ms: u64) -> R {
    if !set_foreground(hwnd) {
        return Err("couldn't bring the window forward".into());
    }
    std::thread::sleep(Duration::from_millis(200));
    for unit in text.encode_utf16() {
        let make = |flags| INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 {
                ki: KEYBDINPUT { wVk: VIRTUAL_KEY(0), wScan: unit, dwFlags: flags, time: 0, dwExtraInfo: 0 },
            },
        };
        let inputs = [make(KEYEVENTF_UNICODE), make(KEYEVENTF_UNICODE | KEYEVENTF_KEYUP)];
        unsafe { SendInput(&inputs, size_of::<INPUT>() as i32) };
        std::thread::sleep(Duration::from_millis(gap_ms));
    }
    println!("typed {} chars", text.chars().count());
    Ok(())
}

fn tray_rect() -> R {
    unsafe {
        let hwnd = FindWindowW(windows::core::w!("BackgroundComputerUseTray"), PCWSTR::null())?;
        let id = NOTIFYICONIDENTIFIER { cbSize: size_of::<NOTIFYICONIDENTIFIER>() as u32, hWnd: hwnd, uID: 1, ..Default::default() };
        let r = Shell_NotifyIconGetRect(&id)?;
        println!("{} {} {} {}", r.left, r.top, r.right - r.left, r.bottom - r.top);
    }
    Ok(())
}

fn mouse(x: i32, y: i32, button: Option<&str>) -> R {
    unsafe {
        SetCursorPos(x, y)?;
        std::thread::sleep(Duration::from_millis(150));
        let (down, up) = match button {
            Some("right") => (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP),
            Some("left") => (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP),
            _ => return Ok(()),
        };
        let make = |flags| INPUT {
            r#type: INPUT_MOUSE,
            Anonymous: INPUT_0 { mi: MOUSEINPUT { dwFlags: flags, ..Default::default() } },
        };
        SendInput(&[make(down)], size_of::<INPUT>() as i32);
        std::thread::sleep(Duration::from_millis(60));
        SendInput(&[make(up)], size_of::<INPUT>() as i32);
    }
    Ok(())
}

fn tap(vk: VIRTUAL_KEY) -> R {
    let make = |flags| INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: vk, wScan: 0, dwFlags: flags, time: 0, dwExtraInfo: 0 } },
    };
    unsafe {
        SendInput(&[make(KEYBD_EVENT_FLAGS(0))], size_of::<INPUT>() as i32);
        std::thread::sleep(Duration::from_millis(40));
        SendInput(&[make(KEYEVENTF_KEYUP)], size_of::<INPUT>() as i32);
    }
    Ok(())
}
