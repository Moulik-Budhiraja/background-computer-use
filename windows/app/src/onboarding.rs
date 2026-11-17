//! The first-run window, like the Mac app's onboarding (Onboarding.swift):
//! what the app does, setting up the agent screen, connecting Claude Code and
//! Codex, and where to find it afterwards. Windows needs no permissions, so
//! those steps aren't here; the agent screen takes their place.
//!
//! Runs on the tray's thread; slow work (finding agents, connecting them,
//! setting up the agent screen) runs on its own thread and updates `MODEL`,
//! then asks the tray thread to redraw.

use std::sync::Mutex;

use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Dwm::{DWMWA_USE_IMMERSIVE_DARK_MODE, DwmSetWindowAttribute};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Registry::{HKEY_CURRENT_USER, RRF_RT_REG_DWORD, RegGetValueW};
use windows::Win32::UI::HiDpi::{AdjustWindowRectExForDpi, GetDpiForWindow};
use windows::Win32::UI::Input::KeyboardAndMouse::{TME_LEAVE, TRACKMOUSEEVENT, TrackMouseEvent, VK_ESCAPE, VK_RETURN};
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::{PCWSTR, w};

use crate::gfx::{Align, Canvas, Font, rgb, rgba};
use crate::{monitor, setup};

const CLASS: PCWSTR = w!("BCUOnboarding");
const W: f32 = 640.0;
const H: f32 = 500.0;
const FOOTER: f32 = 64.0;
const WM_MOUSELEAVE: u32 = 0x02A3;

#[derive(Clone, Copy, PartialEq, Debug)]
enum Step {
    Welcome,
    Screen,
    Connect,
    Done,
}

const STEPS: [Step; 4] = [Step::Welcome, Step::Screen, Step::Connect, Step::Done];

/// What the window shows. Shared with the threads doing the slow work.
struct Model {
    hwnd: usize,
    step: Step,
    hover: Option<Button>,
    tracking: bool,
    /// Why agents have no screen; None when it's on.
    screen_problem: Option<String>,
    setting_up: bool,
    screen_note: Option<(bool, String)>,
    /// None while looking for them.
    agents: Option<[setup::Agent; 2]>,
    connecting: bool,
    connect_note: Option<(bool, String)>,
    copied: bool,
    open_at_sign_in: bool,
}

static MODEL: Mutex<Option<Model>> = Mutex::new(None);

fn with<R>(f: impl FnOnce(&mut Model) -> R) -> Option<R> {
    MODEL.lock().unwrap_or_else(|e| e.into_inner()).as_mut().map(f)
}

fn hwnd() -> Option<HWND> {
    with(|m| HWND(m.hwnd as *mut _))
}

/// Redraw (tray thread). Worker threads call `crate::tray::refresh_windows`.
pub fn refresh() {
    if let Some(h) = hwnd() {
        unsafe {
            let _ = InvalidateRect(Some(h), None, false);
        }
    }
}


fn find_agents() {
    std::thread::spawn(|| {
        let agents = setup::agents();
        with(|m| m.agents = Some(agents));
        crate::tray::refresh_windows();
    });
}

/// Show the window, or bring it forward if it's open. `at_screen` starts at
/// the agent screen's step: everything else was set up before.
pub fn open(at_screen: bool) {
    if let Some(h) = hwnd() {
        unsafe {
            let _ = ShowWindow(h, SW_RESTORE);
            let _ = SetForegroundWindow(h);
        }
        return;
    }
    unsafe {
        let instance = GetModuleHandleW(None).unwrap_or_default();
        static REGISTERED: std::sync::Once = std::sync::Once::new();
        REGISTERED.call_once(|| {
            let class = WNDCLASSW {
                lpfnWndProc: Some(proc_),
                hInstance: instance.into(),
                lpszClassName: CLASS,
                hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
                hIcon: LoadIconW(Some(instance.into()), PCWSTR(1 as _)).unwrap_or_default(),
                ..Default::default()
            };
            RegisterClassW(&class);
        });
        let style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
        let Ok(hwnd) = CreateWindowExW(
            WS_EX_APPWINDOW,
            CLASS,
            w!("Set Up Background Computer Use"),
            style,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            100,
            100,
            None,
            None,
            Some(instance.into()),
            None,
        ) else {
            return;
        };
        *MODEL.lock().unwrap_or_else(|e| e.into_inner()) = Some(Model {
            hwnd: hwnd.0 as usize,
            step: if at_screen { Step::Screen } else { Step::Welcome },
            hover: None,
            tracking: false,
            screen_problem: setup::screen_problem(),
            setting_up: false,
            screen_note: None,
            agents: None,
            connecting: false,
            connect_note: None,
            copied: false,
            open_at_sign_in: true,
        });
        find_agents();
        place(hwnd);
        let dark: i32 = (!apps_light()) as i32;
        let _ = DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark as *const _ as *const _, 4);
        let _ = ShowWindow(hwnd, SW_SHOW);
        let _ = SetForegroundWindow(hwnd);
    }
}

