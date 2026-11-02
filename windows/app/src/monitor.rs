//! The agent monitors: monitors that only exist in software, from the
//! open-source Virtual Display Driver (github.com/VirtualDrivers/Virtual-Display-Driver,
//! MIT), which the setup installs. Each agent session gets one to itself, so
//! its windows keep drawing (a covered or off-screen window stops), and the
//! user never sees them.
//!
//! The driver reloads every monitor when the count changes, which would throw
//! the windows on them onto the user's screen, so the count is set once, at
//! start, before any agent has a window. The monitors sit in a row touching the
//! user's screens only at their bottom-right corner, so the pointer can't drift
//! onto them along an edge; the guard fences them off.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use windows::Win32::Foundation::{GENERIC_WRITE, POINTL, RECT};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::Storage::FileSystem::{CreateFileW, FILE_FLAGS_AND_ATTRIBUTES, FILE_SHARE_NONE, OPEN_EXISTING, WriteFile};
use windows::core::{PCWSTR, w};

use crate::guard;

/// Name the driver's adapter reports (EnumDisplayDevices DeviceString).
const DRIVER_NAME: &str = "Virtual Display Driver";
/// How many agents can each have their own monitor.
pub const WANTED: usize = 4;

#[derive(Clone)]
pub struct Monitor {
    /// e.g. \\.\DISPLAY2
    pub device: Vec<u16>,
    pub rect: RECT,
}

fn wide_to_string(w: &[u16]) -> String {
    let end = w.iter().position(|&c| c == 0).unwrap_or(w.len());
    String::from_utf16_lossy(&w[..end])
}

/// Every virtual monitor that's on, in a stable order.
pub fn all() -> Vec<Monitor> {
    let mut out = Vec::new();
    unsafe {
        let mut i = 0;
        loop {
            let mut dev = DISPLAY_DEVICEW { cb: size_of::<DISPLAY_DEVICEW>() as u32, ..Default::default() };
            if !EnumDisplayDevicesW(PCWSTR::null(), i, &mut dev, 0).as_bool() {
                break;
            }
            i += 1;
            if !wide_to_string(&dev.DeviceString).contains(DRIVER_NAME) || (dev.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP).0 == 0 {
                continue;
            }
            let mut dm = DEVMODEW { dmSize: size_of::<DEVMODEW>() as u16, ..Default::default() };
            if !EnumDisplaySettingsW(PCWSTR(dev.DeviceName.as_ptr()), ENUM_CURRENT_SETTINGS, &mut dm).as_bool() {
                continue;
            }
            let pos = dm.Anonymous1.Anonymous2.dmPosition;
            let rect = RECT { left: pos.x, top: pos.y, right: pos.x + dm.dmPelsWidth as i32, bottom: pos.y + dm.dmPelsHeight as i32 };
            let end = dev.DeviceName.iter().position(|&c| c == 0).unwrap_or(dev.DeviceName.len());
            let mut device = dev.DeviceName[..end].to_vec();
            device.push(0);
            out.push(Monitor { device, rect });
        }
    }
    // DISPLAY10 after DISPLAY9.
    out.sort_by_key(|m| {
        let name = wide_to_string(&m.device);
        let digits: String = name.chars().rev().take_while(|c| c.is_ascii_digit()).collect::<Vec<_>>().into_iter().rev().collect();
        (digits.parse::<u32>().unwrap_or(u32::MAX), name)
    });
    out
}

/// Whether the driver is installed and has a monitor on.
pub fn installed() -> bool {
    !all().is_empty()
}

/// The primary monitor's rect.
fn primary() -> RECT {
    unsafe {
        let m = MonitorFromPoint(windows::Win32::Foundation::POINT { x: 0, y: 0 }, MONITOR_DEFAULTTOPRIMARY);
        let mut info = MONITORINFO { cbSize: size_of::<MONITORINFO>() as u32, ..Default::default() };
        let _ = GetMonitorInfoW(m, &mut info);
        info.rcMonitor
    }
}

/// The user's monitors (every one but the agents'), as one bounding box.
fn user_bounds(agents: &[RECT]) -> RECT {
    unsafe extern "system" fn each(m: HMONITOR, _: HDC, _: *mut RECT, data: windows::Win32::Foundation::LPARAM) -> windows::core::BOOL {
        let (agents, out) = unsafe { &mut *(data.0 as *mut (Vec<RECT>, Option<RECT>)) };
        let mut info = MONITORINFO { cbSize: size_of::<MONITORINFO>() as u32, ..Default::default() };
        unsafe {
            let _ = GetMonitorInfoW(m, &mut info);
        }
        let r = info.rcMonitor;
        if !agents.contains(&r) {
            *out = Some(match out {
                None => r,
                Some(u) => RECT { left: u.left.min(r.left), top: u.top.min(r.top), right: u.right.max(r.right), bottom: u.bottom.max(r.bottom) },
            });
        }
        true.into()
    }
    let mut data: (Vec<RECT>, Option<RECT>) = (agents.to_vec(), None);
    unsafe {
        let _ = EnumDisplayMonitors(None, None, Some(each), windows::Win32::Foundation::LPARAM(&mut data as *mut _ as isize));
    }
    data.1.unwrap_or_else(primary)
}

