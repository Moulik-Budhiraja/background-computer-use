//! `press_menu_item`: choose a menu bar item of an agent's window by its
//! titles, from the menu bar down (["File", "Save As…"]).
//!
//! A classic Win32 menu bar is read as it is and the item's command posted to
//! the window (WM_COMMAND), as a click on it would send: no menu opens. The
//! app is told each menu is about to open first (WM_INITMENUPOPUP), so it
//! fills it in and updates which items are enabled. Apps whose menu bar is
//! their own (WinUI, like Windows 11 Notepad's) get UI Automation: each menu
//! on the path is expanded, and the last item invoked.
//!
//! Titles match without their `&` mnemonic, the shortcut after a tab, a
//! trailing "..." or "…", and case.

use std::time::{Duration, Instant};

use windows::Win32::Foundation::{HWND, LPARAM, WPARAM};
use windows::Win32::System::Variant::{VARIANT, VT_I4};
use windows::Win32::UI::Accessibility::*;
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::win;

pub fn normalize(title: &str) -> String {
    let t = title.split('\t').next().unwrap_or("").replace('&', "");
    let t = t.trim();
    let t = t.strip_suffix("...").or_else(|| t.strip_suffix('…')).unwrap_or(t).trim();
    t.to_lowercase()
}

/// Choose `path` in window `hwnd` of `app`. Returns the result's text.
pub fn press(auto: &IUIAutomation, hwnd: HWND, app: &str, path: &[String]) -> Result<String, String> {
    if path.is_empty() {
        return Err("give path: menu titles from the menu bar down, like [\"File\", \"Save As…\"]".into());
    }
    let menu = unsafe { GetMenu(hwnd) };
    if !menu.0.is_null() && unsafe { GetMenuItemCount(Some(menu)) } > 0 {
        return classic(hwnd, menu, path);
    }
    automation(auto, hwnd, app, path)
}

fn item_text(menu: HMENU, i: i32) -> String {
    let mut buf = [0u16; 256];
    let n = unsafe { GetMenuStringW(menu, i as u32, Some(&mut buf), MF_BYPOSITION) };
    String::from_utf16_lossy(&buf[..n.max(0) as usize])
}

fn send(hwnd: HWND, msg: u32, w: usize, l: isize) {
    let mut result = 0usize;
    unsafe {
        let _ = SendMessageTimeoutW(hwnd, msg, WPARAM(w), LPARAM(l), SMTO_ABORTIFHUNG, 500, Some(&mut result));
    }
}

