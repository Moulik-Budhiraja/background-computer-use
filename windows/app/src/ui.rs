//! The tray's popover (a live preview of each agent's monitor, with pause and
//! stop) and the expanded view of one agent's monitor. A port of the Mac
//! app's popover and viewer. Runs on the tray thread.

use std::cell::RefCell;
use std::collections::HashMap;
use std::time::{Duration, Instant};

use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Dwm::{DWMWA_USE_IMMERSIVE_DARK_MODE, DWMWA_WINDOW_CORNER_PREFERENCE, DWMWCP_ROUND, DwmSetWindowAttribute};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Registry::{HKEY_CURRENT_USER, RRF_RT_REG_DWORD, RegGetValueW};
use windows::Win32::UI::HiDpi::{GetDpiForMonitor, GetDpiForWindow, MDT_EFFECTIVE_DPI};
use windows::Win32::UI::Input::KeyboardAndMouse::{TME_LEAVE, TRACKMOUSEEVENT, TrackMouseEvent, VK_ESCAPE};
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::{PCWSTR, w};

use crate::gfx::{self, Align, Canvas, Font, Frame, rgb, rgba};
use crate::sessions::{self, View};
use crate::{engine, monitor, setup};

// ---------- look ----------

/// Colors with one meaning each, as on the Mac: green is working, amber needs
/// you, gray is paused or idle, blue is for controls.
const LIVE: u32 = 0x2FB457;
const NEEDS: u32 = 0xF09A0A;
const QUIET: u32 = 0x8E8E93;
const ACCENT: u32 = 0x0078D4;
/// Behind the agent's windows.
const MONITOR: u32 = 0x1C1C1F;

// Icon font code points (Segoe Fluent Icons / MDL2 Assets).
const G_PLAY: u32 = 0xE768;
const G_PAUSE: u32 = 0xE769;
const G_STOP: u32 = 0xE71A;
const G_MORE: u32 = 0xE712;
const G_EXPAND: u32 = 0xE740;
const G_COLLAPSE: u32 = 0xE73F;
const G_CHECK: u32 = 0xE73E;
const G_MONITOR: u32 = 0xE7F4;
const G_HAND: u32 = 0xE7C9;
const G_HIDDEN: u32 = 0xED1A;

#[derive(Clone, Copy)]
struct Theme {
    dark: bool,
    ground: u32,
    text: u32,
    secondary: u32,
    hairline: u32,
    hover: u32,
    outline: u32,
}

fn theme() -> Theme {
    let dark = !light_theme();
    if dark {
        Theme {
            dark,
            ground: rgb(0x202022),
            text: rgba(0xFFFFFF, 0.92),
            secondary: rgba(0xFFFFFF, 0.6),
            hairline: rgba(0xFFFFFF, 0.1),
            hover: rgba(0xFFFFFF, 0.08),
            outline: rgba(0xFFFFFF, 0.08),
        }
    } else {
        Theme {
            dark,
            ground: rgb(0xF3F3F3),
            text: rgba(0x000000, 0.88),
            secondary: rgba(0x000000, 0.55),
            hairline: rgba(0x000000, 0.1),
            hover: rgba(0x000000, 0.06),
            outline: rgba(0x000000, 0.08),
        }
    }
}

/// The taskbar's and the tray flyouts' theme.
pub fn light_theme() -> bool {
    let mut v = 0u32;
    let mut n = 4u32;
    unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            w!(r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"),
            w!("SystemUsesLightTheme"),
            RRF_RT_REG_DWORD,
            None,
            Some(&mut v as *mut _ as *mut _),
            Some(&mut n),
        )
        .is_ok()
            && v == 1
    }
}

// ---------- layout ----------

const PAD: f32 = 10.0;
const HEADER: f32 = 28.0;
const GAP: f32 = 10.0;
const BANNER: f32 = 28.0;

#[derive(Clone, Copy, Default, PartialEq)]
struct R {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
}

