//! Reads a window's UI Automation tree and lists the elements worth acting on,
//! numbered so the agent can refer to them. Same listing and diff rules as the
//! Mac app's AXSnapshot: an element keeps its number while it exists, and a
//! later read lists only what changed.

use std::collections::{HashMap, HashSet};

use windows::Win32::Foundation::{HWND, RECT};
use windows::Win32::System::Com::CoTaskMemFree;
use windows::Win32::System::Variant::{VARIANT, VariantGetElementCount, VariantToInt32, VariantToInt32Array, VariantToStringAlloc};
use windows::Win32::UI::Accessibility::*;
use windows::core::Result;

/// UI Automation's runtime id: stable for as long as the element exists.
pub type ElementKey = Vec<i32>;

#[derive(Clone)]
pub struct Node {
    pub index: usize,
    pub element: IUIAutomationElement,
    pub control_type: UIA_CONTROLTYPE_ID,
    /// Screen pixels.
    pub rect: RECT,
    pub patterns: Vec<&'static str>,
}

pub struct Snapshot {
    pub nodes: HashMap<usize, Node>,
    /// The full listing: header, every element line, footer.
    pub text: String,
    pub visited: usize,
    header: String,
    footer: Vec<String>,
    lines: HashMap<usize, String>,
    index_by_key: HashMap<ElementKey, usize>,
    /// Numbered elements still in the window but past max_elements this time.
    unlisted: HashSet<usize>,
    next_index: usize,
    /// Numbering restarted at 1, so numbers from the last read mean nothing.
    pub renumbered: bool,
}

// The properties read for every element, in one cross-process round trip.
const PROPS: [UIA_PROPERTY_ID; 21] = [
    UIA_RuntimeIdPropertyId,
    UIA_ControlTypePropertyId,
    UIA_NamePropertyId,
    UIA_BoundingRectanglePropertyId,
    UIA_IsEnabledPropertyId,
    UIA_HasKeyboardFocusPropertyId,
    UIA_IsOffscreenPropertyId,
    UIA_IsPasswordPropertyId,
    UIA_HelpTextPropertyId,
    UIA_ValueValuePropertyId,
    UIA_ValueIsReadOnlyPropertyId,
    UIA_ToggleToggleStatePropertyId,
    UIA_ExpandCollapseExpandCollapseStatePropertyId,
    UIA_SelectionItemIsSelectedPropertyId,
    UIA_IsInvokePatternAvailablePropertyId,
    UIA_IsValuePatternAvailablePropertyId,
    UIA_IsTogglePatternAvailablePropertyId,
    UIA_IsExpandCollapsePatternAvailablePropertyId,
    UIA_IsSelectionItemPatternAvailablePropertyId,
    UIA_IsScrollPatternAvailablePropertyId,
    UIA_IsRangeValuePatternAvailablePropertyId,
];

pub fn cache_request(auto: &IUIAutomation) -> Result<IUIAutomationCacheRequest> {
    unsafe {
        let cache = auto.CreateCacheRequest()?;
        for p in PROPS {
            cache.AddProperty(p)?;
        }
        cache.SetTreeScope(TreeScope_Subtree)?;
        cache.SetTreeFilter(&auto.ControlViewCondition()?)?;
        cache.SetAutomationElementMode(AutomationElementMode_Full)?;
        Ok(cache)
    }
}

#[derive(Default)]
struct Raw {
    key: ElementKey,
    control_type: i32,
    name: String,
    help: String,
    value: String,
    rect: RECT,
    enabled: bool,
    focused: bool,
    offscreen: bool,
    password: bool,
    read_only: bool,
    toggled: Option<i32>,
    expanded: Option<i32>,
    selected: bool,
    patterns: Vec<&'static str>,
}

fn prop(e: &IUIAutomationElement, id: UIA_PROPERTY_ID) -> Option<VARIANT> {
    unsafe { e.GetCachedPropertyValue(id).ok() }
}

fn as_bool(v: &Option<VARIANT>) -> bool {
    v.as_ref().and_then(|v| bool::try_from(v).ok()).unwrap_or(false)
}

fn as_i32(v: &Option<VARIANT>) -> Option<i32> {
    v.as_ref().and_then(|v| unsafe { VariantToInt32(v).ok() })
}