fn classic(hwnd: HWND, bar: HMENU, path: &[String]) -> Result<String, String> {
    let mut menu = bar;
    for (depth, title) in path.iter().enumerate() {
        let n = unsafe { GetMenuItemCount(Some(menu)) };
        let titles: Vec<String> = (0..n).map(|i| item_text(menu, i)).collect();
        let Some(i) = titles.iter().position(|t| !t.is_empty() && normalize(t) == normalize(title)) else {
            let shown: Vec<String> = titles.iter().filter(|t| !t.is_empty()).map(|t| format!("\"{}\"", t.split('\t').next().unwrap_or("").replace('&', ""))).collect();
            let place = if depth == 0 { "in the menu bar".to_string() } else { format!("in {}", path[..depth].join(" > ")) };
            return Err(format!("no \"{title}\" {place}. It has: {}", shown.join(", ")));
        };
        let mut info = MENUITEMINFOW { cbSize: size_of::<MENUITEMINFOW>() as u32, fMask: MIIM_STATE | MIIM_ID | MIIM_SUBMENU, ..Default::default() };
        unsafe { GetMenuItemInfoW(menu, i as u32, true, &mut info) }.map_err(|e| format!("couldn't read the menu: {e}"))?;
        if depth + 1 == path.len() {
            if !info.hSubMenu.0.is_null() {
                return Err(format!("\"{title}\" opens a menu: add the item to choose in it to the path"));
            }
            if (info.fState.0 & (MFS_DISABLED.0 | MFS_GRAYED.0)) != 0 {
                return Err(format!("{} is disabled right now", path.join(" > ")));
            }
            unsafe { PostMessageW(Some(hwnd), WM_COMMAND, WPARAM(info.wID as usize & 0xffff), LPARAM(0)) }.map_err(|e| format!("couldn't send the command: {e}"))?;
            return Ok(format!("Chose {}.", path.join(" > ")));
        }
        if info.hSubMenu.0.is_null() {
            return Err(format!("\"{title}\" has no menu under it"));
        }
        menu = info.hSubMenu;
        // What the app does as the menu opens: fill it in, enable its items.
        send(hwnd, WM_INITMENUPOPUP, menu.0 as usize, i as isize);
    }
    unreachable!()
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

/// The menu items in `el`.
fn items(auto: &IUIAutomation, el: &IUIAutomationElement) -> Vec<IUIAutomationElement> {
    unsafe {
        let Ok(cond) = auto.CreatePropertyCondition(UIA_ControlTypePropertyId, &int_variant(UIA_MenuItemControlTypeId.0)) else { return Vec::new() };
        let Ok(all) = el.FindAll(TreeScope_Descendants, &cond) else { return Vec::new() };
        (0..all.Length().unwrap_or(0)).filter_map(|i| all.GetElement(i).ok()).collect()
    }
}

fn name(e: &IUIAutomationElement) -> String {
    unsafe { e.CurrentName().map(|s| s.to_string()).unwrap_or_default() }
}

/// Where the open menus are: the window, and its app's other windows that
/// aren't app windows (menus open as windows of their own).
fn places(auto: &IUIAutomation, hwnd: HWND) -> Vec<IUIAutomationElement> {
    let pid = win::pid_tid(hwnd).0;
    let mut out: Vec<IUIAutomationElement> =
        win::top_level_windows().into_iter().filter(|h| *h != hwnd && win::is_visible(*h) && win::pid_tid(*h).0 == pid && !win::is_app_window(*h)).filter_map(|h| unsafe { auto.ElementFromHandle(h).ok() }).collect();
    if let Ok(e) = unsafe { auto.ElementFromHandle(hwnd) } {
        out.push(e);
    }
    out
}

fn is_expanded(e: &IUIAutomationElement) -> bool {
    unsafe {
        e.GetCurrentPatternAs::<IUIAutomationExpandCollapsePattern>(UIA_ExpandCollapsePatternId)
            .and_then(|p| p.CurrentExpandCollapseState())
            .is_ok_and(|s| s == ExpandCollapseState_Expanded)
    }
}

fn automation(auto: &IUIAutomation, hwnd: HWND, app: &str, path: &[String]) -> Result<String, String> {
    let root = unsafe { auto.ElementFromHandle(hwnd) }.map_err(|e| format!("couldn't read the window: {e}"))?;
    let bar = unsafe {
        let cond = auto.CreatePropertyCondition(UIA_ControlTypePropertyId, &int_variant(UIA_MenuBarControlTypeId.0)).map_err(|e| e.to_string())?;
        root.FindFirst(TreeScope_Descendants, &cond).ok()
    }
    .ok_or_else(|| format!("{app}'s window has no menu bar. Use the app's own menu buttons: find them with get_window_state."))?;
    let mut expanded: Vec<IUIAutomationElement> = Vec::new();
    let result = (|| {
        for (depth, title) in path.iter().enumerate() {
            // Its menu takes a moment to open. An app's own menu (not a
            // classic menu bar) takes the foreground as it opens, and closes
            // when the focus guard gives it back: look often.
            let deadline = Instant::now() + Duration::from_millis(1500);
            let found = loop {
                let candidates = if depth == 0 { items(auto, &bar) } else { places(auto, hwnd).iter().flat_map(|p| items(auto, p)).collect() };
                if let Some(e) = candidates.iter().find(|e| normalize(&name(e)) == normalize(title)) {
                    break Ok(e.clone());
                }
                if Instant::now() > deadline {
                    if depth > 0 && !expanded.last().is_some_and(is_expanded) {
                        break Err(format!(
                            "{app}'s {} menu closed as it opened: it's the app's own menu, which closes without the foreground, and the user keeps the foreground. Use the item's keyboard shortcut with press_key, or a button in the window, instead.",
                            path[depth - 1]
                        ));
                    }
                    let names: Vec<String> = candidates.iter().map(name).filter(|n| !n.is_empty()).map(|n| format!("\"{n}\"")).collect();
                    let place = if depth == 0 { "in the menu bar".to_string() } else { format!("in {}", path[..depth].join(" > ")) };
                    break Err(format!("no \"{title}\" {place}. It has: {}", names.join(", ")));
                }
                std::thread::sleep(Duration::from_millis(10));
            }?;
            unsafe {
                if depth + 1 == path.len() {
                    if !found.CurrentIsEnabled().map(|b| b.as_bool()).unwrap_or(true) {
                        return Err(format!("{} is disabled right now", path.join(" > ")));
                    }
                    if let Ok(p) = found.GetCurrentPatternAs::<IUIAutomationInvokePattern>(UIA_InvokePatternId) {
                        p.Invoke().map_err(|e| format!("couldn't choose {}: {e}", path.join(" > ")))?;
                    } else if let Ok(p) = found.GetCurrentPatternAs::<IUIAutomationTogglePattern>(UIA_TogglePatternId) {
                        p.Toggle().map_err(|e| format!("couldn't choose {}: {e}", path.join(" > ")))?;
                    } else {
                        return Err(format!("{} can't be chosen through UI Automation. Click it instead.", path.join(" > ")));
                    }
                    expanded.clear();
                    return Ok(format!("Chose {}.", path.join(" > ")));
                }
                match found.GetCurrentPatternAs::<IUIAutomationExpandCollapsePattern>(UIA_ExpandCollapsePatternId) {
                    Ok(p) => p.Expand().map_err(|e| format!("couldn't open {title}: {e}"))?,
                    Err(_) => found
                        .GetCurrentPatternAs::<IUIAutomationInvokePattern>(UIA_InvokePatternId)
                        .and_then(|p| p.Invoke())
                        .map_err(|e| format!("couldn't open {title}: {e}"))?,
                }
                expanded.push(found);
            }
        }
        unreachable!()
    })();
    // A path that went wrong leaves no menu open.
    for e in expanded.iter().rev() {
        if let Ok(p) = unsafe { e.GetCurrentPatternAs::<IUIAutomationExpandCollapsePattern>(UIA_ExpandCollapsePatternId) } {
            let _ = unsafe { p.Collapse() };
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::normalize;

    #[test]
    fn titles_match_loosely() {
        assert_eq!(normalize("Save &As...\tCtrl+Shift+S"), "save as");
        assert_eq!(normalize("Save As…"), "save as");
        assert_eq!(normalize("&File"), "file");
        assert_eq!(normalize("Word Wrap"), normalize("word wrap"));
    }
}
