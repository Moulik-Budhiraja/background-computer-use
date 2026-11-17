//! The agent screen: where agents' windows live. A monitor that only exists
//! in software, from the open-source Virtual Display Driver
//! (github.com/VirtualDrivers/Virtual-Display-Driver, MIT). Windows draw on it
//! like on any monitor, and the user never sees it. Agents share it.
//!
//! It costs the compositor a whole extra display, which can bog down a weak or
//! hybrid-graphics laptop (four of them at 60 Hz made one unusable), so there
//! is one, at 30 Hz, on the graphics adapter that drives the user's main
//! screen, and setup checks the compositor keeps up once it's on
//! (`frame_time`, setup.rs). When it's off (the user turned it off, it slowed
//! the PC down, or it isn't set up), the driver's monitors are detached from
//! the desktop, the way the user's own display settings would (no admin
//! needed, and Windows remembers it), and agents can't open windows: they're
//! told why (setup::screen_problem).
//!
//! The monitor touches the user's screens only at a corner, so the pointer
//! can't drift onto it along an edge; the guard fences it off. A Remote
//! Desktop session can't see it (it belongs to the computer's own session),
//! so agents can't work there.

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
/// Agent monitors: one, shared by every agent session.
pub const WANTED: usize = 1;
/// The agent monitor's mode. Agents read windows a few times a second at most.
pub const WIDTH: i32 = 1600;
pub const HEIGHT: i32 = 1000;
pub const REFRESH_HZ: u32 = 30;

#[derive(Clone)]
pub struct Monitor {
    /// e.g. \\.\DISPLAY2
    pub device: Vec<u16>,
    pub rect: RECT,
}

/// The screens agents get: the agent monitor, if it's on.
fn usable() -> Vec<Monitor> {
    let mut ms = all();
    ms.truncate(WANTED);
    ms
}

/// Whether any part of `r` is on one of the user's screens (a display that
/// isn't an agent monitor).
pub fn on_user_screen(r: &RECT) -> bool {
    let agents: Vec<RECT> = all().iter().map(|m| m.rect).collect();
    user_screens(&agents).iter().any(|s| r.left < s.right && s.left < r.right && r.top < s.bottom && s.top < r.bottom)
}

/// The first screen an agent would get.
pub fn first() -> Option<Monitor> {
    usable().into_iter().next()
}