/// Size the window for its DPI and center it in the work area it's on.
fn place(hwnd: HWND) {
    unsafe {
        let dpi = GetDpiForWindow(hwnd).max(96);
        let s = dpi as f32 / 96.0;
        let mut r = RECT { left: 0, top: 0, right: (W * s).round() as i32, bottom: (H * s).round() as i32 };
        let _ = AdjustWindowRectExForDpi(&mut r, WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX, false, WS_EX_APPWINDOW, dpi);
        let (w, h) = (r.right - r.left, r.bottom - r.top);
        let m = MonitorFromWindow(hwnd, MONITOR_DEFAULTTOPRIMARY);
        let mut info = MONITORINFO { cbSize: size_of::<MONITORINFO>() as u32, ..Default::default() };
        let _ = GetMonitorInfoW(m, &mut info);
        let work = info.rcWork;
        let x = work.left + (work.right - work.left - w) / 2;
        let y = work.top + (work.bottom - work.top - h) / 2;
        let _ = SetWindowPos(hwnd, None, x, y, w, h, SWP_NOZORDER | SWP_NOACTIVATE);
    }
}

/// Apps' light or dark setting (not the taskbar's).
fn apps_light() -> bool {
    let mut v = 1u32;
    let mut n = 4u32;
    unsafe {
        let _ = RegGetValueW(
            HKEY_CURRENT_USER,
            w!(r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"),
            w!("AppsUseLightTheme"),
            RRF_RT_REG_DWORD,
            None,
            Some(&mut v as *mut _ as *mut _),
            Some(&mut n),
        );
    }
    v != 0
}

// ---------- look ----------

struct Theme {
    dark: bool,
    ground: u32,
    stage: u32,
    text: u32,
    secondary: u32,
    hairline: u32,
    accent: u32,
    on_accent: u32,
    button: u32,
    button_hover: u32,
    card: u32,
}

fn theme() -> Theme {
    if apps_light() {
        Theme {
            dark: false,
            ground: rgb(0xF3F3F3),
            stage: rgb(0xE6EBF1),
            text: rgba(0x000000, 0.9),
            secondary: rgba(0x000000, 0.6),
            hairline: rgba(0x000000, 0.1),
            accent: rgb(0x005FB8),
            on_accent: rgb(0xFFFFFF),
            button: rgb(0xFBFBFB),
            button_hover: rgb(0xF0F0F0),
            card: rgb(0xFFFFFF),
        }
    } else {
        Theme {
            dark: true,
            ground: rgb(0x202020),
            stage: rgb(0x2B2D31),
            text: rgba(0xFFFFFF, 0.92),
            secondary: rgba(0xFFFFFF, 0.62),
            hairline: rgba(0xFFFFFF, 0.1),
            accent: rgb(0x60CDFF),
            on_accent: rgb(0x000000),
            button: rgba(0xFFFFFF, 0.06),
            button_hover: rgba(0xFFFFFF, 0.1),
            card: rgb(0x323438),
        }
    }
}

const LIVE: u32 = 0x2FB457;
const NEEDS: u32 = 0xF09A0A;

// ---------- layout ----------

#[derive(Clone, Copy, PartialEq, Debug)]
enum Button {
    Primary,
    Secondary,
    Back,
    Link,
    Check,
}

#[derive(Clone, Copy)]
struct R {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
}

impl R {
    fn contains(&self, x: f32, y: f32) -> bool {
        x >= self.x && x < self.x + self.w && y >= self.y && y < self.y + self.h
    }
}

/// What the buttons say right now; None means the button isn't there.
struct Labels {
    primary: (String, bool),
    secondary: Option<String>,
    back: bool,
    link: Option<String>,
}

/// Whether the agent screen step can offer to set it up here (not over
/// Remote Desktop, which can't show it).
fn can_set_up(m: &Model) -> bool {
    m.screen_problem.is_some() && !monitor::remote_session()
}

fn labels(m: &Model) -> Labels {
    match m.step {
        Step::Welcome => Labels { primary: ("Get Started".into(), true), secondary: None, back: false, link: None },
        Step::Screen => {
            if m.setting_up {
                Labels { primary: ("Setting Up…".into(), false), secondary: None, back: false, link: None }
            } else if can_set_up(m) {
                Labels { primary: ("Set Up Agent Screen".into(), true), secondary: Some("Later".into()), back: true, link: None }
            } else {
                Labels { primary: ("Continue".into(), true), secondary: None, back: true, link: None }
            }
        }
        Step::Connect => {
            let to_connect = m.agents.is_some_and(|a| a.iter().any(|a| a.found && !a.connected));
            let primary = if m.connecting {
                ("Connecting…".into(), false)
            } else if to_connect {
                ("Connect".into(), true)
            } else {
                ("Continue".into(), true)
            };
            let link = Some(if m.copied { "Copied".into() } else { "Other agent? Copy the MCP command".into() });
            Labels { primary, secondary: to_connect.then(|| "Skip".into()), back: !m.connecting, link }
        }
        Step::Done => Labels { primary: ("Done".into(), true), secondary: None, back: false, link: None },
    }
}

/// Where each button is, in logical pixels.
fn buttons(c: &Canvas, m: &Model) -> Vec<(Button, R, bool)> {
    let l = labels(m);
    let mut out = Vec::new();
    let y = H - FOOTER + (FOOTER - 32.0) / 2.0;
    let width = |text: &str| (c.measure(text, Font::Semibold, 13.0) + 40.0).max(96.0);
    let mut x = W - 24.0;
    let pw = width(&l.primary.0);
    x -= pw;
    out.push((Button::Primary, R { x, y, w: pw, h: 32.0 }, l.primary.1));
    if let Some(s) = &l.secondary {
        let sw = width(s);
        x -= 8.0 + sw;
        out.push((Button::Secondary, R { x, y, w: sw, h: 32.0 }, true));
    }
    if l.back {
        let bw = width("Back");
        x -= 8.0 + bw;
        out.push((Button::Back, R { x, y, w: bw, h: 32.0 }, true));
    }
    if let Some(link) = &l.link {
        let lw = c.measure(link, Font::Semibold, 12.0) + 4.0;
        out.push((Button::Link, R { x: 40.0, y: COPY_Y + 92.0, w: lw, h: 20.0 }, true));
    }
    if m.step == Step::Done {
        let cw = 18.0 + 8.0 + c.measure("Open at sign-in", Font::Regular, 13.0);
        out.push((Button::Check, R { x: 24.0, y: H - FOOTER / 2.0 - 12.0, w: cw, h: 24.0 }, true));
    }
    out
}

const STAGE: R = R { x: 24.0, y: 16.0, w: W - 48.0, h: 236.0 };
const COPY_Y: f32 = 276.0;

// ---------- actions ----------

fn go(step: Step) {
    with(|m| {
        m.step = step;
        m.hover = None;
        if step == Step::Screen && !m.setting_up {
            m.screen_problem = setup::screen_problem();
        }
    });
}

fn back_step(s: Step) -> Step {
    STEPS[STEPS.iter().position(|x| *x == s).unwrap_or(1).saturating_sub(1)]
}

fn press(b: Button) {
    let Some((step, set_up, connecting, setting_up)) = with(|m| (m.step, can_set_up(m), m.connecting, m.setting_up)) else { return };
    match (b, step) {
        (Button::Primary, Step::Welcome) => go(Step::Screen),
        (Button::Primary, Step::Screen) if set_up && !setting_up => {
            with(|m| {
                m.setting_up = true;
                m.screen_note = None;
            });
            std::thread::spawn(|| {
                let result = setup::enable_screen();
                with(|m| {
                    m.setting_up = false;
                    m.screen_problem = setup::screen_problem();
                    // The heading says it's on; only a failure needs a note.
                    m.screen_note = result.err().map(|e| (false, e));
                });
                crate::tray::refresh_windows();
            });
        }
        (Button::Primary, Step::Screen) if !setting_up => go(Step::Connect),
        (Button::Secondary, Step::Screen) => go(Step::Connect),
        (Button::Primary, Step::Connect) => {
            let to_connect = with(|m| m.agents.is_some_and(|a| a.iter().any(|a| a.found && !a.connected))).unwrap_or(false);
            if to_connect && !connecting {
                with(|m| {
                    m.connecting = true;
                    m.connect_note = None;
                });
                std::thread::spawn(|| {
                    let lines = setup::connect_agents();
                    let agents = setup::agents();
                    let failed: Vec<&String> = lines.iter().filter(|l| l.starts_with("Claude Code:") && !l.contains("skipped") || l.starts_with("Codex:") && !l.contains("skipped")).collect();
                    with(|m| {
                        m.connecting = false;
                        m.agents = Some(agents);
                        m.connect_note = Some(match failed.first() {
                            Some(e) => (false, e.to_string()),
                            None => (true, "Connected. Restart the agent if it's open, so it picks this up.".into()),
                        });
                    });
                    crate::tray::refresh_windows();
                });
            } else if !connecting {
                go(Step::Done);
            }
        }
        (Button::Secondary, Step::Connect) => go(Step::Done),
        (Button::Link, Step::Connect) => {
            setup::copy_text(&setup::mcp_command());
            with(|m| m.copied = true);
        }
        (Button::Back, s) => go(back_step(s)),
        (Button::Check, Step::Done) => {
            with(|m| m.open_at_sign_in = !m.open_at_sign_in);
        }
        (Button::Primary, Step::Done) => finish(true),
        _ => {}
    }
    refresh();
}

/// Done, or the window closed: don't show it again at start. Closed the
/// first time, the app still starts at sign-in, as setup always did; the
/// last step is where that's changed.
fn finish(done: bool) {
    let taken = MODEL.lock().unwrap_or_else(|e| e.into_inner()).take();
    let Some(m) = taken else { return };
    if done {
        setup::set_start_at_sign_in(m.open_at_sign_in);
    } else if !setup::onboarded() {
        setup::set_start_at_sign_in(true);
    }
    setup::set_onboarded();
    unsafe {
        let _ = DestroyWindow(HWND(m.hwnd as *mut _));
    }
}

// ---------- drawing ----------

fn paint(hwnd: HWND) {
    let s = unsafe { GetDpiForWindow(hwnd).max(96) } as f32 / 96.0;
    let mut rc = RECT::default();
    unsafe {
        let _ = GetClientRect(hwnd, &mut rc);
    }
    let c = Canvas::new(rc.right, rc.bottom, s);
    let t = theme();
    c.clear(t.ground);
    let guard = MODEL.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(m) = guard.as_ref() {
        c.fill_round(STAGE.x, STAGE.y, STAGE.w, STAGE.h, 12.0, t.stage);
        match m.step {
            Step::Welcome => art_welcome(&c, &t),
            Step::Screen => art_screen(&c, &t, m),
            Step::Connect => art_connect(&c, &t, m),
            Step::Done => art_done(&c, &t),
        }
        copy(&c, &t, m);
        footer(&c, &t, m);
    }
    drop(guard);
    unsafe {
        let mut ps = PAINTSTRUCT::default();
        let hdc = BeginPaint(hwnd, &mut ps);
        c.present(hdc);
        let _ = EndPaint(hwnd, &ps);
    }
}

/// "the agent screen isn't on." as a sentence of its own.
fn sentence(s: &str) -> String {
    let mut c = s.chars();
    c.next().map(|f| f.to_uppercase().chain(c).collect()).unwrap_or_default()
}

fn copy(c: &Canvas, t: &Theme, m: &Model) {
    let (title, line): (String, String) = match m.step {
        Step::Welcome => (
            "Your agents get their own screen".into(),
            "They work in their own windows, on a screen that only exists in software. You never see it, and you keep using your PC.".into(),
        ),
        Step::Screen if m.setting_up => (
            "Setting up the agent screen".into(),
            "If Windows asks for permission, choose Yes. Your display may blink, then the app checks your PC keeps up.".into(),
        ),
        Step::Screen if m.screen_problem.is_none() => (
            "The agent screen is on".into(),
            "Agents work there at 30 frames a second, on the graphics chip that drives your screen. If your PC ever slows down with it on, it turns itself off.".into(),
        ),
        Step::Screen if monitor::remote_session() => (
            "Set up at the computer".into(),
            "Remote Desktop can't show the agent screen, so agents can't work here. When you're at the computer, choose Set up… from the tray icon.".into(),
        ),
        Step::Screen if !monitor::driver_installed() => (
            "Set up the agent screen".into(),
            "Windows asks for permission once, to install the Virtual Display Driver. Your display may blink. Then the app checks your PC keeps up; if it slows down, the screen turns itself off.".into(),
        ),
        Step::Screen => ("The agent screen is off".into(), sentence(m.screen_problem.as_deref().unwrap_or_default())),
        Step::Connect if m.agents.is_some_and(|a| !a.iter().any(|a| a.found)) => (
            "Connect your agents".into(),
            "Claude Code and Codex aren't on this PC yet. Install one, then choose Set up… from the tray icon to connect it.".into(),
        ),
        Step::Connect => ("Connect your agents".into(), "Give Claude Code and Codex on this PC the tools to use your apps.".into()),
        Step::Done => ("You're ready".into(), "Ask an agent to use any app. Click the tray icon to watch it work, or to pause and stop agents.".into()),
    };
    c.text(&title, 40.0, COPY_Y + 16.0, W - 80.0, Font::Title, 26.0, t.text, Align::Left);
    let h = c.paragraph(&line, 40.0, COPY_Y + 40.0, W - 80.0, Font::Regular, 13.5, t.secondary);
    let note = match m.step {
        Step::Screen => m.screen_note.clone(),
        Step::Connect => m.connect_note.clone(),
        _ => None,
    };
    if let Some((ok, text)) = note {
        let color = if ok { rgb(if t.dark { 0x6CCB5F } else { 0x0F7B0F }) } else { rgb(if t.dark { 0xFF99A4 } else { 0xC42B1C }) };
        c.paragraph(&text, 40.0, COPY_Y + 48.0 + h, W - 80.0, Font::Semibold, 12.0, color);
    }
}

fn footer(c: &Canvas, t: &Theme, m: &Model) {
    c.fill_rect(0.0, H - FOOTER, W, 0.5, t.hairline);
    if m.step != Step::Done {
        let i = STEPS.iter().position(|s| *s == m.step).unwrap_or(0);
        for d in 0..3 {
            let color = if d == i { t.text } else { t.hairline };
            c.fill_circle(30.0 + d as f32 * 14.0, H - FOOTER / 2.0, 3.5, color);
        }
    }
    for (b, r, enabled) in buttons(c, m) {
        let hovered = m.hover == Some(b) && enabled;
        let l = labels(m);
        match b {
            Button::Primary => {
                let fill = if enabled { t.accent } else { (t.accent & 0x00FF_FFFF) | 0x6600_0000 };
                c.fill_round(r.x, r.y, r.w, r.h, 5.0, fill);
                if hovered {
                    c.fill_round(r.x, r.y, r.w, r.h, 5.0, rgba(if t.dark { 0x000000 } else { 0xFFFFFF }, 0.1));
                }
                c.text(&l.primary.0, r.x + r.w / 2.0, r.y + r.h / 2.0, r.w, Font::Semibold, 13.0, t.on_accent, Align::Center);
            }
            Button::Secondary | Button::Back => {
                let text = if b == Button::Back { "Back".to_string() } else { l.secondary.clone().unwrap_or_default() };
                c.fill_round(r.x, r.y, r.w, r.h, 5.0, if hovered { t.button_hover } else { t.button });
                c.stroke_round(r.x, r.y, r.w, r.h, 5.0, t.hairline, 1.0, None);
                c.text(&text, r.x + r.w / 2.0, r.y + r.h / 2.0, r.w, Font::Semibold, 13.0, t.text, Align::Center);
            }
            Button::Link => {
                let text = l.link.clone().unwrap_or_default();
                let color = if hovered { (t.accent & 0x00FF_FFFF) | 0xCC00_0000 } else { t.accent };
                c.text(&text, r.x, r.y + r.h / 2.0, r.w + 4.0, Font::Semibold, 12.0, color, Align::Left);
            }
            Button::Check => {
                let (bx, by) = (r.x, r.y + (r.h - 18.0) / 2.0);
                if m.open_at_sign_in {
                    c.fill_round(bx, by, 18.0, 18.0, 4.0, t.accent);
                    c.glyph(0xE73E, bx + 9.0, by + 9.0, 12.0, t.on_accent);
                } else {
                    c.fill_round(bx, by, 18.0, 18.0, 4.0, t.button);
                    c.stroke_round(bx, by, 18.0, 18.0, 4.0, t.secondary, 1.0, None);
                }
                c.text("Open at sign-in", bx + 26.0, r.y + r.h / 2.0, r.w, Font::Regular, 13.0, t.text, Align::Left);
            }
        }
    }
}

/// A screen: bezel, wallpaper, taskbar.
fn screen(c: &Canvas, t: &Theme, x: f32, y: f32, w: f32, h: f32) {
    c.fill_round(x - 5.0, y - 5.0, w + 10.0, h + 10.0, 9.0, rgb(if t.dark { 0x111214 } else { 0x2A2D33 }));
    c.fill_round(x, y, w, h, 4.0, rgb(if t.dark { 0x1F3C5C } else { 0x9CC3E8 }));
    c.fill_rect(x, y + h - 12.0, w, 12.0, rgba(if t.dark { 0x1C1C1C } else { 0xF3F3F3 }, 0.92));
    for i in 0..4 {
        c.fill_round(x + w / 2.0 - 26.0 + i as f32 * 14.0, y + h - 9.0, 8.0, 6.0, 1.5, rgba(0x000000, 0.25));
    }
    // Stand.
    c.fill_round(x + w / 2.0 - 18.0, y + h + 5.0, 36.0, 10.0, 2.0, rgb(if t.dark { 0x111214 } else { 0x2A2D33 }));
    c.fill_round(x + w / 2.0 - 34.0, y + h + 14.0, 68.0, 5.0, 2.5, rgb(if t.dark { 0x111214 } else { 0x2A2D33 }));
}

/// An app window: title bar and a few lines.
fn window(c: &Canvas, x: f32, y: f32, w: f32, h: f32, dark: bool) {
    c.fill_round(x, y + 1.5, w, h, 4.0, rgba(0x000000, 0.18));
    c.fill_round(x, y, w, h, 4.0, rgb(if dark { 0x2B2B2B } else { 0xFFFFFF }));
    c.fill_rect(x, y + 10.0, w, 0.5, rgba(if dark { 0xFFFFFF } else { 0x000000 }, 0.1));
    let ink = rgba(if dark { 0xFFFFFF } else { 0x000000 }, 0.16);
    for (i, frac) in [0.7f32, 0.5, 0.62].iter().enumerate() {
        c.fill_round(x + 8.0, y + 18.0 + i as f32 * 9.0, (w - 16.0) * frac, 4.0, 2.0, ink);
    }
}

/// The agent's pointer, tip at (x, y).
fn pointer(c: &Canvas, x: f32, y: f32, k: f32) {
    let pts: Vec<(f32, f32)> = [(0.0, 0.0), (0.0, 16.6), (4.0, 12.9), (6.6, 18.9), (9.3, 17.8), (6.8, 11.9), (12.0, 11.9)]
        .iter()
        .map(|(px, py)| (x + px * k, y + py * k))
        .collect();
    c.fill_polygon(&pts, rgb(0xFFFFFF));
    c.stroke_polygon(&pts, rgb(0x111111), 1.0);
}

fn caption(c: &Canvas, t: &Theme, text: &str, cx: f32, y: f32) {
    c.text(text, cx, y, 220.0, Font::Semibold, 12.0, t.secondary, Align::Center);
}

fn art_welcome(c: &Canvas, t: &Theme) {
    // The user's screen, untouched.
    let (sx, sy, sw, sh) = (78.0, 46.0, 250.0, 152.0);
    screen(c, t, sx, sy, sw, sh);
    window(c, sx + 26.0, sy + 22.0, 130.0, 86.0, t.dark);
    window(c, sx + 120.0, sy + 44.0, 104.0, 70.0, t.dark);
    caption(c, t, "Your screen", sx + sw / 2.0, sy + sh + 34.0);
    // The agent's windows, out of sight.
    let (ax, ay, aw, ah) = (384.0, 52.0, 196.0, 140.0);
    c.stroke_round(ax, ay, aw, ah, 10.0, rgba(if t.dark { 0xFFFFFF } else { 0x000000 }, 0.3), 1.5, Some(&[4.0, 3.0]));
    window(c, ax + 18.0, ay + 18.0, 112.0, 74.0, t.dark);
    window(c, ax + 74.0, ay + 50.0, 104.0, 70.0, t.dark);
    pointer(c, ax + 120.0, ay + 78.0, 0.9);
    caption(c, t, "Agent's screen, out of sight", ax + aw / 2.0, sy + sh + 34.0);
}

fn art_screen(c: &Canvas, t: &Theme, m: &Model) {
    // The user's screen, and the agent screen beside it, out of sight.
    let (sx, sy, sw, sh) = (78.0, 46.0, 250.0, 152.0);
    screen(c, t, sx, sy, sw, sh);
    window(c, sx + 26.0, sy + 22.0, 130.0, 86.0, t.dark);
    caption(c, t, "Your screen", sx + sw / 2.0, sy + sh + 34.0);
    let (ax, ay, aw, ah) = (384.0, 52.0, 196.0, 140.0);
    c.stroke_round(ax, ay, aw, ah, 10.0, rgba(if t.dark { 0xFFFFFF } else { 0x000000 }, 0.3), 1.5, Some(&[4.0, 3.0]));
    let (label, color) = if m.setting_up {
        ("Setting up…", NEEDS)
    } else if m.screen_problem.is_none() {
        window(c, ax + 18.0, ay + 18.0, 112.0, 74.0, t.dark);
        pointer(c, ax + 100.0, ay + 60.0, 0.9);
        ("On", LIVE)
    } else {
        ("Off", 0x8E8E93)
    };
    pill(c, t, label, color, ax + aw / 2.0, ay + ah - 22.0);
    caption(c, t, "Agent screen", ax + aw / 2.0, sy + sh + 34.0);
}

/// A status: dot and label, centered on (cx, cy).
fn pill(c: &Canvas, t: &Theme, label: &str, color: u32, cx: f32, cy: f32) {
    let tw = c.measure(label, Font::Semibold, 12.0);
    let w = 10.0 + 8.0 + 6.0 + tw + 12.0;
    c.fill_round(cx - w / 2.0, cy - 12.0, w, 24.0, 12.0, rgba(color, if t.dark { 0.18 } else { 0.14 }));
    c.fill_circle(cx - w / 2.0 + 14.0, cy, 4.0, rgb(color));
    c.text(label, cx - w / 2.0 + 24.0, cy, tw + 4.0, Font::Semibold, 12.0, t.text, Align::Left);
}

fn art_connect(c: &Canvas, t: &Theme, m: &Model) {
    for (i, name) in ["Claude Code", "Codex"].into_iter().enumerate() {
        let agent = m.agents.map(|a| a[i]);
        let name = agent.map_or(name, |a| a.name);
        let (x, y, w, h) = (120.0 + i as f32 * 216.0, 50.0, 184.0, 150.0);
        c.fill_round(x, y + 2.0, w, h, 10.0, rgba(0x000000, 0.14));
        c.fill_round(x, y, w, h, 10.0, t.card);
        c.fill_circle(x + w / 2.0, y + 42.0, 22.0, rgba(if t.dark { 0xFFFFFF } else { 0x000000 }, 0.07));
        c.glyph(0xE756, x + w / 2.0, y + 42.0, 20.0, t.text);
        c.text(name, x + w / 2.0, y + 84.0, w - 16.0, Font::Semibold, 14.0, t.text, Align::Center);
        let (label, color) = match agent {
            None => ("Looking…", 0x8E8E93),
            Some(a) if a.connected => ("Connected", LIVE),
            Some(a) if a.found && m.connecting => ("Connecting…", NEEDS),
            Some(a) if a.found => ("Found", 0x0078D4),
            Some(_) => ("Not installed", 0x8E8E93),
        };
        pill(c, t, label, color, x + w / 2.0, y + 118.0);
    }
}

fn art_done(c: &Canvas, t: &Theme) {
    // The taskbar's corner, with the tray icon and its popover.
    let (x, y, w) = (STAGE.x + 60.0, STAGE.y + STAGE.h - 46.0, STAGE.w - 120.0);
    c.fill_round(x, y, w, 30.0, 6.0, t.card);
    let ix = x + w - 120.0;
    c.fill_round(ix - 12.0, y + 3.0, 24.0, 24.0, 4.0, rgba(t.accent, 0.18));
    c.stroke_round(ix - 8.0, y + 9.0, 16.0, 11.0, 2.5, t.text, 1.5, None);
    c.text("12:00", x + w - 50.0, y + 15.0, 60.0, Font::Regular, 11.0, t.secondary, Align::Center);
    // The popover.
    let (px, py, pw, ph) = (ix - 150.0, STAGE.y + 22.0, 240.0, 150.0);
    c.fill_round(px, py + 2.0, pw, ph, 8.0, rgba(0x000000, 0.18));
    c.fill_round(px, py, pw, ph, 8.0, t.card);
    c.fill_circle(px + 16.0, py + 16.0, 6.0, rgba(LIVE, 0.25));
    c.fill_circle(px + 16.0, py + 16.0, 3.5, rgb(LIVE));
    c.text("Agent working", px + 28.0, py + 16.0, 140.0, Font::Semibold, 11.0, t.secondary, Align::Left);
    c.fill_round(px + 10.0, py + 32.0, pw - 20.0, ph - 42.0, 6.0, rgb(0x1C1C1F));
    window(c, px + 26.0, py + 44.0, 120.0, 72.0, true);
    pointer(c, px + 120.0, py + 80.0, 0.7);
}

// ---------- window ----------

fn logical(hwnd: HWND, lparam: LPARAM) -> (f32, f32) {
    let s = unsafe { GetDpiForWindow(hwnd).max(96) } as f32 / 96.0;
    ((lparam.0 & 0xFFFF) as i16 as f32 / s, ((lparam.0 >> 16) & 0xFFFF) as i16 as f32 / s)
}

/// The enabled button under (x, y).
fn hit(hwnd: HWND, x: f32, y: f32) -> Option<Button> {
    let s = unsafe { GetDpiForWindow(hwnd).max(96) } as f32 / 96.0;
    let c = Canvas::new(1, 1, s);
    let guard = MODEL.lock().unwrap_or_else(|e| e.into_inner());
    let m = guard.as_ref()?;
    buttons(&c, m).into_iter().find(|(_, r, enabled)| *enabled && r.contains(x, y)).map(|(b, _, _)| b)
}

unsafe extern "system" fn proc_(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            WM_PAINT => {
                paint(hwnd);
                LRESULT(0)
            }
            WM_ERASEBKGND => LRESULT(1),
            WM_MOUSEMOVE => {
                let (x, y) = logical(hwnd, lparam);
                let h = hit(hwnd, x, y);
                let (changed, track) = with(|m| {
                    let changed = m.hover != h;
                    m.hover = h;
                    let track = !m.tracking;
                    m.tracking = true;
                    (changed, track)
                })
                .unwrap_or((false, false));
                if track {
                    let mut tme = TRACKMOUSEEVENT { cbSize: size_of::<TRACKMOUSEEVENT>() as u32, dwFlags: TME_LEAVE, hwndTrack: hwnd, dwHoverTime: 0 };
                    let _ = TrackMouseEvent(&mut tme);
                }
                if changed {
                    let _ = InvalidateRect(Some(hwnd), None, false);
                }
                LRESULT(0)
            }
            WM_MOUSELEAVE => {
                with(|m| {
                    m.hover = None;
                    m.tracking = false;
                });
                let _ = InvalidateRect(Some(hwnd), None, false);
                LRESULT(0)
            }
            WM_SETCURSOR if (lparam.0 & 0xFFFF) as u32 == HTCLIENT => {
                let hovering = with(|m| m.hover.is_some()).unwrap_or(false);
                let _ = SetCursor(LoadCursorW(None, if hovering { IDC_HAND } else { IDC_ARROW }).ok());
                LRESULT(1)
            }
            WM_LBUTTONUP => {
                let (x, y) = logical(hwnd, lparam);
                if let Some(b) = hit(hwnd, x, y) {
                    press(b);
                }
                LRESULT(0)
            }
            WM_KEYDOWN if wparam.0 as u16 == VK_RETURN.0 => {
                let enabled = with(|m| labels(m).primary.1).unwrap_or(false);
                if enabled {
                    press(Button::Primary);
                }
                LRESULT(0)
            }
            WM_KEYDOWN if wparam.0 as u16 == VK_ESCAPE.0 => {
                finish(false);
                LRESULT(0)
            }
            WM_DPICHANGED => {
                let r = &*(lparam.0 as *const RECT);
                let _ = SetWindowPos(hwnd, None, r.left, r.top, r.right - r.left, r.bottom - r.top, SWP_NOZORDER | SWP_NOACTIVATE);
                LRESULT(0)
            }
            WM_SETTINGCHANGE => {
                let dark: i32 = (!apps_light()) as i32;
                let _ = DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark as *const _ as *const _, 4);
                let _ = InvalidateRect(Some(hwnd), None, false);
                LRESULT(0)
            }
            WM_CLOSE => {
                finish(false);
                LRESULT(0)
            }
            _ => DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }
}
