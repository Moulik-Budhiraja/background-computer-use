//! The tray icon. Click it for the popover (a live preview of each agent's
//! monitor); right-click for Pause, Stop and Quit. Runs on the main thread's
//! message loop, which also runs the popover and the expanded view.

use std::sync::Mutex;
use std::time::{Duration, Instant};

use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::RemoteDesktop::{NOTIFY_FOR_THIS_SESSION, WTSRegisterSessionNotification};
use windows::Win32::System::Shutdown::LockWorkStation;
use windows::Win32::UI::HiDpi::GetSystemMetricsForDpi;
use windows::Win32::UI::Shell::*;
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::{PCWSTR, w};

use crate::gfx::{Canvas, rgb};
use crate::{engine, monitor, sessions, setup, ui, updater};

const WM_TRAY: u32 = WM_APP + 1;
const WM_APP_REFRESH: u32 = WM_APP + 2;
const ID_PAUSE: usize = 1;
const ID_STOP: usize = 2;
const ID_QUIT: usize = 3;
const ID_SETUP: usize = 4;
const ID_UPDATE: usize = 5;
const ICON_TIMER: usize = 1;

/// What the icon shows. Like the Mac's menu bar icon: one display shape with a
/// mark for each state.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Icon {
    Idle,
    Working,
    Waiting,
    Paused,
}

fn current() -> Icon {
    let views: Vec<_> = sessions::all().into_iter().filter(|v| v.visible()).collect();
    if views.iter().any(|v| v.handoff.is_some()) {
        Icon::Waiting
    } else if views.iter().any(|v| v.active()) {
        Icon::Working
    } else if views.iter().any(|v| v.paused) {
        Icon::Paused
    } else {
        Icon::Idle
    }
}

fn tooltip(icon: Icon) -> &'static str {
    match icon {
        Icon::Idle => "Background Computer Use",
        Icon::Working => "Agent working",
        Icon::Waiting => "Agent is waiting on you",
        Icon::Paused => "Agent paused",
    }
}

static HWND_SLOT: std::sync::Mutex<Option<usize>> = std::sync::Mutex::new(None);
static SHOWN: std::sync::Mutex<Option<(Icon, bool)>> = std::sync::Mutex::new(None);

/// Quit cleanly (from any thread): the installer and the updater ask for this.
pub fn request_quit() {
    post(WM_CLOSE);
}

fn post(msg: u32) {
    if let Some(h) = *HWND_SLOT.lock().unwrap_or_else(|e| e.into_inner()) {
        unsafe {
            let _ = PostMessageW(Some(HWND(h as *mut _)), msg, WPARAM(0), LPARAM(0));
        }
    }
}

/// Create the icon and run the message loop until Quit.
pub fn run() {
    unsafe {
        let instance = GetModuleHandleW(None).unwrap_or_default();
        let class = WNDCLASSW { lpfnWndProc: Some(wndproc), hInstance: instance.into(), lpszClassName: w!("BackgroundComputerUseTray"), ..Default::default() };
        RegisterClassW(&class);
        ui::register();
        // A hidden top-level window, not a message-only one: those miss
        // broadcasts like TaskbarCreated and theme changes.
        let hwnd = CreateWindowExW(
            WS_EX_TOOLWINDOW,
            w!("BackgroundComputerUseTray"),
            w!("Background Computer Use"),
            WS_POPUP,
            0,
            0,
            0,
            0,
            None,
            None,
            Some(instance.into()),
            None,
        )
        .expect("tray window");
        *HWND_SLOT.lock().unwrap() = Some(hwnd.0 as usize);
        sessions::on_change(|| post(WM_APP_REFRESH));
        let _ = WTSRegisterSessionNotification(hwnd, NOTIFY_FOR_THIS_SESSION);
        add_icon(hwnd);
        // The working state lasts a few seconds past each call; check it runs out.
        SetTimer(Some(hwnd), ICON_TIMER, 500, None);
        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        let nid = NOTIFYICONDATAW { cbSize: size_of::<NOTIFYICONDATAW>() as u32, hWnd: hwnd, uID: 1, ..Default::default() };
        let _ = Shell_NotifyIconW(NIM_DELETE, &nid);
    }
}