fn as_string(v: &Option<VARIANT>) -> String {
    let Some(v) = v else { return String::new() };
    unsafe {
        let Ok(p) = VariantToStringAlloc(v) else { return String::new() };
        let s = p.to_string().unwrap_or_default();
        CoTaskMemFree(Some(p.0 as *const _));
        s
    }
}

fn as_rect(v: &Option<VARIANT>) -> RECT {
    // A VT_R8 array of left, top, width, height.
    let Some(v) = v else { return RECT::default() };
    let mut d = [0f64; 4];
    unsafe {
        let n = VariantGetElementCount(v);
        if n != 4 {
            return RECT::default();
        }
        if windows::Win32::System::Variant::VariantToDoubleArray(v, &mut d, &mut 0).is_err() {
            return RECT::default();
        }
    }
    RECT { left: d[0] as i32, top: d[1] as i32, right: (d[0] + d[2]) as i32, bottom: (d[1] + d[3]) as i32 }
}

fn as_ints(v: &Option<VARIANT>) -> Vec<i32> {
    let Some(v) = v else { return Vec::new() };
    unsafe {
        let n = VariantGetElementCount(v) as usize;
        if n == 0 || n > 64 {
            return Vec::new();
        }
        let mut out = vec![0i32; n];
        let mut got = 0u32;
        if VariantToInt32Array(v, &mut out, &mut got).is_err() {
            return Vec::new();
        }
        out.truncate(got as usize);
        out
    }
}

fn read(e: &IUIAutomationElement) -> Raw {
    let mut patterns = Vec::new();
    for (id, label) in [
        (UIA_IsInvokePatternAvailablePropertyId, "invoke"),
        (UIA_IsTogglePatternAvailablePropertyId, "toggle"),
        (UIA_IsExpandCollapsePatternAvailablePropertyId, "expand"),
        (UIA_IsSelectionItemPatternAvailablePropertyId, "select"),
        (UIA_IsScrollPatternAvailablePropertyId, "scroll"),
        (UIA_IsValuePatternAvailablePropertyId, "value"),
        (UIA_IsRangeValuePatternAvailablePropertyId, "range"),
    ] {
        if as_bool(&prop(e, id)) {
            patterns.push(label);
        }
    }
    let has = |p| patterns.contains(&p);
    let toggled = if has("toggle") { as_i32(&prop(e, UIA_ToggleToggleStatePropertyId)) } else { None };
    let expanded = if has("expand") { as_i32(&prop(e, UIA_ExpandCollapseExpandCollapseStatePropertyId)) } else { None };
    Raw {
        key: as_ints(&prop(e, UIA_RuntimeIdPropertyId)),
        control_type: as_i32(&prop(e, UIA_ControlTypePropertyId)).unwrap_or(0),
        name: as_string(&prop(e, UIA_NamePropertyId)),
        help: as_string(&prop(e, UIA_HelpTextPropertyId)),
        value: if has("value") { as_string(&prop(e, UIA_ValueValuePropertyId)) } else { String::new() },
        rect: as_rect(&prop(e, UIA_BoundingRectanglePropertyId)),
        enabled: prop(e, UIA_IsEnabledPropertyId).is_none() || as_bool(&prop(e, UIA_IsEnabledPropertyId)),
        focused: as_bool(&prop(e, UIA_HasKeyboardFocusPropertyId)),
        offscreen: as_bool(&prop(e, UIA_IsOffscreenPropertyId)),
        password: as_bool(&prop(e, UIA_IsPasswordPropertyId)),
        read_only: as_bool(&prop(e, UIA_ValueIsReadOnlyPropertyId)),
        toggled,
        expanded,
        selected: has("select") && as_bool(&prop(e, UIA_SelectionItemIsSelectedPropertyId)),
        patterns,
    }
}