fn wide_to_string(w: &[u16]) -> String {
    let end = w.iter().position(|&c| c == 0).unwrap_or(w.len());
    String::from_utf16_lossy(&w[..end])
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// The driver's display devices, attached to the desktop or not: (device name, attached).
fn driver_devices() -> Vec<(Vec<u16>, bool)> {
    let mut out = Vec::new();
    unsafe {
        let mut i = 0;
        loop {
            let mut dev = DISPLAY_DEVICEW { cb: size_of::<DISPLAY_DEVICEW>() as u32, ..Default::default() };
            if !EnumDisplayDevicesW(PCWSTR::null(), i, &mut dev, 0).as_bool() {
                break;
            }
            i += 1;
            if wide_to_string(&dev.DeviceString).contains(DRIVER_NAME) {
                let end = dev.DeviceName.iter().position(|&c| c == 0).unwrap_or(dev.DeviceName.len());
                let mut device = dev.DeviceName[..end].to_vec();
                device.push(0);
                out.push((device, (dev.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP).0 != 0));
            }
        }
    }
    // DISPLAY10 after DISPLAY9.
    out.sort_by_key(|(d, _)| {
        let name = wide_to_string(d);
        let digits: String = name.chars().rev().take_while(|c| c.is_ascii_digit()).collect::<Vec<_>>().into_iter().rev().collect();
        (digits.parse::<u32>().unwrap_or(u32::MAX), name)
    });
    out
}

/// Every agent monitor that's on, in a stable order.
pub fn all() -> Vec<Monitor> {
    driver_devices()
        .into_iter()
        .filter(|(_, attached)| *attached)
        .filter_map(|(device, _)| unsafe {
            let mut dm = DEVMODEW { dmSize: size_of::<DEVMODEW>() as u16, ..Default::default() };
            if !EnumDisplaySettingsW(PCWSTR(device.as_ptr()), ENUM_CURRENT_SETTINGS, &mut dm).as_bool() {
                return None;
            }
            let pos = dm.Anonymous1.Anonymous2.dmPosition;
            let rect = RECT { left: pos.x, top: pos.y, right: pos.x + dm.dmPelsWidth as i32, bottom: pos.y + dm.dmPelsHeight as i32 };
            Some(Monitor { device, rect })
        })
        .collect()
}

/// Whether an agent monitor is on.
pub fn installed() -> bool {
    !all().is_empty()
}

/// Whether this is a Remote Desktop session rather than the computer's own
/// screen. The agent monitors belong to the computer's own session, so a
/// remote one can't see or use them.
pub fn remote_session() -> bool {
    use windows::Win32::System::RemoteDesktop::{ProcessIdToSessionId, WTSGetActiveConsoleSessionId};
    use windows::Win32::System::Threading::GetCurrentProcessId;
    use windows::Win32::UI::WindowsAndMessaging::{GetSystemMetrics, SM_REMOTESESSION};
    unsafe {
        let mut ours = 0u32;
        let console = WTSGetActiveConsoleSessionId();
        GetSystemMetrics(SM_REMOTESESSION) != 0 || (ProcessIdToSessionId(GetCurrentProcessId(), &mut ours).is_ok() && console != u32::MAX && ours != console)
    }
}

/// The driver's hardware ID, which its installer gives the device.
const DRIVER_HWID: &str = r"Root\MttVDD";

/// Whether the driver is installed, even when none of its monitors are on in
/// this session (over Remote Desktop, detached, or turned off in Display settings).
pub fn driver_installed() -> bool {
    use windows::Win32::System::Registry::*;
    use windows::core::PWSTR;
    unsafe {
        let mut key = HKEY::default();
        if RegOpenKeyExW(HKEY_LOCAL_MACHINE, w!(r"SYSTEM\CurrentControlSet\Enum\ROOT\DISPLAY"), Some(0), KEY_READ, &mut key).is_err() {
            return false;
        }
        let mut found = false;
        for i in 0.. {
            let mut name = [0u16; 256];
            let mut len = name.len() as u32;
            if RegEnumKeyExW(key, i, Some(PWSTR(name.as_mut_ptr())), &mut len, None, None, None, None).is_err() {
                break;
            }
            let mut ids = [0u16; 1024];
            let mut size = (ids.len() * 2) as u32;
            if RegGetValueW(key, PCWSTR(name.as_ptr()), w!("HardwareID"), RRF_RT_REG_MULTI_SZ, None, Some(ids.as_mut_ptr() as *mut _), Some(&mut size)).is_ok()
                && String::from_utf16_lossy(&ids[..size as usize / 2]).split('\0').any(|id| id.eq_ignore_ascii_case(DRIVER_HWID))
            {
                found = true;
                break;
            }
        }
        let _ = RegCloseKey(key);
        found
    }
}

/// Whether Windows started the installed driver: it has monitors, attached
/// to the desktop or not. A driver Windows stopped (Device Manager shows an
/// error, like code 43) has none.
pub fn driver_running() -> bool {
    !driver_devices().is_empty()
}

/// The graphics adapter driving the user's main screen, as Windows names it
/// (e.g. "Intel(R) UHD Graphics 620"): the agent monitor is drawn there too,
/// so frames never cross between two GPUs.
pub fn primary_adapter() -> Option<String> {
    unsafe {
        let mut i = 0;
        loop {
            let mut dev = DISPLAY_DEVICEW { cb: size_of::<DISPLAY_DEVICEW>() as u32, ..Default::default() };
            if !EnumDisplayDevicesW(PCWSTR::null(), i, &mut dev, 0).as_bool() {
                return None;
            }
            i += 1;
            if (dev.StateFlags & DISPLAY_DEVICE_PRIMARY_DEVICE).0 != 0 {
                let name = wide_to_string(&dev.DeviceString);
                return (!name.is_empty() && !name.contains(DRIVER_NAME)).then_some(name);
            }
        }
    }
}

/// The user's screens: every display that isn't an agent monitor.
fn user_screens(agents: &[RECT]) -> Vec<RECT> {
    unsafe extern "system" fn each(m: HMONITOR, _: HDC, _: *mut RECT, data: windows::Win32::Foundation::LPARAM) -> windows::core::BOOL {
        let (agents, out) = unsafe { &mut *(data.0 as *mut (Vec<RECT>, Vec<RECT>)) };
        let mut info = MONITORINFO { cbSize: size_of::<MONITORINFO>() as u32, ..Default::default() };
        unsafe {
            let _ = GetMonitorInfoW(m, &mut info);
        }
        if !agents.contains(&info.rcMonitor) {
            out.push(info.rcMonitor);
        }
        true.into()
    }
    let mut data: (Vec<RECT>, Vec<RECT>) = (agents.to_vec(), Vec::new());
    unsafe {
        let _ = EnumDisplayMonitors(None, None, Some(each), windows::Win32::Foundation::LPARAM(&mut data as *mut _ as isize));
    }
    data.1
}

/// Where the agent monitors go: in a row from the bottom-right corner of
/// the user's right-most screen. No user screen reaches past that screen's
/// right edge, so the row can't overlap one (a ScreenPad or a second screen
/// below, say), and it touches them only at that corner.
fn placement(user: &[RECT]) -> (i32, i32) {
    user.iter().max_by_key(|r| (r.right, r.bottom)).map(|r| (r.right, r.bottom)).unwrap_or((1920, 1080))
}

/// Takes `devices` off the desktop, as unchecking them in Display settings
/// would. Windows keeps that across restarts. Returns whether any came off.
fn detach(devices: &[Vec<u16>]) -> bool {
    let mut any = false;
    for device in devices {
        let mut dm = DEVMODEW { dmSize: size_of::<DEVMODEW>() as u16, ..Default::default() };
        // A position and a zero size: "detach this display".
        dm.dmFields = DM_POSITION | DM_PELSWIDTH | DM_PELSHEIGHT;
        let r = unsafe { ChangeDisplaySettingsExW(PCWSTR(device.as_ptr()), Some(&dm), None, CDS_UPDATEREGISTRY | CDS_NORESET, None) };
        any |= r == DISP_CHANGE_SUCCESSFUL;
    }
    if any {
        unsafe {
            let _ = ChangeDisplaySettingsExW(PCWSTR::null(), None, None, CDS_TYPE(0), None);
        }
    }
    any
}

/// Puts up to `n` detached agent monitors back on the desktop at (x, y), in a row.
fn attach(n: usize, at: (i32, i32)) -> bool {
    let off: Vec<Vec<u16>> = driver_devices().into_iter().filter(|(_, a)| !a).map(|(d, _)| d).take(n).collect();
    let mut any = false;
    for (i, device) in off.iter().enumerate() {
        let mut dm = DEVMODEW { dmSize: size_of::<DEVMODEW>() as u16, ..Default::default() };
        dm.dmFields = DM_POSITION | DM_PELSWIDTH | DM_PELSHEIGHT;
        dm.Anonymous1.Anonymous2.dmPosition = POINTL { x: at.0 + i as i32 * WIDTH, y: at.1 };
        dm.dmPelsWidth = WIDTH as u32;
        dm.dmPelsHeight = HEIGHT as u32;
        let r = unsafe { ChangeDisplaySettingsExW(PCWSTR(device.as_ptr()), Some(&dm), None, CDS_UPDATEREGISTRY | CDS_NORESET, None) };
        any |= r == DISP_CHANGE_SUCCESSFUL;
    }
    if any {
        unsafe {
            let _ = ChangeDisplaySettingsExW(PCWSTR::null(), None, None, CDS_TYPE(0), None);
        }
    }
    any
}

/// Sends a command to the driver (it listens on a pipe any user can write to).
pub fn driver_command(cmd: &str) -> bool {
    let msg = wide(cmd);
    unsafe {
        let Ok(pipe) = CreateFileW(w!(r"\\.\pipe\MTTVirtualDisplayPipe"), GENERIC_WRITE.0, FILE_SHARE_NONE, None, OPEN_EXISTING, FILE_FLAGS_AND_ATTRIBUTES(0), None)
        else {
            return false;
        };
        let bytes = std::slice::from_raw_parts(msg.as_ptr() as *const u8, (msg.len() - 1) * 2);
        let ok = WriteFile(pipe, Some(bytes), None, None).is_ok();
        let _ = windows::Win32::Foundation::CloseHandle(pipe);
        ok
    }
}

/// Waits (up to `limit`) until `done` holds.
fn wait_for(limit: Duration, done: impl Fn() -> bool) -> bool {
    let t = Instant::now();
    while t.elapsed() < limit {
        if done() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    done()
}

/// Make the agent monitors match the setting: with it off, none on the
/// desktop; with it on, `WANTED` of them, placed and fenced. Call at start,
/// before any agent has a window, and when the setting changes. Nothing
/// changes over Remote Desktop, where they can't be seen anyway.
pub fn apply_setting(on: bool) {
    if remote_session() {
        guard::set_fence(Vec::new());
        return;
    }
    let ms = all();
    if !on {
        if !ms.is_empty() {
            detach(&ms.iter().map(|m| m.device.clone()).collect::<Vec<_>>());
        }
        guard::set_fence(Vec::new());
        return;
    }
    if !driver_installed() {
        return;
    }
    if ms.len() > WANTED {
        detach(&ms[WANTED..].iter().map(|m| m.device.clone()).collect::<Vec<_>>());
    } else if ms.len() < WANTED {
        let at = placement(&user_screens(&[]));
        // A monitor the driver has but the desktop doesn't: put it back. If
        // the driver has none, reloading it brings its monitors up.
        if !attach(WANTED - ms.len(), at) {
            driver_command("RELOAD_DRIVER");
        }
        wait_for(Duration::from_secs(15), || all().len() >= WANTED);
        let now = all();
        if now.len() > WANTED {
            detach(&now[WANTED..].iter().map(|m| m.device.clone()).collect::<Vec<_>>());
        }
    }
    arrange();
}

/// The layout last asked for and what Windows made of it, so a layout it
/// won't take isn't asked for again (each ask resets every display).
static LAST_ASK: Mutex<Option<Vec<RECT>>> = Mutex::new(None);

/// Put the agent monitors in a row at the corner of the user's screens, fence
/// them off, and return the screens agents get now.
pub fn arrange() -> Vec<Monitor> {
    let mut ms = all();
    if ms.is_empty() {
        guard::set_fence(Vec::new());
        return ms;
    }
    let user = user_screens(&ms.iter().map(|m| m.rect).collect::<Vec<_>>());
    let (mut x, y) = placement(&user);
    let mut moved = false;
    let mut last = LAST_ASK.lock().unwrap_or_else(|e| e.into_inner());
    let mut wanted = Vec::new();
    for m in &ms {
        wanted.push(RECT { left: x, top: y, right: x + m.rect.right - m.rect.left, bottom: y + m.rect.bottom - m.rect.top });
        x += m.rect.right - m.rect.left;
    }
    if last.as_ref() != Some(&wanted) {
        for (m, r) in ms.iter().zip(&wanted) {
            if m.rect.left != r.left || m.rect.top != r.top {
                unsafe {
                    let mut dm = DEVMODEW { dmSize: size_of::<DEVMODEW>() as u16, ..Default::default() };
                    if EnumDisplaySettingsW(PCWSTR(m.device.as_ptr()), ENUM_CURRENT_SETTINGS, &mut dm).as_bool() {
                        dm.Anonymous1.Anonymous2.dmPosition = POINTL { x: r.left, y: r.top };
                        dm.dmFields = DM_POSITION;
                        let _ = ChangeDisplaySettingsExW(PCWSTR(m.device.as_ptr()), Some(&dm), None, CDS_UPDATEREGISTRY | CDS_NORESET, None);
                        moved = true;
                    }
                }
            }
        }
        *last = Some(wanted);
    }
    drop(last);
    if moved {
        unsafe {
            let _ = ChangeDisplaySettingsExW(PCWSTR::null(), None, None, CDS_TYPE(0), None);
        }
        ms = all();
    }
    // Each monitor fenced on its own: a box around several could cover the
    // user's screen if Windows put them somewhere else.
    guard::set_fence(ms.iter().map(|m| m.rect).collect());
    ms.truncate(WANTED);
    ms
}

/// Which screen each session has, by index into `usable()`.
static SLOTS: Mutex<Option<HashMap<String, usize>>> = Mutex::new(None);

/// The session's screen, giving it one the first time. With more sessions
/// than screens, they share. With no agent screen, why not, for the agent.
pub fn for_session(session: &str) -> Result<Monitor, String> {
    let ms = arrange();
    if ms.is_empty() {
        return Err(format!(
            "You have no screen to work on: {}",
            crate::setup::screen_problem().unwrap_or_else(|| "the agent screen isn't on.".into())
        ));
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

/// The screen the session has, if any, without claiming one.
pub fn of_session(session: &str) -> Option<Monitor> {
    let index = *SLOTS.lock().unwrap_or_else(|e| e.into_inner()).as_ref()?.get(session)?;
    usable().into_iter().nth(index)
}

/// The session is done with its screen.
pub fn release(session: &str) {
    if let Some(slots) = SLOTS.lock().unwrap_or_else(|e| e.into_inner()).as_mut() {
        slots.remove(session);
    }
}

pub fn name(m: &Monitor) -> String {
    wide_to_string(&m.device)
}

/// Every session's screen rect, in one pass.
pub fn slots() -> Vec<(String, RECT)> {
    let ms = usable();
    let slots = SLOTS.lock().unwrap_or_else(|e| e.into_inner());
    slots
        .as_ref()
        .map(|s| s.iter().filter_map(|(id, &i)| ms.get(i).map(|m| (id.clone(), m.rect))).collect())
        .unwrap_or_default()
}

/// How long the compositor takes to present a frame, as the median over
/// `over`, in ms: about 16.7 on a 60 Hz screen that keeps up. DwmFlush
/// waits for the next present, so a compositor that's falling behind shows
/// up here as it does to the user: everything updating slowly.
pub fn frame_time(over: Duration) -> f64 {
    use windows::Win32::Graphics::Dwm::DwmFlush;
    let mut samples = Vec::new();
    let t = Instant::now();
    while t.elapsed() < over {
        let s = Instant::now();
        if unsafe { DwmFlush() }.is_err() {
            std::thread::sleep(Duration::from_millis(16));
        }
        samples.push(s.elapsed().as_secs_f64() * 1000.0);
    }
    samples.sort_by(|a, b| a.total_cmp(b));
    samples.get(samples.len() / 2).copied().unwrap_or(0.0)
}

static READY: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// The screens are set up; calls can use them.
pub fn set_ready() {
    READY.store(true, std::sync::atomic::Ordering::Release);
}

/// Wait (up to 20 s) for the screens to be ready at start.
pub fn wait_ready() {
    let t = Instant::now();
    while !READY.load(std::sync::atomic::Ordering::Acquire) && t.elapsed() < Duration::from_secs(20) {
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn r(left: i32, top: i32, right: i32, bottom: i32) -> RECT {
        RECT { left, top, right, bottom }
    }

    #[test]
    fn placed_past_every_user_screen() {
        // A laptop screen with a ScreenPad below it, narrower and centered.
        let user = [r(0, 0, 1920, 1080), r(240, 1080, 1680, 1800)];
        assert_eq!(placement(&user), (1920, 1080));
        // A second screen to the left and lower down.
        let user = [r(0, 0, 2560, 1440), r(-1920, 400, 0, 1480)];
        assert_eq!(placement(&user), (2560, 1440));
        // Two screens with the same right edge: the lower one's corner.
        let user = [r(0, 0, 1920, 1080), r(0, 1080, 1920, 2160)];
        assert_eq!(placement(&user), (1920, 2160));
    }
}