impl R {
    fn new(x: f32, y: f32, w: f32, h: f32) -> R {
        R { x, y, w, h }
    }
    fn contains(&self, x: f32, y: f32) -> bool {
        x >= self.x && x < self.x + self.w && y >= self.y && y < self.y + self.h
    }
    fn cx(&self) -> f32 {
        self.x + self.w / 2.0
    }
    fn cy(&self) -> f32 {
        self.y + self.h / 2.0
    }
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Hit {
    None,
    Pause,
    Stop,
    More,
    Collapse,
    Setup,
    Tile(usize),
    Resume(usize),
    Done(usize),
}

struct Tile {
    view: View,
    rect: R,
    banner: Option<R>,
}

/// What a window shows: its size, header buttons and tiles, in logical pixels.
struct Layout {
    w: f32,
    h: f32,
    pause: R,
    stop: R,
    sep: R,
    /// More (popover) or collapse (viewer).
    last: R,
    tiles: Vec<Tile>,
    placeholder: Option<R>,
}

fn header_buttons(w: f32) -> (R, R, R, R) {
    let last = R::new(w - PAD - 28.0, PAD, 28.0, HEADER);
    let sep = R::new(last.x - 4.0 - 1.0, PAD + 7.0, 1.0, 14.0);
    let stop = R::new(sep.x - 2.0 - 28.0, PAD, 28.0, HEADER);
    let pause = R::new(stop.x - 28.0, PAD, 28.0, HEADER);
    (pause, stop, sep, last)
}

fn popover_layout(views: &[View]) -> Layout {
    let shown: Vec<View> = views.iter().filter(|v| v.visible()).take(6).cloned().collect();
    let top = PAD + HEADER + GAP;
    if shown.is_empty() {
        let w = 440.0 + PAD * 2.0;
        let (pause, stop, sep, last) = header_buttons(w);
        return Layout { w, h: top + 275.0 + PAD, pause, stop, sep, last, tiles: Vec::new(), placeholder: Some(R::new(PAD, top, 440.0, 275.0)) };
    }
    let cols = match shown.len() {
        1 => 1,
        2..=4 => 2,
        _ => 3,
    };
    let tw = if cols == 1 { 440.0 } else { 320.0 };
    let th = (tw * 10.0 / 16.0f32).round();
    let w = PAD * 2.0 + cols as f32 * tw + (cols - 1) as f32 * GAP;
    let (pause, stop, sep, last) = header_buttons(w);
    let mut tiles = Vec::new();
    let mut y = top;
    for row in shown.chunks(cols) {
        let banner_row = row.iter().any(|v| v.handoff.is_some());
        for (c, v) in row.iter().enumerate() {
            let x = PAD + c as f32 * (tw + GAP);
            let rect = R::new(x, y, tw, th);
            let banner = v.handoff.is_some().then(|| R::new(x, y + th + 8.0, tw, BANNER));
            tiles.push(Tile { view: v.clone(), rect, banner });
        }
        y += th + if banner_row { 8.0 + BANNER } else { 0.0 } + GAP;
    }
    Layout { w, h: y - GAP + PAD, pause, stop, sep, last, tiles, placeholder: None }
}

fn viewer_layout(view: &View, pw: f32, ph: f32) -> Layout {
    let w = pw + PAD * 2.0;
    let (pause, stop, sep, last) = header_buttons(w);
    let rect = R::new(PAD, PAD + HEADER + GAP, pw, ph);
    let banner = view.handoff.is_some().then(|| R::new(PAD, rect.y + ph + 8.0, pw, BANNER));
    let h = rect.y + ph + if banner.is_some() { 8.0 + BANNER } else { 0.0 } + PAD;
    Layout { w, h, pause, stop, sep, last, tiles: vec![Tile { view: view.clone(), rect, banner }], placeholder: None }
}

fn hit(layout: &Layout, x: f32, y: f32, viewer: bool) -> Hit {
    let anything = !layout.tiles.is_empty();
    if layout.pause.contains(x, y) && anything {
        return Hit::Pause;
    }
    if layout.stop.contains(x, y) && layout.tiles.iter().any(|t| t.view.windows > 0) {
        return Hit::Stop;
    }
    if layout.last.contains(x, y) {
        return if viewer { Hit::Collapse } else { Hit::More };
    }
    if let Some(p) = layout.placeholder
        && needs_setup()
        && setup_button(p).contains(x, y)
    {
        return Hit::Setup;
    }
    for (i, t) in layout.tiles.iter().enumerate() {
        if let Some(b) = t.banner
            && R::new(b.x + b.w - 30.0, b.y, 30.0, b.h).contains(x, y)
        {
            return Hit::Done(i);
        }
        if t.rect.contains(x, y) {
            if t.view.paused && t.view.handoff.is_none() {
                let c = paused_circle(t.rect);
                if (x - c.0).powi(2) + (y - c.1).powi(2) <= 22.0f32.powi(2) {
                    return Hit::Resume(i);
                }
            }
            return if viewer { Hit::None } else { Hit::Tile(i) };
        }
    }
    Hit::None
}

fn paused_circle(r: R) -> (f32, f32) {
    (r.cx(), r.cy() - (44.0 + 10.0 + 15.0) / 2.0 + 22.0)
}

/// No agent monitor, and not over Remote Desktop (where agents get hidden screens).
fn needs_setup() -> bool {
    !monitor::installed() && !monitor::hidden_mode()
}

fn setup_button(p: R) -> R {
    R::new(p.cx() - 40.0, p.cy() + 22.0, 80.0, 26.0)
}

// ---------- drawing ----------

fn tally(c: &Canvas, cx: f32, cy: f32, v: Option<&View>, waiting: bool, active: bool, paused: bool, needs_setup: bool) {
    let _ = v;
    let dot = |color: u32| {
        c.fill_circle(cx, cy, 7.0, rgba(color, 0.2));
        c.fill_circle(cx, cy, 4.0, rgb(color));
    };
    if waiting {
        dot(NEEDS);
    } else if active {
        dot(LIVE);
    } else if paused {
        c.fill_round(cx - 3.5, cy - 4.0, 2.5, 8.0, 1.0, rgb(QUIET));
        c.fill_round(cx + 1.0, cy - 4.0, 2.5, 8.0, 1.0, rgb(QUIET));
    } else if needs_setup {
        dot(NEEDS);
    } else {
        c.stroke_circle(cx, cy, 3.25, rgb(QUIET), 1.5);
    }
}

fn view_tally(c: &Canvas, cx: f32, cy: f32, v: &View) {
    tally(c, cx, cy, Some(v), v.handoff.is_some(), v.active(), v.paused, false);
}

fn icon_button(c: &Canvas, t: &Theme, r: R, glyph: u32, hovered: bool, enabled: bool) {
    if hovered && enabled {
        c.fill_round(r.x, r.y, r.w, r.h, 6.0, t.hover);
    }
    let color = if enabled { t.secondary } else { (t.secondary & 0x00FF_FFFF) | (((t.secondary >> 24) * 35 / 100) << 24) };
    let (x, y) = (r.cx(), r.cy());
    // Filled shapes, like the Mac's SF Symbols; the icon font's are outlines.
    match glyph {
        G_PAUSE => {
            c.fill_round(x - 4.5, y - 6.0, 3.5, 12.0, 1.0, color);
            c.fill_round(x + 1.0, y - 6.0, 3.5, 12.0, 1.0, color);
        }
        G_PLAY => play(c, x, y, 11.0, color),
        G_STOP => c.fill_round(x - 5.5, y - 5.5, 11.0, 11.0, 2.0, color),
        G_MORE => {
            for dx in [-5.5, 0.0, 5.5] {
                c.fill_circle(x + dx, y, 1.6, color);
            }
        }
        _ => c.glyph(glyph, x, y, 13.0, color),
    }
}

/// A filled play triangle centered (by area) on (x, y), `h` tall.
fn play(c: &Canvas, x: f32, y: f32, h: f32, color: u32) {
    let w = h * 0.9;
    let x0 = x - w / 3.0;
    c.fill_polygon(&[(x0, y - h / 2.0), (x0 + w, y), (x0, y + h / 2.0)], color);
    c.stroke_polygon(&[(x0, y - h / 2.0), (x0 + w, y), (x0, y + h / 2.0)], color, 1.5);
}

/// Where each session's agent cursor is drawn, gliding between points.
struct Glide {
    from: POINT,
    to: POINT,
    start: Instant,
}

impl Glide {
    fn at(&self) -> (f32, f32) {
        let t = (self.start.elapsed().as_secs_f32() / 0.22).min(1.0);
        let e = 1.0 - (1.0 - t).powi(3);
        (self.from.x as f32 + (self.to.x - self.from.x) as f32 * e, self.from.y as f32 + (self.to.y - self.from.y) as f32 * e)
    }
}

/// The agent's pointer: a white arrow with a dark edge, tip at (x, y).
fn cursor(c: &Canvas, x: f32, y: f32, size: f32) {
    let k = size / 20.0;
    let pts: Vec<(f32, f32)> = [(0.0, 0.0), (0.0, 16.6), (4.0, 12.9), (6.6, 18.9), (9.3, 17.8), (6.8, 11.9), (12.0, 11.9)]
        .iter()
        .map(|(px, py)| (x + px * k, y + py * k))
        .collect();
    let shadow: Vec<(f32, f32)> = pts.iter().map(|(a, b)| (a + 0.6, b + 1.2)).collect();
    c.fill_polygon(&shadow, rgba(0x000000, 0.28));
    c.fill_polygon(&pts, rgb(0xFFFFFF));
    c.stroke_polygon(&pts, rgb(0x111111), 1.1 * k.max(0.8));
}

struct Paint<'a> {
    c: &'a Canvas,
    t: Theme,
    hover: Hit,
    frames: &'a HashMap<String, Frame>,
    glides: &'a HashMap<String, Glide>,
    monitors: &'a HashMap<String, RECT>,
}

