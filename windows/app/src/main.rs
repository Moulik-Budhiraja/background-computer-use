//! Background Computer Use for Windows: the tray app.
#![windows_subsystem = "windows"]
//!
//! Serves the tools over a named pipe to `bcu mcp` (and host apps' requests,
//! host.rs), runs each agent session on the agent screen, and shows them in
//! the tray. Debug entry point:
//!   BackgroundComputerUse.exe --snapshot <hwnd> [max]

use background_computer_use::{gfx, guard, host, monitor, offscreen, pipe, serve, setup, snapshot, tray, updater};

use windows::Win32::Foundation::{HWND, RECT};
use windows::Win32::Graphics::Dwm::{DWMWA_EXTENDED_FRAME_BOUNDS, DwmGetWindowAttribute};
use windows::Win32::System::Com::{CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx};
use windows::Win32::UI::Accessibility::{CUIAutomation8, IUIAutomation};
use windows::Win32::UI::HiDpi::{DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, SetProcessDpiAwarenessContext};
use windows::Win32::UI::WindowsAndMessaging::{GetWindowTextW, GetWindowThreadProcessId};

fn main() {
    unsafe {
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
    }
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("--snapshot") {
        // A windowed app has no console; print to the one we were started from.
        unsafe {
            let _ = windows::Win32::System::Console::AttachConsole(windows::Win32::System::Console::ATTACH_PARENT_PROCESS);
        }
        let hwnd = parse_hwnd(args.get(1).map(String::as_str).unwrap_or(""));
        let max = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(250);
        if let Err(e) = debug_snapshot(hwnd, max) {
            eprintln!("snapshot failed: {e}");
            std::process::exit(2);
        }
        return;
    }
    if args.first().map(String::as_str) == Some("--virtual-screen") {
        // Ask the running app to turn the agent monitor on or off, as its menu does.
        tray::ask_running_for_virtual_screen(args.get(1).map(String::as_str) != Some("off"));
        return;
    }
    if args.first().map(String::as_str) == Some("--uninstall") {
        setup::uninstall(args.iter().any(|a| a == "--silent"));
        return;
    }
    // One engine per user. Another copy of the app runs it: this one exits. A
    // host app's runs it (`bcu serve`): it steps aside once its agents are
    // done, and this app takes over.
    if !serve::wait_turn() {
        return;
    }
    host::configure(host::APP_NAME, true);
    offscreen::start();
    guard::start();
    gfx::startup();
    updater::start(tray::request_quit);
    println!("serving {}", pipe::pipe_name());
    std::thread::spawn(move || {
        // Where this app is, so a host's `bcu serve` can start it.
        if let Err(e) = pipe::serve_then(serve::write_app_record) {
            eprintln!("Background Computer Use: {e}");
            std::process::exit(1);
        }
    });
    // The agent screen, as it should be (an older version's four are set up
    // again as one). Calls wait for this.
    std::thread::spawn(|| {
        setup::start_screen();
        monitor::set_ready();
        setup::on_launch();
    });
    tray::run();
}

fn parse_hwnd(s: &str) -> HWND {
    let v = s.strip_prefix("0x").map(|h| isize::from_str_radix(h, 16)).unwrap_or_else(|| s.parse()).unwrap_or(0);
    HWND(v as *mut _)
}

fn debug_snapshot(hwnd: HWND, max: usize) -> windows::core::Result<()> {
    let auto: IUIAutomation = unsafe { CoCreateInstance(&CUIAutomation8, None, CLSCTX_INPROC_SERVER)? };
    let mut title = [0u16; 512];
    let n = unsafe { GetWindowTextW(hwnd, &mut title) };
    let title = String::from_utf16_lossy(&title[..n.max(0) as usize]);
    let mut pid = 0;
    unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)) };
    let mut frame = RECT::default();
    unsafe {
        let _ = DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, &mut frame as *mut _ as *mut _, size_of::<RECT>() as u32);
    }
    let target = snapshot::Target { hwnd, title: &title, app: "app", pid, frame, popups: &[] };
    // Chromium builds its full tree only after a UIA client has asked once.
    let t = std::time::Instant::now();
    let first = snapshot::take(&auto, &target, max, None)?;
    println!("first read: {} visited in {:.0} ms", first.visited, t.elapsed().as_secs_f64() * 1000.0);
    std::thread::sleep(std::time::Duration::from_millis(1000));
    let t = std::time::Instant::now();
    let second = snapshot::take(&auto, &target, max, Some(&first))?;
    println!("second read: {} visited in {:.0} ms\n", second.visited, t.elapsed().as_secs_f64() * 1000.0);
    println!("{}", second.text);
    println!("\n--- diff from first read ---");
    println!("{}", snapshot::diff(&first, &second).unwrap_or_else(|| "(full listing would be sent)".into()));
    Ok(())
}
