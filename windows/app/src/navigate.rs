//! `navigate`: load a URL in an agent's browser window, and answer the
//! "Leave site?" a page can ask when a step leaves it.
//!
//! The URL goes into the window's address bar through UI Automation (set, not
//! typed: no shortcut, so no modifier keys are marked down on the browser's
//! thread, which the user's own window of it may share) and Return is posted
//! to the window. Without an address bar UI Automation can set, it's Ctrl+L
//! and the URL as text. Then it waits for the page to say it has the new
//! address, 5 s at most.
//!
//! Chromium asks "Leave site?" in a dialog of its own, owned by the window
//! whose page asks. After an agent's step in a browser window, a watch looks
//! for such a dialog over that window for 4 s and presses Leave: the agent's
//! step left the page. Never while the user drives an agent's screen, where
//! their own input reaches the browser. What pages asked goes into the
//! session's next tool result.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use windows::Win32::Foundation::HWND;
use windows::Win32::System::Com::{CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx};
use windows::Win32::UI::Accessibility::*;
use windows::Win32::UI::Input::KeyboardAndMouse::{VK_CONTROL, VK_L};
use windows::Win32::UI::WindowsAndMessaging::{GA_ROOTOWNER, GetAncestor};
use windows::Win32::System::Variant::{VARIANT, VT_BSTR, VT_I4, VariantClear};
use windows::core::BSTR;

use crate::{browser, host, input, win};

/// The URL to load for what an agent passed: as given when it has a scheme,
/// with https:// in front of a bare host ("example.com/a"; http:// for
/// localhost and IP addresses), None for anything else (words to search for).
/// The Mac's `BrowserAutomation.loadableURL`.
pub fn loadable_url(text: &str) -> Option<String> {
    let t = text.trim();
    if t.is_empty() {
        return None;
    }
    let lower = t.to_lowercase();
    if let Some(i) = t.find("://")
        && i > 0
        && t[..i].chars().next().is_some_and(|c| c.is_ascii_alphabetic())
        && t[..i].chars().all(|c| c.is_ascii_alphanumeric() || "+.-".contains(c))
    {
        return Some(t.to_string());
    }
    for scheme in ["about:", "data:", "javascript:", "mailto:", "file:", "chrome:", "edge:", "view-source:", "blob:"] {
        if lower.starts_with(scheme) {
            return Some(t.to_string());
        }
    }
    // A bare host has no spaces; with them it's words to search for.
    if t.chars().any(char::is_whitespace) {
        return None;
    }
    let host_port: String = lower.chars().take_while(|c| !"/?#".contains(*c)).collect();
    let mut host = host_port.clone();
    if host_port.starts_with('[') {
        let close = host_port.find(']')?;
        let rest = &host_port[close + 1..];
        if !(rest.is_empty() || (rest.len() > 1 && rest.starts_with(':') && rest[1..].chars().all(|c| c.is_ascii_digit()))) {
            return None;
        }
        return Some(format!("http://{t}"));
    }
    if let Some(colon) = host_port.find(':') {
        host = host_port[..colon].to_string();
        let port = &host_port[colon + 1..];
        if port.is_empty() || !port.chars().all(|c| c.is_ascii_digit()) {
            return None;
        }
    }
    let labels: Vec<&str> = host.split('.').collect();
    if !labels.iter().all(|l| !l.is_empty() && l.chars().all(|c| c.is_alphanumeric() || c == '-')) {
        return None;
    }
    if host == "localhost" || host.ends_with(".localhost") {
        return Some(format!("http://{t}"));
    }
    if labels.len() == 4 && labels.iter().all(|l| l.chars().all(|c| c.is_ascii_digit())) {
        return Some(format!("http://{t}"));
    }
    if labels.len() < 2 || !labels.last().unwrap().chars().any(char::is_alphabetic) {
        return None;
    }
    Some(format!("https://{t}"))
}

fn int_variant(v: i32) -> VARIANT {
    let mut var = VARIANT::default();
    unsafe {
        let inner = &mut *var.Anonymous.Anonymous;
        inner.vt = VT_I4;
        inner.Anonymous.lVal = v;
    }
    var
}

/// Elements of a control type.
fn of_type(auto: &IUIAutomation, kind: UIA_CONTROLTYPE_ID) -> Option<IUIAutomationCondition> {
    unsafe { auto.CreatePropertyCondition(UIA_ControlTypePropertyId, &int_variant(kind.0)).ok() }
}