impl Paint<'_> {
    fn preview(&self, i: usize, tile: &Tile, viewer: bool) {
        let c = self.c;
        let r = tile.rect;
        let v = &tile.view;
        c.fill_round(r.x, r.y, r.w, r.h, 8.0, rgb(MONITOR));
        if v.windows == 0 && v.handoff.is_none() {
            c.glyph(G_MONITOR, r.cx(), r.cy() - 12.0, 20.0, rgba(0xFFFFFF, 0.45));
            c.text("Nothing running", r.cx(), r.cy() + 14.0, r.w - 20.0, Font::Semibold, 12.0, rgba(0xFFFFFF, 0.45), Align::Center);
        } else if let Some(f) = self.frames.get(&v.id) {
            c.image_round(f, r.x, r.y, r.w, r.h, 8.0);
            if let (Some(g), Some(m)) = (self.glides.get(&v.id), self.monitors.get(&v.id)) {
                let (px, py) = g.at();
                let (mw, mh) = ((m.right - m.left) as f32, (m.bottom - m.top) as f32);
                let (x, y) = (r.x + (px - m.left as f32) * r.w / mw, r.y + (py - m.top as f32) * r.h / mh);
                if r.contains(x, y) {
                    cursor(c, x, y, if viewer { 20.0 } else { 14.0 });
                }
            }
        }
        if let Some((app, _)) = &v.handoff {
            let label = format!("{app} is on your screen");
            let tw = c.measure(&label, Font::Semibold, 12.0);
            let w = 14.0 + 12.0 + 6.0 + tw + 14.0;
            let (x, y) = (r.cx() - w / 2.0, r.cy() - 16.0);
            c.fill_round(x, y, w, 32.0, 16.0, rgba(0x000000, 0.45));
            c.stroke_round(x, y, w, 32.0, 16.0, rgba(0xFFFFFF, 0.3), 1.0, Some(&[4.0, 3.0]));
            c.glyph(G_MONITOR, x + 14.0 + 6.0, r.cy(), 12.0, rgba(0xFFFFFF, 0.78));
            c.text(&label, x + 14.0 + 12.0 + 6.0, r.cy(), tw + 2.0, Font::Semibold, 12.0, rgba(0xFFFFFF, 0.78), Align::Left);
        } else if v.paused {
            c.fill_round(r.x, r.y, r.w, r.h, 8.0, rgba(0x0C0C0D, 0.74));
            let (cx, cy) = paused_circle(r);
            c.fill_circle(cx, cy + 2.0, 22.0, rgba(0x000000, 0.3));
            c.fill_circle(cx, cy, 22.0, rgb(0xFFFFFF));
            play(c, cx + 1.0, cy, 15.0, rgb(0x1D1D1F));
            c.text("Paused", cx, cy + 22.0 + 10.0 + 7.5, 120.0, Font::Semibold, 12.0, rgba(0xFFFFFF, 0.74), Align::Center);
        }
        if !viewer {
            self.label(r, v);
            if self.hover == Hit::Tile(i) {
                c.fill_circle(r.cx(), r.cy(), 20.0, rgba(0x000000, 0.5));
                c.glyph(G_EXPAND, r.cx(), r.cy(), 15.0, rgb(0xFFFFFF));
            }
        }
        c.stroke_round(r.x, r.y, r.w, r.h, 8.0, self.t.outline, 0.5, None);
        if let Some(b) = tile.banner {
            self.banner(i, b, v);
        }
    }

    /// The tile's name tag: status, agent name and its apps' icons.
    fn label(&self, r: R, v: &View) {
        let c = self.c;
        let tw = c.measure(&v.label, Font::Semibold, 11.0);
        let mut exes: Vec<&str> = Vec::new();
        for a in &v.apps {
            if !a.exe.is_empty() && !exes.contains(&a.exe.as_str()) && exes.len() < 3 {
                exes.push(&a.exe);
            }
        }
        let w = 7.0 + 12.0 + 5.0 + tw + exes.len() as f32 * 19.0 + 7.0;
        let (x, y) = (r.x + 8.0, r.y + r.h - 8.0 - 22.0);
        c.fill_round(x, y, w, 22.0, 11.0, rgba(0x000000, 0.55));
        view_tally(c, x + 7.0 + 6.0, y + 11.0, v);
        c.text(&v.label, x + 7.0 + 12.0 + 5.0, y + 11.0, tw + 2.0, Font::Semibold, 11.0, rgb(0xFFFFFF), Align::Left);
        let mut ix = x + 7.0 + 12.0 + 5.0 + tw + 5.0;
        for exe in exes {
            c.app_icon(exe, ix, y + 4.0, 14.0);
            ix += 19.0;
        }
    }

    /// Below a tile when the agent handed a window to the user.
    fn banner(&self, i: usize, b: R, v: &View) {
        let c = self.c;
        let reason = v.handoff.as_ref().map(|(app, r)| if r.is_empty() { format!("{app} needs you") } else { r.clone() }).unwrap_or_default();
        c.fill_round(b.x + 2.0, b.y, 28.0, 28.0, 8.0, rgba(NEEDS, 0.14));
        c.glyph(G_HAND, b.x + 16.0, b.cy(), 13.0, rgb(if self.t.dark { 0xF5A623 } else { 0xC77700 }));
        c.text(&reason, b.x + 2.0 + 28.0 + 10.0, b.cy(), b.w - 28.0 - 10.0 - 10.0 - 28.0 - 4.0, Font::Semibold, 13.0, self.t.text, Align::Left);
        let (cx, cy) = (b.x + b.w - 2.0 - 14.0, b.cy());
        c.fill_circle(cx, cy, 14.0, if self.hover == Hit::Done(i) { rgb(0x1A86D9) } else { rgb(ACCENT) });
        c.glyph(G_CHECK, cx, cy, 12.0, rgb(0xFFFFFF));
    }

    fn placeholder(&self, p: R) {
        let c = self.c;
        c.fill_round(p.x, p.y, p.w, p.h, 8.0, rgb(MONITOR));
        if monitor::installed() {
            c.glyph(G_MONITOR, p.cx(), p.cy() - 12.0, 20.0, rgba(0xFFFFFF, 0.45));
            c.text("Nothing running", p.cx(), p.cy() + 14.0, p.w - 20.0, Font::Semibold, 12.0, rgba(0xFFFFFF, 0.45), Align::Center);
        } else if monitor::hidden_mode() {
            c.glyph(G_MONITOR, p.cx(), p.cy() - 22.0, 20.0, rgba(0xFFFFFF, 0.45));
            c.text("Nothing running", p.cx(), p.cy() + 4.0, p.w - 20.0, Font::Semibold, 12.0, rgba(0xFFFFFF, 0.45), Align::Center);
            c.text("Over Remote Desktop, agents work in hidden windows", p.cx(), p.cy() + 24.0, p.w - 20.0, Font::Semibold, 11.0, rgba(0xFFFFFF, 0.35), Align::Center);
        } else {
            c.glyph(G_HIDDEN, p.cx(), p.cy() - 26.0, 20.0, rgba(0xFFFFFF, 0.45));
            c.text("Agent screens aren't set up", p.cx(), p.cy() + 2.0, p.w - 20.0, Font::Semibold, 13.0, rgba(0xFFFFFF, 0.88), Align::Center);
            let b = setup_button(p);
            c.fill_round(b.x, b.y, b.w, b.h, 13.0, rgba(0xFFFFFF, if self.hover == Hit::Setup { 0.22 } else { 0.14 }));
            c.text("Set up", b.cx(), b.cy(), b.w, Font::Semibold, 12.0, rgb(0xFFFFFF), Align::Center);
        }
        c.stroke_round(p.x, p.y, p.w, p.h, 8.0, self.t.outline, 0.5, None);
    }
}