fn notify_data(hwnd: HWND, icon: Icon) -> NOTIFYICONDATAW {
    let mut nid = NOTIFYICONDATAW {
        cbSize: size_of::<NOTIFYICONDATAW>() as u32,
        hWnd: hwnd,
        uID: 1,
        uFlags: NIF_ICON | NIF_TIP | NIF_MESSAGE,
        uCallbackMessage: WM_TRAY,
        hIcon: make_icon(icon),
        ..Default::default()
    };
    let waiting = sessions::all().into_iter().find_map(|v| v.handoff);
    let text = match waiting {
        Some((app, reason)) if !reason.is_empty() => format!("{app}: {reason}"),
        _ => tooltip(icon).to_string(),
    };
    let tip: Vec<u16> = text.encode_utf16().take(nid.szTip.len() - 1).collect();
    nid.szTip[..tip.len()].copy_from_slice(&tip);
    nid
}

unsafe fn add_icon(hwnd: HWND) {
    let icon = current();
    let nid = notify_data(hwnd, icon);
    unsafe {
        let _ = Shell_NotifyIconW(NIM_ADD, &nid);
        let _ = DestroyIcon(nid.hIcon);
    }
    *SHOWN.lock().unwrap() = Some((icon, ui::light_theme()));
}

/// Update the icon if its state (or the taskbar's theme) changed.
unsafe fn refresh(hwnd: HWND, force: bool) {
    let icon = current();
    let light = ui::light_theme();
    let mut shown = SHOWN.lock().unwrap();
    if !force && *shown == Some((icon, light)) {
        return;
    }
    *shown = Some((icon, light));
    drop(shown);
    let nid = notify_data(hwnd, icon);
    unsafe {
        let _ = Shell_NotifyIconW(NIM_MODIFY, &nid);
        let _ = DestroyIcon(nid.hIcon);
    }
}

/// The Mac's menu bar glyph, drawn in the taskbar's text color: a display
/// outline, plus a cursor (working), a dot in a gap (waiting) or pause bars.
fn make_icon(icon: Icon) -> HICON {
    let size = unsafe { GetSystemMetricsForDpi(SM_CXSMICON, primary_dpi()) }.max(16);
    let c = Canvas::new_icon(size);
    let k = size as f32 / 18.0;
    let ink = if ui::light_theme() { rgb(0x1B1B1B) } else { rgb(0xFFFFFF) };
    // Snapped to whole pixels so the outline stays crisp at 16 px.
    let line = (1.5 * k).round().max(1.0);
    let (x0, y0) = ((1.0 * k).round(), (2.5 * k).round());
    let (x1, y1) = ((17.0 * k).round(), (14.0 * k).round());
    let display = |c: &Canvas| c.stroke_round(x0, y0, x1 - x0, y1 - y0, 2.25 * k, ink, line, None);
    match icon {
        Icon::Idle => display(&c),
        Icon::Working => {
            display(&c);
            let cursor: Vec<(f32, f32)> =
                [(9.6, 7.2), (9.6, 14.8), (11.5, 13.0), (12.8, 16.0), (14.1, 15.45), (12.8, 12.5), (15.4, 12.4)].iter().map(|(x, y)| (x * k, y * k)).collect();
            c.clear_polygon_outline(&cursor, 2.6 * k);
            c.fill_polygon(&cursor, ink);
        }
        Icon::Waiting => {
            display(&c);
            c.clear_circle(14.6 * k, 3.9 * k, 4.4 * k);
            c.fill_circle(14.6 * k, 3.9 * k, 2.6 * k, ink);
        }
        Icon::Paused => {
            display(&c);
            c.fill_round(6.4 * k, 5.9 * k, 1.8 * k, 4.7 * k, 0.6 * k, ink);
            c.fill_round(9.8 * k, 5.9 * k, 1.8 * k, 4.7 * k, 0.6 * k, ink);
        }
    }
    c.into_icon()
}

fn primary_dpi() -> u32 {
    unsafe {
        let dc = GetDC(None);
        let dpi = GetDeviceCaps(Some(dc), LOGPIXELSX);
        ReleaseDC(None, dc);
        dpi.max(96) as u32
    }
}

fn icon_rect(hwnd: HWND) -> RECT {
    let id = NOTIFYICONIDENTIFIER { cbSize: size_of::<NOTIFYICONIDENTIFIER>() as u32, hWnd: hwnd, uID: 1, ..Default::default() };
    unsafe {
        Shell_NotifyIconGetRect(&id).unwrap_or_else(|_| {
            let mut p = POINT::default();
            let _ = GetCursorPos(&mut p);
            RECT { left: p.x - 8, top: p.y - 8, right: p.x + 8, bottom: p.y + 8 }
        })
    }
}

