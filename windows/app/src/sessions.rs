//! What the tray shows about each agent session. The session threads write
//! it; the tray reads a copy. Nothing here is needed to run a tool.

use std::sync::Mutex;
use std::time::{Duration, Instant};

use windows::Win32::Foundation::POINT;

#[derive(Clone)]
pub struct AppTag {
    pub name: String,
    pub exe: String,
}

#[derive(Clone)]
pub struct View {
    pub id: String,
    /// "Claude Code", "Codex", ...
    pub label: String,
    /// Apps of the session's windows, in the order they were opened.
    pub apps: Vec<AppTag>,
    pub windows: usize,
    /// What the running call is doing ("Clicking"), while one runs.
    pub busy: Option<&'static str>,
    pub last_call: Option<Instant>,
    pub paused: bool,
    /// The app and reason of a window handed to the user.
    pub handoff: Option<(String, String)>,
    /// Where the agent last pointed, in screen pixels, and when.
    pub pointer: Option<(POINT, Instant)>,
}

impl View {
    /// Working: a call runs or ran in the last few seconds, or the agent has
    /// windows open and called in the last 30 s (it's thinking between steps),
    /// so the icon doesn't flicker between calls.
    pub fn active(&self) -> bool {
        let since = |s| self.last_call.is_some_and(|t| t.elapsed() < Duration::from_secs(s));
        !self.paused && (self.busy.is_some() || since(3) || (self.windows > 0 && since(30)))
    }

    /// Worth a preview: it has windows, or called recently.
    pub fn visible(&self) -> bool {
        self.windows > 0 || self.handoff.is_some() || self.last_call.is_some_and(|t| t.elapsed() < Duration::from_secs(60))
    }

    pub fn status_text(&self) -> String {
        if let Some((app, reason)) = &self.handoff {
            return if reason.is_empty() { format!("{app} needs you") } else { reason.clone() };
        }
        if self.paused {
            return "Paused".into();
        }
        if let Some(b) = self.busy {
            return b.into();
        }
        if self.active() || self.windows > 0 {
            let mut names: Vec<&str> = self.apps.iter().map(|a| a.name.as_str()).collect();
            names.dedup();
            return if names.is_empty() { "Working".into() } else { format!("Working in {}", names.join(", ")) };
        }
        "Idle".into()
    }
}

static VIEWS: Mutex<Vec<View>> = Mutex::new(Vec::new());
static NOTIFY: Mutex<Option<Box<dyn Fn() + Send>>> = Mutex::new(None);

/// Called (from any thread) whenever a session changes.
pub fn on_change(f: impl Fn() + Send + 'static) {
    *NOTIFY.lock().unwrap_or_else(|e| e.into_inner()) = Some(Box::new(f));
}

fn changed() {
    if let Some(f) = NOTIFY.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
        f();
    }
}

/// "Claude Code", "Codex", or the client's own name; numbered when two
/// sessions would share one.
pub fn label_for(client: Option<&str>) -> String {
    let name = client.unwrap_or("");
    let lower = name.to_lowercase();
    let base = if lower.contains("claude") {
        "Claude Code".to_string()
    } else if lower.contains("codex") {
        "Codex".to_string()
    } else if name.is_empty() {
        "Agent".to_string()
    } else {
        name.to_string()
    };
    let views = VIEWS.lock().unwrap_or_else(|e| e.into_inner());
    let taken = |l: &str| views.iter().any(|v| v.label == l);
    if !taken(&base) {
        return base;
    }
    let mut n = 2;
    while taken(&format!("{base} {n}")) {
        n += 1;
    }
    format!("{base} {n}")
}

pub fn add(id: &str, label: String) {
    VIEWS.lock().unwrap_or_else(|e| e.into_inner()).push(View {
        id: id.to_string(),
        label,
        apps: Vec::new(),
        windows: 0,
        busy: None,
        last_call: None,
        paused: false,
        handoff: None,
        pointer: None,
    });
    changed();
}

pub fn update(id: &str, f: impl FnOnce(&mut View)) {
    {
        let mut views = VIEWS.lock().unwrap_or_else(|e| e.into_inner());
        let Some(v) = views.iter_mut().find(|v| v.id == id) else { return };
        f(v);
    }
    changed();
}

pub fn all() -> Vec<View> {
    VIEWS.lock().unwrap_or_else(|e| e.into_inner()).clone()
}

pub fn get(id: &str) -> Option<View> {
    VIEWS.lock().unwrap_or_else(|e| e.into_inner()).iter().find(|v| v.id == id).cloned()
}