fn header_text(views: &[View]) -> String {
    let shown: Vec<&View> = views.iter().filter(|v| v.visible()).collect();
    match shown.len() {
        0 if needs_setup() => "Setup needed".into(),
        0 => "Idle".into(),
        1 => shown[0].status_text(),
        n => {
            let waiting = shown.iter().filter(|v| v.handoff.is_some()).count();
            if waiting > 0 { format!("{n} agents · {waiting} need{} you", if waiting == 1 { "s" } else { "" }) } else { format!("{n} agents") }
        }
    }
}

// ---------- state ----------

struct Win {
    hwnd: HWND,
    hover: Hit,
    tracking: bool,
}

#[derive(Default)]
struct Ui {
    popover: Option<Win>,
    viewer: Option<(Win, HWND, String)>,
    /// When the popover last closed, so the tray click that closed it doesn't reopen it.
    closed_at: Option<Instant>,
    frames: HashMap<String, Frame>,
    glides: HashMap<String, Glide>,
    monitors: HashMap<String, RECT>,
}

thread_local! {
    static UI: RefCell<Ui> = RefCell::new(Ui::default());
}

/// Short borrows only: never call anything that sends window messages inside.
fn with<R>(f: impl FnOnce(&mut Ui) -> R) -> Option<R> {
    UI.with(|u| u.try_borrow_mut().ok().map(|mut u| f(&mut u)))
}

const POPOVER_CLASS: PCWSTR = w!("BCUPopover");
const VIEWER_CLASS: PCWSTR = w!("BCUViewer");
const DIM_CLASS: PCWSTR = w!("BCUDim");
const FRAME_TIMER: usize = 1;
const WM_MOUSELEAVE: u32 = 0x02A3;

pub fn register() {
    unsafe {
        let instance = GetModuleHandleW(None).unwrap_or_default();
        let arrow = LoadCursorW(None, IDC_ARROW).unwrap_or_default();
        for (name, proc_) in [
            (POPOVER_CLASS, popover_proc as unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT),
            (VIEWER_CLASS, viewer_proc),
            (DIM_CLASS, dim_proc),
        ] {
            let class = WNDCLASSW { lpfnWndProc: Some(proc_), hInstance: instance.into(), lpszClassName: name, hCursor: arrow, ..Default::default() };
            RegisterClassW(&class);
        }
    }
}