/// Elements of a class name.
fn of_class(auto: &IUIAutomation, class: &str) -> Option<IUIAutomationCondition> {
    let mut var = VARIANT::default();
    unsafe {
        let inner = &mut *var.Anonymous.Anonymous;
        inner.vt = VT_BSTR;
        inner.Anonymous.bstrVal = std::mem::ManuallyDrop::new(BSTR::from(class));
        let cond = auto.CreatePropertyCondition(UIA_ClassNamePropertyId, &var).ok();
        let _ = VariantClear(&mut var);
        cond
    }
}

/// The address the window's page has: the web content's value.
fn page_url(auto: &IUIAutomation, hwnd: HWND) -> Option<String> {
    unsafe {
        let root = auto.ElementFromHandle(hwnd).ok()?;
        let cond = of_type(auto, UIA_DocumentControlTypeId)?;
        let doc = root.FindFirst(TreeScope_Descendants, &cond).ok()?;
        let v: IUIAutomationValuePattern = doc.GetCurrentPatternAs(UIA_ValuePatternId).ok()?;
        let s = v.CurrentValue().ok()?.to_string();
        (!s.is_empty()).then_some(s)
    }
}

/// Chromium's address bar (its views class name, the same in every language).
fn address_bar(auto: &IUIAutomation, hwnd: HWND) -> Option<IUIAutomationElement> {
    unsafe {
        let root = auto.ElementFromHandle(hwnd).ok()?;
        let cond = of_class(auto, "OmniboxViewViews")?;
        root.FindFirst(TreeScope_Descendants, &cond).ok()
    }
}

/// Put `url` in the address bar: set through UI Automation, or, when the bar
/// says its value is read-only (it can, until it has been focused), clicked
/// (which focuses it and selects what's there) and set or typed.
fn fill_address_bar(hwnd: HWND, bar: &IUIAutomationElement, url: &str) -> Result<(), String> {
    let set = || unsafe { bar.GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId).and_then(|v| v.SetValue(&BSTR::from(url))) };
    if set().is_ok() {
        return Ok(());
    }
    let r = unsafe { bar.CurrentBoundingRectangle() }.map_err(|e| e.to_string())?;
    let center = windows::Win32::Foundation::POINT { x: (r.left + r.right) / 2, y: (r.top + r.bottom) / 2 };
    input::click(hwnd, center, input::Button::Left, 1)?;
    std::thread::sleep(Duration::from_millis(100));
    if set().is_ok() {
        return Ok(());
    }
    input::type_text(hwnd, url)
}

/// Load `given` in the agent's browser window `id`. Returns the result's text.
pub fn navigate(auto: &IUIAutomation, id: u64, hwnd: HWND, app: &str, given: &str) -> Result<String, String> {
    let given = given.trim();
    if given.is_empty() {
        return Err("give url".into());
    }
    let url = loadable_url(given).ok_or_else(|| {
        format!("\"{given}\" isn't a URL. Give a full one, like https://example.com. navigate doesn't search: to search, load the search page's URL with the query in it.")
    })?;
    let pid = win::pid_tid(hwnd).0;
    if !win::exe_path(pid).is_some_and(|exe| browser::is_browser(&exe)) {
        return Err(format!("navigate works in browsers only. In {app}, click the address bar, type_text the URL and \"\\n\"."));
    }
    // A window that just opened may not have its first page yet.
    let t = Instant::now();
    let mut before = page_url(auto, hwnd);
    while before.is_none() && t.elapsed() < Duration::from_secs(2) {
        std::thread::sleep(Duration::from_millis(100));
        before = page_url(auto, hwnd);
    }
    match address_bar(auto, hwnd) {
        Some(bar) => {
            fill_address_bar(hwnd, &bar, &url).map_err(|e| format!("{app} didn't take the URL ({e}). Click the address bar, type_text the URL and \"\\n\"."))?;
            input::type_text(hwnd, "\n")?;
        }
        None => {
            input::press_key(hwnd, VK_L, &[VK_CONTROL])?;
            input::type_text(hwnd, &format!("{url}\n"))?;
        }
    }
    // The page has the new address once the browser has started on it. One
    // that settles on another address than asked for was redirected there.
    let t = Instant::now();
    let mut moved: Option<(String, Instant)> = None;
    let loaded = loop {
        std::thread::sleep(Duration::from_millis(100));
        let now = page_url(auto, hwnd);
        if let Some(n) = &now
            && same_url(n, &url)
        {
            break Some(n.clone());
        }
        match (&now, &moved) {
            (Some(n), Some((m, since))) if n == m => {
                if since.elapsed() > Duration::from_millis(1500) {
                    break Some(n.clone());
                }
            }
            (Some(n), _) if Some(n) != before.as_ref() => moved = Some((n.clone(), Instant::now())),
            _ => {}
        }
        if t.elapsed() > Duration::from_secs(5) {
            break None;
        }
    };
    Ok(match loaded {
        Some(at) => format!("Loaded {at} in window {id}. Next: get_window_state window_id={id} (it waits for the page to settle)."),
        None => format!("Loading {url} in window {id}. Next: get_window_state window_id={id} (it waits for the page to settle)."),
    })
}