unsafe fn show_menu(hwnd: HWND) {
    unsafe {
        let Ok(menu) = CreatePopupMenu() else { return };
        let paused = engine::all_paused();
        let pause_label = if paused { w!("Resume agents") } else { w!("Pause agents") };
        let _ = AppendMenuW(menu, MF_STRING, ID_PAUSE, pause_label);
        let _ = AppendMenuW(menu, MF_STRING, ID_STOP, w!("Stop agents"));
        let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null());
        let _ = AppendMenuW(menu, MF_STRING, ID_SETUP, w!("Set up…"));
        let update: Vec<u16> = match updater::pending() {
            Some(v) => format!("Restart to update to {v}"),
            None => "Check for updates".into(),
        }
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
        let _ = AppendMenuW(menu, MF_STRING, ID_UPDATE, PCWSTR(update.as_ptr()));
        let _ = AppendMenuW(menu, MF_STRING, ID_QUIT, w!("Quit"));
        let mut pt = POINT::default();
        let _ = GetCursorPos(&mut pt);
        // The menu closes properly only if our window is foreground while it's open.
        let _ = SetForegroundWindow(hwnd);
        let cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_BOTTOMALIGN, pt.x, pt.y, Some(0), hwnd, None);
        let _ = DestroyMenu(menu);
        match cmd.0 as usize {
            ID_PAUSE => engine::set_paused(None, !paused),
            ID_STOP => engine::stop(None),
            ID_SETUP => {
                std::thread::spawn(|| setup::run(false));
            }
            ID_UPDATE => update_action(),
            ID_QUIT => request_quit(),
            _ => {}
        }
    }
}

/// "Check for updates", or install the one that's ready.
pub fn update_action() {
    if updater::pending().is_some() {
        updater::install_now();
    } else {
        updater::check_now();
    }
}

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            WM_TRAY => {
                match (lparam.0 & 0xffff) as u32 {
                    WM_LBUTTONUP => ui::toggle_popover(icon_rect(hwnd)),
                    WM_RBUTTONUP | WM_CONTEXTMENU => show_menu(hwnd),
                    _ => {}
                }
                LRESULT(0)
            }
            WM_APP_REFRESH => {
                refresh(hwnd, false);
                ui::refresh();
                LRESULT(0)
            }
            WM_TIMER => {
                refresh(hwnd, false);
                LRESULT(0)
            }
            WM_CLOSE => {
                // Close the agents' windows (and give borrowed ones back) before quitting.
                engine::stop_for_quit(Duration::from_secs(10));
                PostQuitMessage(0);
                LRESULT(0)
            }
            WM_WTSSESSION_CHANGE => {
                session_changed(wparam.0 as u32);
                LRESULT(0)
            }
            WM_SETTINGCHANGE => {
                // The light/dark switch arrives as "ImmersiveColorSet".
                std::thread::sleep(Duration::from_millis(50));
                refresh(hwnd, true);
                LRESULT(0)
            }
            _ => {
                // Explorer restarted: put the icon back.
                if msg == taskbar_created() {
                    add_icon(hwnd);
                    return LRESULT(0);
                }
                DefWindowProcW(hwnd, msg, wparam, lparam)
            }
        }
    }
}

/// When Remote Desktop disconnects, the keep-drawing task (install-monitor.ps1)
/// moves the session onto the computer's own display so agents' windows keep
/// drawing. Lock it the moment it arrives: agents keep working on a locked
/// session (measured), and nobody at the computer can use it.
fn session_changed(event: u32) {
    const CONSOLE_CONNECT: u32 = 1;
    const REMOTE_CONNECT: u32 = 3;
    const REMOTE_DISCONNECT: u32 = 4;
    static DISCONNECTED: Mutex<Option<Instant>> = Mutex::new(None);
    let mut disconnected = DISCONNECTED.lock().unwrap_or_else(|e| e.into_inner());
    match event {
        REMOTE_DISCONNECT => *disconnected = Some(Instant::now()),
        // The task acts a few seconds after the disconnect. Someone signing in
        // at the computer comes later, through the sign-in screen.
        CONSOLE_CONNECT if disconnected.take().is_some_and(|t| t.elapsed() < Duration::from_secs(30)) => unsafe {
            let _ = LockWorkStation();
        },
        REMOTE_CONNECT => *disconnected = None,
        _ => {}
    }
    // The screens changed: place the agent monitors again if they're back.
    if matches!(event, CONSOLE_CONNECT | REMOTE_CONNECT) {
        std::thread::spawn(|| {
            std::thread::sleep(Duration::from_secs(2));
            monitor::arrange();
        });
    }
}

fn taskbar_created() -> u32 {
    static ID: std::sync::OnceLock<u32> = std::sync::OnceLock::new();
    *ID.get_or_init(|| unsafe { RegisterWindowMessageW(w!("TaskbarCreated")) })
}
