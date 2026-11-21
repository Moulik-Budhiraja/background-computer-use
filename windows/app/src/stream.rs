//! Live frames of a session's agent screen for a host's preview (`frames`):
//! JPEGs at the rate asked for, on the connection that asked. A frame is
//! skipped while the client is two behind, and one that shows nothing new is
//! sent at most once a second.
//!
//! Agents share one agent screen (monitor.rs). A frame is a copy of it,
//! unless a window of a session outside this one's family (its parent and
//! subagents) is on it: then only the family's windows are drawn, each from
//! its own surface (PrintWindow), in their order on screen.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::json;
use windows::Win32::Foundation::{HWND, RECT};

use crate::host::{self, Conn};
use crate::jpeg::{self, Bgra};
use crate::{capture, gfx, monitor, win};

#[derive(Clone, Copy)]
pub struct Options {
    pub fps: u32,
    pub max_width: i32,
    pub quality: f32,
    /// One of the session's windows instead of its screen; 0 for the screen.
    pub window: u64,
    /// A window to leave out (one the user is dragging).
    pub exclude: u64,
}

impl Default for Options {
    fn default() -> Self {
        Options { fps: 15, max_width: 1600, quality: 0.6, window: 0, exclude: 0 }
    }
}

pub struct Stream {
    pub id: u64,
    pub session: String,
    conn: Arc<Conn>,
    options: Mutex<Options>,
    stopped: AtomicBool,
}

static NEXT: AtomicU64 = AtomicU64::new(1);

impl Stream {
    pub fn start(session: String, conn: Arc<Conn>, options: Options) -> Arc<Stream> {
        let s = Arc::new(Stream { id: NEXT.fetch_add(1, Ordering::Relaxed), session, conn, options: Mutex::new(options), stopped: AtomicBool::new(false) });
        let run = s.clone();
        std::thread::Builder::new().name(format!("frames {}", s.id)).spawn(move || run.run()).expect("frames thread");
        s
    }

    pub fn options(&self) -> Options {
        *self.options.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn update(&self, o: Options) {
        *self.options.lock().unwrap_or_else(|e| e.into_inner()) = o;
    }

    pub fn stop(&self) {
        self.stopped.store(true, Ordering::Relaxed);
    }

    fn run(&self) {
        let mut seq = 0u64;
        let mut last: Option<(u64, Instant)> = None;
        while !self.stopped.load(Ordering::Relaxed) {
            let o = self.options();
            let started = Instant::now();
            if self.conn.backlog() < 2
                && let Some((img, whole)) = frame(&self.session, &o)
            {
                let print = jpeg::fingerprint(&img.bits);
                if last.is_none_or(|(p, at)| p != print || at.elapsed() >= Duration::from_secs(1))
                    && let Ok(data) = jpeg::encode(&img, o.quality)
                {
                    seq += 1;
                    let mut e = json!({
                        "event": "frame", "stream": self.id, "session": self.session, "seq": seq,
                        "mime": "image/jpeg", "data": capture::base64(&data),
                    });
                    match whole {
                        Some(r) => e["display"] = json!({"width": r.right - r.left, "height": r.bottom - r.top}),
                        None => e["window"] = json!(o.window),
                    }
                    self.conn.send(&e);
                    last = Some((print, Instant::now()));
                }
            }
            let interval = Duration::from_secs_f64(1.0 / o.fps.max(1) as f64);
            std::thread::sleep(interval.saturating_sub(started.elapsed()).max(Duration::from_millis(5)));
        }
    }
}

/// The picture to send now, and the screen it shows (None for one window).
fn frame(session: &str, o: &Options) -> Option<(Bgra, Option<RECT>)> {
    if o.window != 0 {
        // A window shows only while the session (or its family) has it.
        let w = host::windows_of(&host::family(session)).into_iter().find(|w| w.id == o.window)?;
        let img = window_image(w.hwnd)?;
        let (fw, fh) = jpeg::fit(img.w, img.h, o.max_width);
        return Some((jpeg::scale(&img, fw, fh), None));
    }
    let screen = monitor::of_session(session)?.rect;
    let (sw, sh) = (screen.right - screen.left, screen.bottom - screen.top);
    let (fw, fh) = jpeg::fit(sw, sh, o.max_width);
    if o.exclude == 0 && !host::others_on(session, &screen) {
        let f = gfx::capture_screen(screen, fw, fh)?;
        return Some((Bgra { w: f.w, h: f.h, bits: f.bits }, Some(screen)));
    }
    let img = compose(session, screen, o.exclude);
    Some((jpeg::scale(&img, fw, fh), Some(screen)))
}

fn window_image(hwnd: HWND) -> Option<Bgra> {
    let img = capture::window(hwnd, win::frame(hwnd)).ok()?;
    Some(Bgra { w: img.width as i32, h: img.height as i32, bits: img.bgra })
}

/// The family's windows on `screen`, and the popups of their apps over
/// them (menus, dropdowns), drawn bottom to top over a dark background.
fn compose(session: &str, screen: RECT, exclude: u64) -> Bgra {
    let (w, h) = (screen.right - screen.left, screen.bottom - screen.top);
    let mut canvas = Bgra { w, h, bits: [0x20, 0x20, 0x20, 0xff].repeat((w * h) as usize) };
    // Bottom to top.
    let mut shown = host::shown_windows(session, &screen, exclude);
    shown.reverse();
    for hwnd in shown {
        let f = win::frame(hwnd);
        if let Some(img) = window_image(hwnd) {
            blit(&mut canvas, &img, f.left - screen.left, f.top - screen.top);
        }
    }
    canvas
}

fn blit(dst: &mut Bgra, src: &Bgra, x: i32, y: i32) {
    let x0 = x.max(0);
    let x1 = (x + src.w).min(dst.w);
    if x1 <= x0 {
        return;
    }
    for sy in 0..src.h {
        let dy = y + sy;
        if dy < 0 || dy >= dst.h {
            continue;
        }
        let s = ((sy * src.w + (x0 - x)) * 4) as usize;
        let d = ((dy * dst.w + x0) * 4) as usize;
        let n = ((x1 - x0) * 4) as usize;
        dst.bits[d..d + n].copy_from_slice(&src.bits[s..s + n]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blit_clips() {
        let mut dst = Bgra { w: 3, h: 2, bits: vec![0; 24] };
        let src = Bgra { w: 2, h: 2, bits: vec![9; 16] };
        blit(&mut dst, &src, 2, -1);
        // Only the source's bottom-left pixel lands, at (2, 0).
        let set: Vec<usize> = (0..6).filter(|i| dst.bits[i * 4] == 9).collect();
        assert_eq!(set, vec![2]);
    }
}