/// The same address, but for a trailing slash and the case of its scheme and host.
fn same_url(a: &str, b: &str) -> bool {
    let norm = |u: &str| {
        let u = u.trim_end_matches('/');
        match u.find("://") {
            Some(i) => {
                let rest = &u[i + 3..];
                let host_end = rest.find('/').unwrap_or(rest.len());
                format!("{}://{}{}", u[..i].to_lowercase(), rest[..host_end].to_lowercase(), &rest[host_end..])
            }
            None => u.to_string(),
        }
    };
    norm(a) == norm(b)
}

// ---------- "Leave site?" ----------

/// How long after a step in a browser begins the watch looks out for a page
/// asking "Leave site?".
const WATCH: Duration = Duration::from_millis(4000);

struct Watch {
    until: Instant,
}

/// Running watches, by agent window; and what pages asked, by session.
static WATCHES: Mutex<Option<HashMap<usize, Watch>>> = Mutex::new(None);
static ANSWERS: Mutex<Option<HashMap<String, Vec<String>>>> = Mutex::new(None);
/// Whether each process is a Chromium browser's, once looked up.
static CHROMIUM: Mutex<Option<HashMap<u32, bool>>> = Mutex::new(None);

/// A step in `session`'s browser window `hwnd` began: watch it for a
/// "Leave site?" for 4 s, or keep its running watch going that long.
pub fn watch_leave(session: &str, hwnd: HWND) {
    let pid = win::pid_tid(hwnd).0;
    let chromium = {
        let mut known = CHROMIUM.lock().unwrap_or_else(|e| e.into_inner());
        *known.get_or_insert_with(HashMap::new).entry(pid).or_insert_with(|| win::exe_path(pid).is_some_and(|exe| browser::is_chromium(&exe)))
    };
    if !chromium {
        return;
    }
    {
        let mut w = WATCHES.lock().unwrap_or_else(|e| e.into_inner());
        let w = w.get_or_insert_with(HashMap::new);
        if let Some(running) = w.get_mut(&(hwnd.0 as usize)) {
            running.until = Instant::now() + WATCH;
            return;
        }
        w.insert(hwnd.0 as usize, Watch { until: Instant::now() + WATCH });
    }
    let session = session.to_string();
    let key = hwnd.0 as usize;
    // Dialogs already up are someone else's business: noted now, before the
    // step runs and can raise one of its own.
    let mut looked: Vec<usize> = dialogs_of(hwnd).iter().map(|h| h.0 as usize).collect();
    std::thread::spawn(move || {
        let hwnd = HWND(key as *mut _);
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        }
        let auto: Option<IUIAutomation> = unsafe { CoCreateInstance(&CUIAutomation8, None, CLSCTX_INPROC_SERVER).ok() };
        loop {
            let over = {
                let mut w = WATCHES.lock().unwrap_or_else(|e| e.into_inner());
                let w = w.get_or_insert_with(HashMap::new);
                let over = w.get(&key).is_none_or(|x| Instant::now() >= x.until);
                if over {
                    w.remove(&key);
                }
                over
            };
            if over {
                return;
            }
            if let Some(auto) = &auto {
                for d in dialogs_of(hwnd) {
                    if looked.contains(&(d.0 as usize)) || host::any_user_in_control() {
                        continue;
                    }
                    match answer_leave(auto, d) {
                        Some(Some(text)) => {
                            looked.push(d.0 as usize);
                            eprintln!("answered Leave for a page that asked \"{text}\" after an agent's step");
                            ANSWERS.lock().unwrap_or_else(|e| e.into_inner()).get_or_insert_with(HashMap::new).entry(session.clone()).or_default().push(text);
                        }
                        // Not one (or not drawn yet: its buttons come a moment later).
                        Some(None) => looked.push(d.0 as usize),
                        None => {}
                    }
                }
            }
            std::thread::sleep(Duration::from_millis(30));
        }
    });
}