#[allow(non_upper_case_globals)]
pub fn role_name(id: UIA_CONTROLTYPE_ID) -> &'static str {
    match id {
        UIA_ButtonControlTypeId => "Button",
        UIA_CalendarControlTypeId => "Calendar",
        UIA_CheckBoxControlTypeId => "CheckBox",
        UIA_ComboBoxControlTypeId => "ComboBox",
        UIA_DataGridControlTypeId => "Grid",
        UIA_DataItemControlTypeId => "DataItem",
        UIA_DocumentControlTypeId => "Document",
        UIA_EditControlTypeId => "Edit",
        UIA_GroupControlTypeId => "Group",
        UIA_HeaderControlTypeId => "Header",
        UIA_HeaderItemControlTypeId => "HeaderItem",
        UIA_HyperlinkControlTypeId => "Link",
        UIA_ImageControlTypeId => "Image",
        UIA_ListControlTypeId => "List",
        UIA_ListItemControlTypeId => "ListItem",
        UIA_MenuBarControlTypeId => "MenuBar",
        UIA_MenuControlTypeId => "Menu",
        UIA_MenuItemControlTypeId => "MenuItem",
        UIA_PaneControlTypeId => "Pane",
        UIA_ProgressBarControlTypeId => "ProgressBar",
        UIA_RadioButtonControlTypeId => "RadioButton",
        UIA_ScrollBarControlTypeId => "ScrollBar",
        UIA_SliderControlTypeId => "Slider",
        UIA_SpinnerControlTypeId => "Spinner",
        UIA_SplitButtonControlTypeId => "SplitButton",
        UIA_StatusBarControlTypeId => "StatusBar",
        UIA_TabControlTypeId => "Tabs",
        UIA_TabItemControlTypeId => "Tab",
        UIA_TableControlTypeId => "Table",
        UIA_TextControlTypeId => "Text",
        UIA_ToolBarControlTypeId => "ToolBar",
        UIA_ToolTipControlTypeId => "ToolTip",
        UIA_TreeControlTypeId => "Tree",
        UIA_TreeItemControlTypeId => "TreeItem",
        UIA_WindowControlTypeId => "Window",
        UIA_TitleBarControlTypeId => "TitleBar",
        UIA_ThumbControlTypeId => "Thumb",
        UIA_SemanticZoomControlTypeId => "SemanticZoom",
        UIA_AppBarControlTypeId => "AppBar",
        UIA_CustomControlTypeId => "Custom",
        _ => "Element",
    }
}

/// Control types listed even with no actions, because their text or role helps the agent read the window.
#[allow(non_upper_case_globals)]
fn listed_role(id: UIA_CONTROLTYPE_ID) -> bool {
    !matches!(
        id,
        UIA_PaneControlTypeId
            | UIA_GroupControlTypeId
            | UIA_CustomControlTypeId
            | UIA_TitleBarControlTypeId
            | UIA_ThumbControlTypeId
            | UIA_SeparatorControlTypeId
            | UIA_ScrollBarControlTypeId
    )
}

fn clean(s: &str, limit: usize) -> String {
    let one: String = s.replace(['\n', '\r'], " ").trim().to_string();
    if one.chars().count() > limit { one.chars().take(limit).collect::<String>() + "…" } else { one }
}

fn intersects(a: &RECT, b: &RECT) -> bool {
    a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom
}

pub struct Target<'a> {
    pub hwnd: HWND,
    pub title: &'a str,
    pub app: &'a str,
    pub pid: u32,
    /// The window's visible frame in screen pixels.
    pub frame: RECT,
    /// Popups the window opened (menus, suggestion lists), listed after it.
    pub popups: &'a [IUIAutomationElement],
}