fn scale_of(hwnd: HWND) -> f32 {
    unsafe { GetDpiForWindow(hwnd).max(96) as f32 / 96.0 }
}

fn dpi_at(p: POINT) -> f32 {
    let mut x = 96;
    let mut y = 96;
    unsafe {
        let m = MonitorFromPoint(p, MONITOR_DEFAULTTONEAREST);
        let _ = GetDpiForMonitor(m, MDT_EFFECTIVE_DPI, &mut x, &mut y);
    }
    x.max(96) as f32 / 96.0
}

fn work_area_at(p: POINT) -> (RECT, RECT) {
    unsafe {
        let m = MonitorFromPoint(p, MONITOR_DEFAULTTONEAREST);
        let mut info = MONITORINFO { cbSize: size_of::<MONITORINFO>() as u32, ..Default::default() };
        let _ = GetMonitorInfoW(m, &mut info);
        (info.rcWork, info.rcMonitor)
    }
}

fn style_window(hwnd: HWND) {
    unsafe {
        let round = DWMWCP_ROUND;
        let _ = DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, &round as *const _ as *const _, size_of_val(&round) as u32);
        let dark: i32 = (!light_theme()) as i32;
        let _ = DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark as *const _ as *const _, 4);
    }
}

// ---------- popover ----------

/// The tray icon was clicked.
pub fn toggle_popover(icon: RECT) {
    let open = with(|u| u.popover.as_ref().map(|p| p.hwnd)).flatten();
    if let Some(h) = open {
        unsafe {
            let _ = DestroyWindow(h);
        }
        return;
    }
    if with(|u| u.closed_at.is_some_and(|t| t.elapsed() < Duration::from_millis(300))).unwrap_or(false) {
        return;
    }
    let anchor = POINT { x: (icon.left + icon.right) / 2, y: (icon.top + icon.bottom) / 2 };
    let s = dpi_at(anchor);
    let layout = popover_layout(&sessions::all());
    let (w, h) = ((layout.w * s).round() as i32, (layout.h * s).round() as i32);
    let (x, y) = popover_origin(anchor, icon, w, h);
    unsafe {
        let instance = GetModuleHandleW(None).unwrap_or_default();
        let Ok(hwnd) = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_TOPMOST, POPOVER_CLASS, w!("Background Computer Use"), WS_POPUP, x, y, w, h, None, None, Some(instance.into()), None)
        else {
            return;
        };
        style_window(hwnd);
        with(|u| u.popover = Some(Win { hwnd, hover: Hit::None, tracking: false }));
        tick();
        let _ = ShowWindow(hwnd, SW_SHOW);
        let _ = SetForegroundWindow(hwnd);
        SetTimer(Some(hwnd), FRAME_TIMER, 1000 / 15, None);
    }
}

fn popover_origin(anchor: POINT, icon: RECT, w: i32, h: i32) -> (i32, i32) {
    let (work, _) = work_area_at(anchor);
    let margin = 12;
    let x = (anchor.x - w / 2).clamp(work.left + margin, (work.right - w - margin).max(work.left + margin));
    let y = if icon.top < work.top + 4 && icon.bottom <= work.top + 80 { work.top + margin } else { work.bottom - h - margin };
    (x, y)
}

/// Sessions changed: resize the popover to fit, redraw both windows.
pub fn refresh() {
    let popover = with(|u| u.popover.as_ref().map(|p| p.hwnd)).flatten();
    if let Some(hwnd) = popover {
        let s = scale_of(hwnd);
        let layout = popover_layout(&sessions::all());
        let (w, h) = ((layout.w * s).round() as i32, (layout.h * s).round() as i32);
        let mut r = RECT::default();
        unsafe {
            let _ = GetWindowRect(hwnd, &mut r);
            if r.right - r.left != w || r.bottom - r.top != h {
                // Keep the edge nearest the taskbar where it is.
                let (work, _) = work_area_at(POINT { x: r.left, y: r.top });
                let bottom_anchored = r.bottom >= work.bottom - 40;
                let x = (r.right - w).max(work.left + 12);
                let y = if bottom_anchored { r.bottom - h } else { r.top };
                let _ = SetWindowPos(hwnd, None, x, y, w, h, SWP_NOZORDER | SWP_NOACTIVATE);
            }
            let _ = InvalidateRect(Some(hwnd), None, false);
        }
    }
    let viewer = with(|u| u.viewer.as_ref().map(|v| v.0.hwnd)).flatten();
    if let Some(hwnd) = viewer {
        // Grow or shrink for the handoff banner, keeping the top where it is.
        if let Some((_, layout, _)) = viewer_state(hwnd) {
            let s = scale_of(hwnd);
            let h = (layout.h * s).round() as i32;
            let mut r = RECT::default();
            unsafe {
                let _ = GetWindowRect(hwnd, &mut r);
                if r.bottom - r.top != h {
                    let _ = SetWindowPos(hwnd, None, r.left, r.top, r.right - r.left, h, SWP_NOZORDER | SWP_NOACTIVATE);
                }
            }
        }
        unsafe {
            let _ = InvalidateRect(Some(hwnd), None, false);
        }
    }
}