/// At start, before any agent has a window: ask the driver for one monitor per
/// agent if it has fewer. Changing the count reloads all of them.
pub fn ensure_count() {
    let have = all().len();
    if have == 0 || have >= WANTED {
        return;
    }
    let msg: Vec<u16> = format!("SETDISPLAYCOUNT {WANTED}").encode_utf16().chain(std::iter::once(0)).collect();
    unsafe {
        let Ok(pipe) = CreateFileW(w!(r"\\.\pipe\MTTVirtualDisplayPipe"), GENERIC_WRITE.0, FILE_SHARE_NONE, None, OPEN_EXISTING, FILE_FLAGS_AND_ATTRIBUTES(0), None)
        else {
            return;
        };
        let bytes = std::slice::from_raw_parts(msg.as_ptr() as *const u8, msg.len() * 2);
        let _ = WriteFile(pipe, Some(bytes), None, None);
        let _ = windows::Win32::Foundation::CloseHandle(pipe);
    }
    // The monitors go away and come back.
    let t = Instant::now();
    while t.elapsed() < Duration::from_secs(15) {
        std::thread::sleep(Duration::from_millis(250));
        if t.elapsed() > Duration::from_secs(2) && all().len() >= WANTED {
            break;
        }
    }
    arrange();
}

/// Put the monitors in a row from the bottom-right corner of the user's
/// screens, fence them off, and return them in their final places.
pub fn arrange() -> Vec<Monitor> {
    let mut ms = all();
    if ms.is_empty() {
        guard::set_fence(None);
        return ms;
    }
    let user = user_bounds(&ms.iter().map(|m| m.rect).collect::<Vec<_>>());
    let mut x = user.right;
    let mut moved = false;
    for m in &ms {
        if m.rect.left != x || m.rect.top != user.bottom {
            unsafe {
                let mut dm = DEVMODEW { dmSize: size_of::<DEVMODEW>() as u16, ..Default::default() };
                if EnumDisplaySettingsW(PCWSTR(m.device.as_ptr()), ENUM_CURRENT_SETTINGS, &mut dm).as_bool() {
                    dm.Anonymous1.Anonymous2.dmPosition = POINTL { x, y: user.bottom };
                    dm.dmFields = DM_POSITION;
                    let _ = ChangeDisplaySettingsExW(PCWSTR(m.device.as_ptr()), Some(&dm), None, CDS_UPDATEREGISTRY | CDS_NORESET, None);
                    moved = true;
                }
            }
        }
        x += m.rect.right - m.rect.left;
    }
    if moved {
        unsafe {
            let _ = ChangeDisplaySettingsExW(PCWSTR::null(), None, None, CDS_TYPE(0), None);
        }
        ms = all();
    }
    let fence = ms.iter().skip(1).fold(ms[0].rect, |u, m| RECT {
        left: u.left.min(m.rect.left),
        top: u.top.min(m.rect.top),
        right: u.right.max(m.rect.right),
        bottom: u.bottom.max(m.rect.bottom),
    });
    guard::set_fence(Some(fence));
    ms
}

/// Which monitor each session has, by index into `all()`.
static SLOTS: Mutex<Option<HashMap<String, usize>>> = Mutex::new(None);

/// The session's monitor, giving it a free one the first time. With more
/// sessions than monitors, the extra ones share.
pub fn for_session(session: &str) -> Result<Monitor, String> {
    let ms = arrange();
    if ms.is_empty() {
        return Err("The agent monitor isn't available: the Virtual Display Driver isn't installed or its monitor is off. Open Background Computer Use's setup to install it.".into());
    }
    let mut slots = SLOTS.lock().unwrap_or_else(|e| e.into_inner());
    let slots = slots.get_or_insert_with(HashMap::new);
    let index = match slots.get(session) {
        Some(&i) if i < ms.len() => i,
        _ => {
            let i = (0..ms.len()).find(|i| !slots.values().any(|v| v == i)).unwrap_or_else(|| {
                // All taken: the least shared one.
                (0..ms.len()).min_by_key(|i| slots.values().filter(|v| *v == i).count()).unwrap_or(0)
            });
            slots.insert(session.to_string(), i);
            i
        }
    };
    Ok(ms[index].clone())
}

/// The monitor the session has, if any, without claiming one.
pub fn of_session(session: &str) -> Option<Monitor> {
    let index = *SLOTS.lock().unwrap_or_else(|e| e.into_inner()).as_ref()?.get(session)?;
    all().into_iter().nth(index)
}

/// The session is done with its monitor.
pub fn release(session: &str) {
    if let Some(slots) = SLOTS.lock().unwrap_or_else(|e| e.into_inner()).as_mut() {
        slots.remove(session);
    }
}

pub fn name(m: &Monitor) -> String {
    wide_to_string(&m.device)
}

/// Every session's monitor rect, in one pass.
pub fn slots() -> Vec<(String, RECT)> {
    let ms = all();
    let slots = SLOTS.lock().unwrap_or_else(|e| e.into_inner());
    slots
        .as_ref()
        .map(|s| s.iter().filter_map(|(id, &i)| ms.get(i).map(|m| (id.clone(), m.rect))).collect())
        .unwrap_or_default()
}

static READY: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// The monitors are counted and placed; calls can use them.
pub fn set_ready() {
    READY.store(true, std::sync::atomic::Ordering::Release);
}

/// Wait (up to 20 s) for the monitors to be ready at start.
pub fn wait_ready() {
    let t = Instant::now();
    while !READY.load(std::sync::atomic::Ordering::Acquire) && t.elapsed() < Duration::from_secs(20) {
        std::thread::sleep(Duration::from_millis(50));
    }
}