/// Element numbers carry over from `previous`: an element still there keeps
/// its number and new elements get new ones, so a diff between two reads is
/// meaningful. When most elements are new (another page), numbering restarts at 1.
pub fn take(
    auto: &IUIAutomation,
    target: &Target,
    max_elements: usize,
    previous: Option<&Snapshot>,
) -> Result<Snapshot> {
    let cache = cache_request(auto)?;
    let root = unsafe { auto.ElementFromHandle(target.hwnd)?.BuildUpdatedCache(&cache)? };

    struct Entry {
        key: Option<ElementKey>,
        indent: String,
        body: String,
        node: Option<(IUIAutomationElement, UIA_CONTROLTYPE_ID, RECT, Vec<&'static str>)>,
    }
    struct Walk<'a> {
        entries: Vec<Entry>,
        overflow: Vec<ElementKey>,
        visited: usize,
        listed: usize,
        skipped_offscreen: usize,
        truncated: bool,
        bounds: RECT,
        frame: RECT,
        max: usize,
        _p: std::marker::PhantomData<&'a ()>,
    }

    fn walk(w: &mut Walk, e: &IUIAutomationElement, depth: usize, indent: usize) {
        if w.visited >= 6000 || depth >= 60 {
            return;
        }
        w.visited += 1;
        let raw = read(e);
        let ct = UIA_CONTROLTYPE_ID(raw.control_type);
        let mut child_indent = indent;
        let actionable = raw.patterns.iter().any(|p| *p != "scroll");
        let has_text = !raw.name.is_empty() || !raw.value.is_empty();
        let interesting = depth > 0
            && (actionable || (listed_role(ct) && has_text))
            && (ct != UIA_ImageControlTypeId || !raw.name.is_empty());
        let r = raw.rect;
        if interesting && r.right > r.left && r.bottom > r.top {
            let visible = !raw.offscreen && intersects(&r, &RECT { left: w.bounds.left - 2, top: w.bounds.top - 2, right: w.bounds.right + 2, bottom: w.bounds.bottom + 2 });
            if !visible {
                w.skipped_offscreen += 1;
            } else if w.listed >= w.max {
                w.truncated = true;
                w.overflow.push(raw.key.clone());
            } else {
                w.listed += 1;
                let mut line = role_name(ct).to_string();
                if !raw.name.is_empty() {
                    line += &format!(" \"{}\"", clean(&raw.name, 100));
                }
                // Never show what's in a password field, even if the app exposes it.
                if raw.password && !raw.value.is_empty() {
                    line += " value=(hidden)";
                } else if !raw.value.is_empty() && raw.value != raw.name {
                    line += &format!(" value=\"{}\"", clean(&raw.value, 160));
                }
                if raw.value.is_empty() && !raw.help.is_empty() && raw.help != raw.name {
                    line += &format!(" help=\"{}\"", clean(&raw.help, 100));
                }
                line += &format!(
                    " @({},{} {}x{})",
                    r.left - w.frame.left,
                    r.top - w.frame.top,
                    r.right - r.left,
                    r.bottom - r.top
                );
                let settable = raw.patterns.contains(&"value") && !raw.read_only;
                let mut flags: Vec<String> = Vec::new();
                if !raw.enabled {
                    flags.push("disabled".into());
                }
                if raw.focused {
                    flags.push("focused".into());
                }
                if raw.selected {
                    flags.push("selected".into());
                }
                match raw.toggled {
                    Some(1) => flags.push("on".into()),
                    Some(2) => flags.push("mixed".into()),
                    _ => {}
                }
                match raw.expanded {
                    Some(0) => flags.push("collapsed".into()),
                    Some(1) | Some(2) => flags.push("expanded".into()),
                    _ => {}
                }
                if settable {
                    flags.push("settable".into());
                }
                let acts: Vec<&str> = raw.patterns.iter().copied().filter(|p| !matches!(*p, "value" | "range")).collect();
                if !acts.is_empty() {
                    flags.push(acts.join(","));
                }
                if !flags.is_empty() {
                    line += &format!(" [{}]", flags.join(" "));
                }
                w.entries.push(Entry {
                    key: Some(raw.key.clone()),
                    indent: "  ".repeat(indent.min(12)),
                    body: line,
                    node: Some((e.clone(), ct, r, raw.patterns.clone())),
                });
                child_indent = indent + 1;
            }
        }
        if let Ok(kids) = unsafe { e.GetCachedChildren() } {
            let n = unsafe { kids.Length() }.unwrap_or(0);
            for i in 0..n {
                if let Ok(child) = unsafe { kids.GetElement(i) } {
                    walk(w, &child, depth + 1, child_indent);
                }
            }
        }
    }

    let mut w = Walk {
        entries: Vec::new(),
        overflow: Vec::new(),
        visited: 0,
        listed: 0,
        skipped_offscreen: 0,
        truncated: false,
        bounds: target.frame,
        frame: target.frame,
        max: max_elements,
        _p: std::marker::PhantomData,
    };
    walk(&mut w, &root, 0, 0);
    for popup in target.popups {
        let Ok(p) = (unsafe { popup.BuildUpdatedCache(&cache) }) else { continue };
        w.bounds = read(&p).rect;
        w.entries.push(Entry { key: None, indent: String::new(), body: "Popup over this window:".into(), node: None });
        // Depth 1 so the popup itself is listed too (a menu, a list).
        walk(&mut w, &p, 1, 1);
    }

    // Number the elements.
    let keys: Vec<&ElementKey> = w.entries.iter().filter_map(|e| e.key.as_ref()).collect();
    let matched = previous.map(|p| keys.iter().filter(|k| p.index_by_key.contains_key(**k)).count()).unwrap_or(0);
    let renumber = previous.is_none() || keys.is_empty() || (matched as f64) < 0.4 * keys.len() as f64;
    let mut next = if renumber { 1 } else { previous.unwrap().next_index };
    let mut used = HashSet::new();
    let mut nodes = HashMap::new();
    let mut lines = HashMap::new();
    let mut index_by_key = HashMap::new();
    let mut listing = Vec::new();
    for e in w.entries {
        let (Some(key), Some((element, ct, rect, patterns))) = (e.key, e.node) else {
            listing.push(e.indent + &e.body);
            continue;
        };
        let idx = match previous.and_then(|p| p.index_by_key.get(&key)) {
            Some(&old) if !renumber && !key.is_empty() && !used.contains(&old) => old,
            _ => {
                next += 1;
                next - 1
            }
        };
        used.insert(idx);
        let line = format!("{}[{idx}] {}", e.indent, e.body);
        nodes.insert(idx, Node { index: idx, element, control_type: ct, rect, patterns });
        lines.insert(idx, line.clone());
        if !key.is_empty() {
            index_by_key.insert(key, idx);
        }
        listing.push(line);
    }

    // Elements pushed past max_elements keep their numbers for when they're
    // listed again, and aren't reported as removed.
    let mut unlisted = HashSet::new();
    if let (false, Some(prev)) = (renumber, previous) {
        for key in w.overflow {
            if let Some(&old) = prev.index_by_key.get(&key)
                && !used.contains(&old)
            {
                used.insert(old);
                index_by_key.insert(key, old);
                unlisted.insert(old);
            }
        }
    }

    let f = target.frame;
    let mut header = format!(
        "Window {} \"{}\" of {} (pid {}), {}x{} pixels. Coordinates are window-relative pixels, matching the screenshot.",
        target.hwnd.0 as usize,
        clean(target.title, 80),
        target.app,
        target.pid,
        f.right - f.left,
        f.bottom - f.top
    );
    if w.listed == 0 {
        header += "\nNo accessible elements found. Use the screenshot and x/y clicks.";
    }
    let mut footer = Vec::new();
    if w.truncated {
        footer.push("(more elements not listed; raise max_elements or scroll)".to_string());
    }
    if w.skipped_offscreen > 0 {
        footer.push(format!("({} elements scrolled out of view not listed)", w.skipped_offscreen));
    }
    let text = std::iter::once(header.clone()).chain(listing).chain(footer.iter().cloned()).collect::<Vec<_>>().join("\n");
    Ok(Snapshot {
        nodes,
        text,
        visited: w.visited,
        header,
        footer,
        lines,
        index_by_key,
        unlisted,
        next_index: next,
        renumbered: renumber && previous.is_some(),
    })
}

