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

pub fn is_maximized(hwnd: HWND) -> bool {
    unsafe { IsZoomed(hwnd).as_bool() }
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

/// A process's integrity level (its mandatory label's RID), if it can be read.
fn integrity(process: HANDLE) -> Option<u32> {
    use windows::Win32::Security::{GetSidSubAuthority, GetSidSubAuthorityCount, GetTokenInformation, TOKEN_MANDATORY_LABEL, TOKEN_QUERY, TokenIntegrityLevel};
    unsafe {
        let mut token = HANDLE::default();
        OpenProcessToken(process, TOKEN_QUERY, &mut token).ok()?;
        let mut len = 0u32;
        let _ = GetTokenInformation(token, TokenIntegrityLevel, None, 0, &mut len);
        let mut buf = vec![0u8; len as usize];
        let ok = GetTokenInformation(token, TokenIntegrityLevel, Some(buf.as_mut_ptr() as *mut _), len, &mut len);
        let _ = CloseHandle(token);
        ok.ok()?;
        let label = &*(buf.as_ptr() as *const TOKEN_MANDATORY_LABEL);
        let count = *GetSidSubAuthorityCount(label.Label.Sid);
        Some(*GetSidSubAuthority(label.Label.Sid, count.checked_sub(1)? as u32))
    }
}

/// Whether `pid` runs above this app's integrity level (as administrator,
/// say): Windows then drops the app's moves and input to its windows (UIPI).
pub fn above_us(pid: u32) -> bool {
    unsafe {
        let Some(ours) = integrity(GetCurrentProcess()) else { return false };
        let Ok(process) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else { return false };
        let theirs = integrity(process);
        let _ = CloseHandle(process);
        theirs.is_some_and(|t| t > ours)
    }
}

/// Every running process's parent, by pid.
pub fn parents() -> std::collections::HashMap<u32, u32> {
    use windows::Win32::System::Diagnostics::ToolHelp::{CreateToolhelp32Snapshot, PROCESSENTRY32W, Process32FirstW, Process32NextW, TH32CS_SNAPPROCESS};
    let mut out = std::collections::HashMap::new();
    unsafe {
        let Ok(snap) = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) else { return out };
        let mut e = PROCESSENTRY32W { dwSize: size_of::<PROCESSENTRY32W>() as u32, ..Default::default() };
        let mut more = Process32FirstW(snap, &mut e).is_ok();
        while more {
            out.insert(e.th32ProcessID, e.th32ParentProcessID);
            more = Process32NextW(snap, &mut e).is_ok();
        }
        let _ = CloseHandle(snap);
    }
    out
}

/// Whether `pid` is one of `roots` or was started by one, directly or not.
pub fn descends_from(pid: u32, roots: &[u32], parents: &std::collections::HashMap<u32, u32>) -> bool {
    let mut p = pid;
    // Bounded: pids get reused, so the chain can loop.
    for _ in 0..32 {
        if p == 0 {
            return false;
        }
        if roots.contains(&p) {
            return true;
        }
        match parents.get(&p) {
            Some(&parent) if parent != p => p = parent,
            _ => return false,
        }
    }
    false
}

/// The processes of a window's child windows: a UWP app's frame belongs to
/// ApplicationFrameHost.exe, and the app's own window is a child of it.
pub fn child_pids(hwnd: HWND) -> Vec<u32> {
    unsafe extern "system" fn each(child: HWND, out: LPARAM) -> BOOL {
        let list = unsafe { &mut *(out.0 as *mut Vec<u32>) };
        let pid = pid_tid(child).0;
        if !list.contains(&pid) {
            list.push(pid);
        }
        true.into()
    }
    let mut list: Vec<u32> = Vec::new();
    unsafe {
        let _ = EnumChildWindows(Some(hwnd), Some(each), LPARAM(&mut list as *mut _ as isize));
    }
    list
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn process_trees() {
        // 10 started 11, which started 12; 20 is unrelated; 30 and 31 are each other's parent (reused pids).
        let parents = std::collections::HashMap::from([(11, 10), (12, 11), (20, 4), (30, 31), (31, 30)]);
        assert!(descends_from(12, &[10], &parents));
        assert!(descends_from(10, &[10], &parents));
        assert!(!descends_from(20, &[10], &parents));
        assert!(!descends_from(30, &[10], &parents));
        assert!(!descends_from(0, &[0], &parents));
    }
}