/// The visible windows `hwnd` owns: its dialogs.
fn dialogs_of(hwnd: HWND) -> Vec<HWND> {
    win::top_level_windows().into_iter().filter(|h| *h != hwnd && win::is_visible(*h) && unsafe { GetAncestor(*h, GA_ROOTOWNER) } == hwnd).collect()
}

/// Press Leave on a dialog asking whether to leave a page: one with Leave and
/// Cancel, four buttons at most. Some(text it said) when pressed, Some(None)
/// when it's another dialog, None while it has no buttons yet.
fn answer_leave(auto: &IUIAutomation, dialog: HWND) -> Option<Option<String>> {
    unsafe {
        let root = auto.ElementFromHandle(dialog).ok()?;
        let buttons = root.FindAll(TreeScope_Descendants, &of_type(auto, UIA_ButtonControlTypeId)?).ok()?;
        let n = buttons.Length().ok()?;
        if n == 0 {
            return None;
        }
        let mut leave = None;
        let mut cancel = false;
        for i in 0..n {
            let b = buttons.GetElement(i).ok()?;
            let name = b.CurrentName().map(|s| s.to_string()).unwrap_or_default();
            if name == "Leave" {
                leave = Some(b);
            } else if name == "Cancel" {
                cancel = true;
            }
        }
        let (Some(leave), true, true) = (leave, cancel, n <= 4) else { return Some(None) };
        let texts = root.FindAll(TreeScope_Descendants, &of_type(auto, UIA_TextControlTypeId)?).ok();
        let mut said = Vec::new();
        if let Some(t) = texts {
            for i in 0..t.Length().unwrap_or(0).min(4) {
                if let Ok(e) = t.GetElement(i)
                    && let Ok(name) = e.CurrentName()
                    && !name.is_empty()
                {
                    said.push(name.to_string().chars().take(160).collect::<String>());
                }
            }
        }
        let p: IUIAutomationInvokePattern = leave.GetCurrentPatternAs(UIA_InvokePatternId).ok()?;
        p.Invoke().ok()?;
        Some(Some(if said.is_empty() { win::title(dialog) } else { said.join(" ") }))
    }
}

/// What pages asked and got Leave since the session's last call, for its result.
pub fn take_answers(session: &str) -> Option<String> {
    let asked = ANSWERS.lock().unwrap_or_else(|e| e.into_inner()).as_mut()?.remove(session)?;
    (!asked.is_empty()).then(|| "\n[page] ".to_string() + &asked.iter().map(|a| format!("A page asked \"{a}\" as your step left it: answered Leave.")).collect::<Vec<_>>().join(" "))
}

#[cfg(test)]
mod tests {
    use super::loadable_url;

    #[test]
    fn same_urls() {
        assert!(super::same_url("https://Example.com/", "https://example.com"));
        assert!(super::same_url("file:///C:/a/page.html", "file:///C:/a/page.html"));
        assert!(!super::same_url("https://example.com/a", "https://example.com/b"));
    }

    #[test]
    fn urls() {
        assert_eq!(loadable_url("https://example.com/a").as_deref(), Some("https://example.com/a"));
        assert_eq!(loadable_url("example.com/a?b").as_deref(), Some("https://example.com/a?b"));
        assert_eq!(loadable_url("localhost:3000").as_deref(), Some("http://localhost:3000"));
        assert_eq!(loadable_url("192.168.0.1").as_deref(), Some("http://192.168.0.1"));
        assert_eq!(loadable_url("file:///C:/x.html").as_deref(), Some("file:///C:/x.html"));
        assert_eq!(loadable_url("about:blank").as_deref(), Some("about:blank"));
        assert_eq!(loadable_url("cheap flights"), None);
        assert_eq!(loadable_url("weather"), None);
        assert_eq!(loadable_url("1.2.3"), None);
    }
}