/// Grab new frames for what's on screen, and move the agent cursors along.
fn tick() {
    let views = sessions::all();
    let monitors: HashMap<String, RECT> = monitor::slots().into_iter().collect();
    let popover = with(|u| u.popover.as_ref().map(|p| p.hwnd)).flatten();
    let viewer = with(|u| u.viewer.as_ref().map(|v| (v.0.hwnd, v.2.clone()))).flatten();
    // Which sessions to capture, and at what size (device pixels).
    let mut wanted: Vec<(String, i32, i32)> = Vec::new();
    if let Some(hwnd) = popover {
        let s = scale_of(hwnd);
        for t in popover_layout(&views).tiles {
            wanted.push((t.view.id.clone(), (t.rect.w * s).round() as i32, (t.rect.h * s).round() as i32));
        }
    }
    if let Some((hwnd, id)) = &viewer {
        let s = scale_of(*hwnd);
        if let Some(v) = views.iter().find(|v| &v.id == id) {
            let (pw, ph) = viewer_preview_size(*hwnd);
            let t = &viewer_layout(v, pw, ph).tiles[0];
            wanted.retain(|(w, _, _)| w != id);
            wanted.push((id.clone(), (t.rect.w * s).round() as i32, (t.rect.h * s).round() as i32));
        }
    }
    let mut frames = HashMap::new();
    for (id, w, h) in wanted {
        let has_windows = views.iter().any(|v| v.id == id && v.windows > 0);
        if let (true, Some(m)) = (has_windows, monitors.get(&id))
            && let Some(f) = if monitor::on_screen(m) { gfx::capture_screen(*m, w, h) } else { gfx::capture_windows(*m, w, h) }
        {
            frames.insert(id, f);
        }
    }
    with(|u| {
        u.frames = frames;
        u.monitors = monitors;
        for v in &views {
            let Some((p, _)) = v.pointer else { continue };
            match u.glides.get_mut(&v.id) {
                Some(g) if g.to.x == p.x && g.to.y == p.y => {}
                Some(g) => {
                    let (x, y) = g.at();
                    *g = Glide { from: POINT { x: x as i32, y: y as i32 }, to: p, start: Instant::now() };
                }
                None => {
                    u.glides.insert(v.id.clone(), Glide { from: p, to: p, start: Instant::now() });
                }
            }
        }
    });
    for h in [popover, viewer.map(|v| v.0)].into_iter().flatten() {
        unsafe {
            let _ = InvalidateRect(Some(h), None, false);
        }
    }
}

fn paint(hwnd: HWND, layout: &Layout, hover: Hit, views: &[View], viewer: bool) {
    let s = scale_of(hwnd);
    let mut rc = RECT::default();
    unsafe {
        let _ = GetClientRect(hwnd, &mut rc);
    }
    let c = Canvas::new(rc.right, rc.bottom, s);
    let t = theme();
    c.clear(t.ground);
    let all_paused = engine::all_paused();
    // Header.
    let shown: Vec<&View> = views.iter().filter(|v| v.visible()).collect();
    if viewer {
        let v = &layout.tiles[0].view;
        view_tally(&c, PAD + 11.0, PAD + HEADER / 2.0, v);
        let mut x = PAD + 24.0;
        c.text(&v.label, x, PAD + HEADER / 2.0, 200.0, Font::Semibold, 12.0, t.text, Align::Left);
        x += c.measure(&v.label, Font::Semibold, 12.0) + 12.0;
        let mut seen: Vec<&str> = Vec::new();
        for a in &v.apps {
            if seen.contains(&a.name.as_str()) || x > layout.pause.x - 80.0 {
                continue;
            }
            seen.push(&a.name);
            if c.app_icon(&a.exe, x, PAD + 6.0, 16.0) {
                x += 21.0;
            }
            c.text(&a.name, x, PAD + HEADER / 2.0, (layout.pause.x - x - 8.0).max(10.0), Font::Semibold, 12.0, t.secondary, Align::Left);
            x += c.measure(&a.name, Font::Semibold, 12.0) + 12.0;
        }
    } else {
        let waiting = shown.iter().any(|v| v.handoff.is_some());
        let active = shown.iter().any(|v| v.active());
        let paused = all_paused;
        tally(&c, PAD + 11.0, PAD + HEADER / 2.0, None, waiting, active, paused, shown.is_empty() && needs_setup());
        c.text(&header_text(views), PAD + 24.0, PAD + HEADER / 2.0, layout.pause.x - PAD - 30.0, Font::Semibold, 12.0, t.secondary, Align::Left);
    }
    let paused_here = if viewer { layout.tiles[0].view.paused } else { all_paused };
    let any = !layout.tiles.is_empty();
    icon_button(&c, &t, layout.pause, if paused_here { G_PLAY } else { G_PAUSE }, hover == Hit::Pause, any);
    icon_button(&c, &t, layout.stop, G_STOP, hover == Hit::Stop, layout.tiles.iter().any(|t| t.view.windows > 0));
    c.fill_rect(layout.sep.x, layout.sep.y, layout.sep.w, layout.sep.h, t.hairline);
    icon_button(&c, &t, layout.last, if viewer { G_COLLAPSE } else { G_MORE }, matches!(hover, Hit::More | Hit::Collapse), true);
    // Previews.
    with(|u| {
        let p = Paint { c: &c, t, hover, frames: &u.frames, glides: &u.glides, monitors: &u.monitors };
        if let Some(ph) = layout.placeholder {
            p.placeholder(ph);
        }
        for (i, tile) in layout.tiles.iter().enumerate() {
            p.preview(i, tile, viewer);
        }
    });
    unsafe {
        let mut ps = PAINTSTRUCT::default();
        let hdc = BeginPaint(hwnd, &mut ps);
        c.present(hdc);
        let _ = EndPaint(hwnd, &ps);
    }
}

fn track_leave(hwnd: HWND) {
    let mut tme = TRACKMOUSEEVENT { cbSize: size_of::<TRACKMOUSEEVENT>() as u32, dwFlags: TME_LEAVE, hwndTrack: hwnd, dwHoverTime: 0 };
    unsafe {
        let _ = TrackMouseEvent(&mut tme);
    }
}

fn logical(hwnd: HWND, lparam: LPARAM) -> (f32, f32) {
    let s = scale_of(hwnd);
    let x = (lparam.0 & 0xFFFF) as i16 as f32;
    let y = ((lparam.0 >> 16) & 0xFFFF) as i16 as f32;
    (x / s, y / s)
}