/// What changed between two reads of the same window, or None when the full
/// listing is the better answer (renumbered, or most lines changed).
pub fn diff(old: &Snapshot, new: &Snapshot) -> Option<String> {
    if new.renumbered {
        return None;
    }
    let mut order: Vec<usize> = new.lines.keys().copied().collect();
    order.sort();
    let added: Vec<usize> = order.iter().copied().filter(|i| !old.lines.contains_key(i)).collect();
    let changed: Vec<usize> = order.iter().copied().filter(|i| old.lines.get(i).is_some_and(|l| Some(l) != new.lines.get(i))).collect();
    let mut removed: Vec<usize> = old.lines.keys().copied().filter(|i| !new.lines.contains_key(i) && !new.unlisted.contains(i)).collect();
    removed.sort();
    let pushed_out = old.lines.keys().filter(|i| new.unlisted.contains(i)).count();
    let touched = added.len() + changed.len() + removed.len();
    if touched > 20.max(new.lines.len() / 2) {
        return None;
    }
    let mut out = vec![new.header.clone()];
    if touched == 0 {
        out.push("No changes since your last get_window_state of this window.".into());
    } else {
        out.push(format!(
            "Changes since your last get_window_state of this window. The other {} elements are unchanged and keep their numbers; pass full=true for the whole list.",
            new.lines.len() - added.len() - changed.len()
        ));
        for i in removed {
            out.push(format!("- {}", old.lines[&i].trim()));
        }
        for i in added {
            out.push(format!("+ {}", new.lines[&i].trim()));
        }
        for i in changed {
            out.push(format!("~ {}", new.lines[&i].trim()));
        }
    }
    if pushed_out > 0 {
        out.push(format!(
            "({pushed_out} elements from your last read are still there but past max_elements now; they keep their numbers)"
        ));
    }
    out.extend(new.footer.iter().cloned());
    Some(out.join("\n"))
}
