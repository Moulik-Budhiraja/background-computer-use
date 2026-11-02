//! Small Win32 helpers: window and process facts.

use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Dwm::*;
use windows::Win32::System::Threading::*;
use windows::Win32::UI::Shell::{ASSOCF_NONE, ASSOCSTR, ASSOCSTR_EXECUTABLE, ASSOCSTR_FRIENDLYAPPNAME, AssocQueryStringW};
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::{BOOL, PWSTR, w};

pub fn title(hwnd: HWND) -> String {
    let mut buf = [0u16; 512];
    let n = unsafe { GetWindowTextW(hwnd, &mut buf) };
    String::from_utf16_lossy(&buf[..n.max(0) as usize])
}

pub fn pid_tid(hwnd: HWND) -> (u32, u32) {
    let mut pid = 0u32;
    let tid = unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)) };
    (pid, tid)
}

pub fn exe_path(pid: u32) -> Option<String> {
    unsafe {
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let mut buf = [0u16; 1024];
        let mut len = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(process, PROCESS_NAME_WIN32, PWSTR(buf.as_mut_ptr()), &mut len);
        let _ = CloseHandle(process);
        ok.ok()?;
        Some(String::from_utf16_lossy(&buf[..len as usize]))
    }
}

/// "notepad.exe"
pub fn exe_name(pid: u32) -> String {
    exe_path(pid).map(|p| p.rsplit('\\').next().unwrap_or(&p).to_string()).unwrap_or_else(|| "?".into())
}

/// "Notepad": the executable's name without .exe, capitalized.
pub fn app_name(pid: u32) -> String {
    app_name_from_exe(&exe_name(pid))
}

pub fn app_name_from_exe(exe: &str) -> String {
    let stem = exe.strip_suffix(".exe").or_else(|| exe.strip_suffix(".EXE")).unwrap_or(exe);
    let mut c = stem.chars();
    c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
}

/// The visible frame in screen pixels, without the invisible resize borders.
pub fn frame(hwnd: HWND) -> RECT {
    let mut r = RECT::default();
    unsafe {
        if DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, &mut r as *mut _ as *mut _, size_of::<RECT>() as u32).is_err() {
            let _ = GetWindowRect(hwnd, &mut r);
        }
    }
    r
}

pub fn exists(hwnd: HWND) -> bool {
    unsafe { IsWindow(Some(hwnd)).as_bool() }
}

pub fn is_visible(hwnd: HWND) -> bool {
    unsafe { IsWindowVisible(hwnd).as_bool() }
}

pub fn is_minimized(hwnd: HWND) -> bool {
    unsafe { IsIconic(hwnd).as_bool() }
}

pub fn is_cloaked(hwnd: HWND) -> bool {
    let mut cloaked = 0u32;
    unsafe {
        let _ = DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &mut cloaked as *mut _ as *mut _, 4);
    }
    cloaked != 0
}

/// Windows a person would call windows: visible, unowned top-level, titled, not cloaked
/// (UWP frames on another virtual desktop are cloaked), and not tool windows.
pub fn is_app_window(hwnd: HWND) -> bool {
    unsafe {
        if !is_visible(hwnd) || is_cloaked(hwnd) || title(hwnd).is_empty() {
            return false;
        }
        if !GetWindow(hwnd, GW_OWNER).unwrap_or_default().0.is_null() {
            return false;
        }
        let ex = GetWindowLongW(hwnd, GWL_EXSTYLE) as u32;
        ex & WS_EX_TOOLWINDOW.0 == 0
    }
}

pub fn top_level_windows() -> Vec<HWND> {
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

pub fn foreground() -> HWND {
    unsafe { GetForegroundWindow() }
}

pub fn id(hwnd: HWND) -> u64 {
    hwnd.0 as usize as u64
}

pub fn from_id(id: u64) -> HWND {
    HWND(id as usize as *mut _)
}

fn assoc(kind: ASSOCSTR) -> Option<String> {
    unsafe {
        let mut buf = [0u16; 1024];
        let mut len = buf.len() as u32;
        AssocQueryStringW(ASSOCF_NONE, kind, w!("https"), w!("open"), Some(PWSTR(buf.as_mut_ptr())), &mut len).ok().ok()?;
        let s = String::from_utf16_lossy(&buf[..len as usize]);
        Some(s.trim_end_matches('\0').to_string())
    }
}

/// The user's default browser: (friendly name, executable path).
pub fn default_browser() -> Option<(String, String)> {
    let exe = assoc(ASSOCSTR_EXECUTABLE)?;
    let name = assoc(ASSOCSTR_FRIENDLYAPPNAME).unwrap_or_else(|| exe.rsplit('\\').next().unwrap_or(&exe).to_string());
    Some((name, exe))
}