unsafe extern "system" fn popover_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            WM_PAINT => {
                let views = sessions::all();
                let layout = popover_layout(&views);
                let hover = with(|u| u.popover.as_ref().map(|p| p.hover)).flatten().unwrap_or(Hit::None);
                paint(hwnd, &layout, hover, &views, false);
                LRESULT(0)
            }
            WM_ERASEBKGND => LRESULT(1),
            WM_TIMER => {
                tick();
                LRESULT(0)
            }
            WM_MOUSEMOVE => {
                let (x, y) = logical(hwnd, lparam);
                let h = hit(&popover_layout(&sessions::all()), x, y, false);
                let (changed, track) = with(|u| match u.popover.as_mut() {
                    Some(p) => {
                        let changed = p.hover != h;
                        p.hover = h;
                        let track = !p.tracking;
                        p.tracking = true;
                        (changed, track)
                    }
                    None => (false, false),
                })
                .unwrap_or((false, false));
                if track {
                    track_leave(hwnd);
                }
                if changed {
                    let _ = InvalidateRect(Some(hwnd), None, false);
                }
                LRESULT(0)
            }
            WM_MOUSELEAVE => {
                with(|u| {
                    if let Some(p) = u.popover.as_mut() {
                        p.hover = Hit::None;
                        p.tracking = false;
                    }
                });
                let _ = InvalidateRect(Some(hwnd), None, false);
                LRESULT(0)
            }
            WM_LBUTTONUP => {
                let (x, y) = logical(hwnd, lparam);
                let layout = popover_layout(&sessions::all());
                match hit(&layout, x, y, false) {
                    Hit::Pause => engine::set_paused(None, !engine::all_paused()),
                    Hit::Stop => engine::stop(None),
                    Hit::More => more_menu(hwnd, layout.last),
                    Hit::Setup => {
                        let _ = DestroyWindow(hwnd);
                        std::thread::spawn(|| setup::run(false));
                    }
                    Hit::Tile(i) => {
                        let id = layout.tiles[i].view.id.clone();
                        let _ = DestroyWindow(hwnd);
                        open_viewer(&id);
                    }
                    Hit::Resume(i) => engine::set_paused(Some(&layout.tiles[i].view.id), false),
                    Hit::Done(i) => engine::hand_back(&layout.tiles[i].view.id),
                    Hit::Collapse | Hit::None => {}
                }
                LRESULT(0)
            }
            WM_ACTIVATE => {
                if (wparam.0 & 0xFFFF) as u32 == WA_INACTIVE {
                    let _ = DestroyWindow(hwnd);
                }
                LRESULT(0)
            }
            WM_KEYDOWN if wparam.0 as u16 == VK_ESCAPE.0 => {
                let _ = DestroyWindow(hwnd);
                LRESULT(0)
            }
            WM_DESTROY => {
                let _ = KillTimer(Some(hwnd), FRAME_TIMER);
                with(|u| {
                    u.popover = None;
                    u.closed_at = Some(Instant::now());
                });
                LRESULT(0)
            }
            _ => DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }
}

const M_LOGIN: usize = 1;
const M_SETUP: usize = 2;
const M_QUIT: usize = 3;
const M_UPDATE: usize = 4;

/// ⋯: open at sign-in, setup, quit.
fn more_menu(hwnd: HWND, anchor: R) {
    unsafe {
        let Ok(menu) = CreatePopupMenu() else { return };
        let login = setup::starts_at_sign_in();
        let _ = AppendMenuW(menu, MF_STRING | if login { MF_CHECKED } else { MF_UNCHECKED }, M_LOGIN, w!("Open at sign-in"));
        let _ = AppendMenuW(menu, MF_STRING, M_SETUP, w!("Set up…"));
        let update: Vec<u16> = match crate::updater::pending() {
            Some(v) => format!("Restart to update to {v}"),
            None => "Check for updates".into(),
        }
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
        let _ = AppendMenuW(menu, MF_STRING, M_UPDATE, PCWSTR(update.as_ptr()));
        let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null());
        let size: Vec<u16> = "Agent screens 1600 × 1000".encode_utf16().chain(std::iter::once(0)).collect();
        let _ = AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, PCWSTR(size.as_ptr()));
        let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null());
        let _ = AppendMenuW(menu, MF_STRING, M_QUIT, w!("Quit Background Computer Use"));
        let s = scale_of(hwnd);
        let mut p = POINT { x: ((anchor.x + anchor.w) * s) as i32, y: ((anchor.y + anchor.h) * s) as i32 };
        let _ = ClientToScreen(hwnd, &mut p);
        let cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTALIGN | TPM_TOPALIGN, p.x, p.y, Some(0), hwnd, None);
        let _ = DestroyMenu(menu);
        match cmd.0 as usize {
            M_LOGIN => setup::set_start_at_sign_in(!login),
            M_SETUP => {
                let _ = DestroyWindow(hwnd);
                std::thread::spawn(|| setup::run(false));
            }
            M_UPDATE => {
                let _ = DestroyWindow(hwnd);
                crate::tray::update_action();
            }
            M_QUIT => crate::tray::request_quit(),
            _ => {}
        }
    }
}

// ---------- expanded view ----------

/// The preview's size in the expanded view, in logical pixels: as big as fits
/// in 82% of the screen, in the agent monitor's shape.
fn viewer_preview_size(hwnd: HWND) -> (f32, f32) {
    let s = scale_of(hwnd);
    let mut r = RECT::default();
    unsafe {
        let _ = GetWindowRect(hwnd, &mut r);
    }
    let (work, _) = work_area_at(POINT { x: (r.left + r.right) / 2, y: (r.top + r.bottom) / 2 });
    viewer_fit(work, s)
}

fn viewer_fit(work: RECT, s: f32) -> (f32, f32) {
    let (ww, wh) = ((work.right - work.left) as f32 / s, (work.bottom - work.top) as f32 / s);
    let max_h = wh * 0.82 - (PAD * 2.0 + HEADER + GAP);
    let pw = (ww * 0.82).min(max_h * 1.6).floor();
    (pw, (pw / 1.6).round())
}

pub fn open_viewer(session: &str) {
    let Some(view) = sessions::get(session) else { return };
    close_viewer();
    let mut cursor = POINT::default();
    unsafe {
        let _ = GetCursorPos(&mut cursor);
    }
    let (work, mon) = work_area_at(cursor);
    let s = dpi_at(cursor);
    let (pw, ph) = viewer_fit(work, s);
    let layout = viewer_layout(&view, pw, ph);
    let (w, h) = ((layout.w * s).round() as i32, (layout.h * s).round() as i32);
    let x = work.left + (work.right - work.left - w) / 2;
    let y = work.top + (work.bottom - work.top - h) / 2;
    unsafe {
        let instance = GetModuleHandleW(None).unwrap_or_default();
        // A dimmed backdrop over the screen; clicking it closes the view.
        let dim = CreateWindowExW(
            WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_LAYERED,
            DIM_CLASS,
            w!(""),
            WS_POPUP,
            mon.left,
            mon.top,
            mon.right - mon.left,
            mon.bottom - mon.top,
            None,
            None,
            Some(instance.into()),
            None,
        )
        .unwrap_or_default();
        let _ = SetLayeredWindowAttributes(dim, COLORREF(0), 128, LWA_ALPHA);
        let Ok(hwnd) = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_TOPMOST, VIEWER_CLASS, w!("Background Computer Use"), WS_POPUP, x, y, w, h, Some(dim), None, Some(instance.into()), None)
        else {
            let _ = DestroyWindow(dim);
            return;
        };
        style_window(hwnd);
        with(|u| u.viewer = Some((Win { hwnd, hover: Hit::None, tracking: false }, dim, session.to_string())));
        tick();
        let _ = ShowWindow(dim, SW_SHOWNOACTIVATE);
        let _ = ShowWindow(hwnd, SW_SHOW);
        let _ = SetForegroundWindow(hwnd);
        SetTimer(Some(hwnd), FRAME_TIMER, 1000 / 20, None);
    }
}

fn close_viewer() {
    let open = with(|u| u.viewer.take().map(|v| (v.0.hwnd, v.1))).flatten();
    if let Some((hwnd, dim)) = open {
        unsafe {
            let _ = KillTimer(Some(hwnd), FRAME_TIMER);
            let _ = DestroyWindow(hwnd);
            let _ = DestroyWindow(dim);
        }
    }
}

fn viewer_state(hwnd: HWND) -> Option<(View, Layout, Hit)> {
    let (id, hover) = with(|u| u.viewer.as_ref().map(|v| (v.2.clone(), v.0.hover))).flatten()?;
    let view = sessions::get(&id)?;
    let (pw, ph) = viewer_preview_size(hwnd);
    let layout = viewer_layout(&view, pw, ph);
    Some((view, layout, hover))
}

unsafe extern "system" fn viewer_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            WM_PAINT => {
                match viewer_state(hwnd) {
                    Some((view, layout, hover)) => paint(hwnd, &layout, hover, std::slice::from_ref(&view), true),
                    None => {
                        let mut ps = PAINTSTRUCT::default();
                        BeginPaint(hwnd, &mut ps);
                        let _ = EndPaint(hwnd, &ps);
                    }
                }
                LRESULT(0)
            }
            WM_ERASEBKGND => LRESULT(1),
            WM_TIMER => {
                tick();
                LRESULT(0)
            }
            WM_MOUSEMOVE => {
                let (x, y) = logical(hwnd, lparam);
                let h = viewer_state(hwnd).map(|(_, l, _)| hit(&l, x, y, true)).unwrap_or(Hit::None);
                let (changed, track) = with(|u| match u.viewer.as_mut() {
                    Some(v) => {
                        let changed = v.0.hover != h;
                        v.0.hover = h;
                        let track = !v.0.tracking;
                        v.0.tracking = true;
                        (changed, track)
                    }
                    None => (false, false),
                })
                .unwrap_or((false, false));
                if track {
                    track_leave(hwnd);
                }
                if changed {
                    let _ = InvalidateRect(Some(hwnd), None, false);
                }
                LRESULT(0)
            }
            WM_MOUSELEAVE => {
                with(|u| {
                    if let Some(v) = u.viewer.as_mut() {
                        v.0.hover = Hit::None;
                        v.0.tracking = false;
                    }
                });
                let _ = InvalidateRect(Some(hwnd), None, false);
                LRESULT(0)
            }
            WM_LBUTTONUP => {
                let (x, y) = logical(hwnd, lparam);
                if let Some((view, layout, _)) = viewer_state(hwnd) {
                    match hit(&layout, x, y, true) {
                        Hit::Pause => engine::set_paused(Some(&view.id), !view.paused),
                        Hit::Stop => engine::stop(Some(&view.id)),
                        Hit::Collapse => close_viewer(),
                        Hit::Resume(_) => engine::set_paused(Some(&view.id), false),
                        Hit::Done(_) => engine::hand_back(&view.id),
                        _ => {}
                    }
                }
                LRESULT(0)
            }
            WM_KEYDOWN if wparam.0 as u16 == VK_ESCAPE.0 => {
                close_viewer();
                LRESULT(0)
            }
            WM_ACTIVATE => {
                if (wparam.0 & 0xFFFF) as u32 == WA_INACTIVE {
                    close_viewer();
                }
                LRESULT(0)
            }
            _ => DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }
}

unsafe extern "system" fn dim_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            WM_LBUTTONDOWN | WM_RBUTTONDOWN => {
                close_viewer();
                LRESULT(0)
            }
            WM_MOUSEACTIVATE => LRESULT(MA_NOACTIVATE as isize),
            WM_PAINT => {
                let mut ps = PAINTSTRUCT::default();
                let hdc = BeginPaint(hwnd, &mut ps);
                let _ = FillRect(hdc, &ps.rcPaint, HBRUSH(GetStockObject(BLACK_BRUSH).0));
                let _ = EndPaint(hwnd, &ps);
                LRESULT(0)
            }
            _ => DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }
}
