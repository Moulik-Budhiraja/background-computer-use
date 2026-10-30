import AppKit
import ApplicationServices

public struct AXNode {
    public let index: Int
    public let element: AXUIElement
    public let role: String
    public let frame: CGRect          // global coordinates
    public let actions: [String]
    public let valueSettable: Bool
}

public struct AXSnapshotResult {
    public let windowID: CGWindowID
    public let nodes: [Int: AXNode]
    /// The full listing: header, every element line, footer.
    public let text: String
    public let visited: Int
    let header: String
    let footer: [String]
    /// Each element's line (indent, number, description) by element number.
    let lines: [Int: String]
    let indexByElement: [AXUIElement: Int]
    /// Numbered elements still in the window but past max_elements this time.
    let unlisted: Set<Int>
    let nextIndex: Int
    /// True when numbering restarted at 1, so numbers from the last read mean nothing.
    public let renumbered: Bool
}

/// Walks a window's accessibility tree and lists the elements worth acting on.
public enum AXSnapshot {
    private static let attrs = ["AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXValue",
                                "AXPosition", "AXSize", "AXEnabled", "AXFocused", "AXChildren",
                                "AXPlaceholderValue", "AXSelected", "AXHelp"]

    private static let interactiveRoles: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXComboBox", "AXLink", "AXMenuItem", "AXMenuButton", "AXSlider", "AXTab", "AXTabGroup",
        "AXCell", "AXRow", "AXDisclosureTriangle", "AXIncrementor", "AXSearchField", "AXSecureTextField",
        "AXSegmentedControl", "AXColorWell", "AXDateField", "AXStepper", "AXSwitch", "AXToggle",
        "AXMenuBarItem", "AXOutline", "AXList", "AXTable", "AXScrollBar", "AXImage", "AXHeading",
        "AXStaticText", "AXWebArea", "AXToolbar", "AXSheet", "AXDialog", "AXPopover",
    ]

    private struct Raw {
        var role = "", subrole = "", title = "", desc = "", value = "", placeholder = "", help = ""
        var frame: CGRect?
        var enabled = true, focused = false, selected = false
        var children: [AXUIElement] = []
    }

    private static func read(_ el: AXUIElement) -> Raw {
        var raw = Raw()
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(el, attrs as CFArray, [], &values) == .success,
              let list = values as? [AnyObject], list.count == attrs.count else { return raw }
        func str(_ i: Int) -> String {
            let v = list[i]
            if let s = v as? String { return s }
            if let n = v as? NSNumber, CFGetTypeID(v) != AXValueGetTypeID() { return n.stringValue }
            return ""
        }
        func bool(_ i: Int) -> Bool? { (list[i] as? NSNumber).map { $0.boolValue } }
        raw.role = str(0); raw.subrole = str(1); raw.title = str(2); raw.desc = str(3); raw.value = str(4)
        raw.placeholder = str(10); raw.help = str(12)
        var pos: CGPoint?, size: CGSize?
        if CFGetTypeID(list[5]) == AXValueGetTypeID() {
            var p = CGPoint.zero
            if AXValueGetValue(unsafeBitCast(list[5], to: AXValue.self), .cgPoint, &p) { pos = p }
        }
        if CFGetTypeID(list[6]) == AXValueGetTypeID() {
            var s = CGSize.zero
            if AXValueGetValue(unsafeBitCast(list[6], to: AXValue.self), .cgSize, &s) { size = s }
        }
        if let pos, let size { raw.frame = CGRect(origin: pos, size: size) }
        raw.enabled = bool(7) ?? true
        raw.focused = bool(8) ?? false
        raw.selected = bool(11) ?? false
        if let kids = list[9] as? [AnyObject] {
            raw.children = kids.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? unsafeBitCast($0, to: AXUIElement.self) : nil }
        }
        return raw
    }

    /// Element numbers carry over from `previous`: an element still there keeps
    /// its number and new elements get new ones, so a diff between two reads
    /// is meaningful. When most elements are new (another page), numbering
    /// restarts at 1.
    public static func take(window: AXUIElement, windowID: CGWindowID, title: String, appName: String, pid: pid_t, maxElements: Int = 250, popups: [AXUIElement] = [], previous: AXSnapshotResult? = nil) -> AXSnapshotResult {
        let windowFrame = AX.frame(window) ?? .zero
        // Collected first and numbered after the walk. `element` is nil for a
        // plain text line (the popup heading).
        struct Entry { let element: AXUIElement?; let indent: String; let body: String; let node: (String, CGRect, [String], Bool)? }
        var entries: [Entry] = []
        var overflow: [AXUIElement] = []
        var visited = 0
        var listed = 0
        var skippedOffscreen = 0
        var truncated = false

        func clean(_ s: String, _ limit: Int = 100) -> String {
            let one = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return one.count > limit ? String(one.prefix(limit)) + "…" : one
        }

        var bounds = windowFrame
        func walk(_ el: AXUIElement, depth: Int, indent: Int) {
            guard visited < 6000, depth < 60 else { return }
            visited += 1
            let raw = read(el)
            var childIndent = indent
            let label = [raw.title, raw.desc].first { !$0.isEmpty } ?? ""
            let hasText = !label.isEmpty || !raw.value.isEmpty || !raw.placeholder.isEmpty
            let interesting = interactiveRoles.contains(raw.role) && (raw.role != "AXStaticText" || hasText) && (raw.role != "AXImage" || !label.isEmpty)
            if interesting, let f = raw.frame, f.width > 0, f.height > 0 {
                let visible = f.intersects(bounds.insetBy(dx: -2, dy: -2))
                if !visible {
                    skippedOffscreen += 1
                } else if listed >= maxElements {
                    truncated = true
                    overflow.append(el)
                } else {
                    listed += 1
                    let actions = AX.actions(el)
                    let settable = AX.isSettable(el, "AXValue")
                    var line = raw.role.replacingOccurrences(of: "AX", with: "")
                    if !raw.subrole.isEmpty && raw.subrole != "AXUnknown" { line += "(\(raw.subrole.replacingOccurrences(of: "AX", with: "")))" }
                    if !label.isEmpty { line += " \"\(clean(label))\"" }
                    // Never show what's in a password field, even if the app exposes it.
                    let secure = raw.role == "AXSecureTextField" || raw.subrole == "AXSecureTextField"
                    if secure && !raw.value.isEmpty { line += " value=(hidden)" }
                    else if !raw.value.isEmpty && raw.value != label { line += " value=\"\(clean(raw.value, 160))\"" }
                    if raw.value.isEmpty && !raw.placeholder.isEmpty { line += " placeholder=\"\(clean(raw.placeholder))\"" }
                    let local = CGRect(x: f.minX - windowFrame.minX, y: f.minY - windowFrame.minY, width: f.width, height: f.height)
                    line += " @(\(Int(local.minX)),\(Int(local.minY)) \(Int(local.width))x\(Int(local.height)))"
                    var flags: [String] = []
                    if !raw.enabled { flags.append("disabled") }
                    if raw.focused { flags.append("focused") }
                    if raw.selected { flags.append("selected") }
                    if settable { flags.append("settable") }
                    // Skip noise and app-defined custom actions ("Name:…\ntarget:…").
                    let acts = actions.filter { $0.hasPrefix("AX") && !$0.contains(":") && !$0.contains("\n")
                        && $0 != "AXScrollToVisible" && $0 != "AXShowDefaultUI" && $0 != "AXShowAlternateUI" }
                        .map { $0.replacingOccurrences(of: "AX", with: "").lowercased() }
                    if !acts.isEmpty { flags.append(acts.joined(separator: ",")) }
                    if !flags.isEmpty { line += " [\(flags.joined(separator: " "))]" }
                    entries.append(Entry(element: el, indent: String(repeating: "  ", count: min(indent, 12)), body: line, node: (raw.role, f, actions, settable)))
                    childIndent = indent + 1
                }
            }
            for child in raw.children { walk(child, depth: depth + 1, indent: childIndent) }
        }

        walk(window, depth: 0, indent: 0)
        // Popups the window opened (suggestion lists, menus, dropdowns) are
        // separate windows; list them after it so their rows can be pressed.
        for popup in popups {
            bounds = AX.frame(popup) ?? windowFrame
            entries.append(Entry(element: nil, indent: "", body: "Popup over this window:", node: nil))
            walk(popup, depth: 0, indent: 1)
        }
        // Number the elements.
        let elements = entries.compactMap(\.element)
        let matched = previous.map { prev in elements.filter { prev.indexByElement[$0] != nil }.count } ?? 0
        let renumber = previous == nil || elements.isEmpty || Double(matched) < 0.4 * Double(elements.count)
        var next = renumber ? 1 : previous!.nextIndex
        var used = Set<Int>()
        var nodes: [Int: AXNode] = [:]
        var lineByIndex: [Int: String] = [:]
        var indexByElement: [AXUIElement: Int] = [:]
        var listing: [String] = []
        for e in entries {
            guard let el = e.element, let n = e.node else { listing.append(e.indent + e.body); continue }
            var idx: Int
            if !renumber, let old = previous!.indexByElement[el], !used.contains(old) {
                idx = old
            } else {
                idx = next
                next += 1
            }
            used.insert(idx)
            let line = e.indent + "[\(idx)] " + e.body
            nodes[idx] = AXNode(index: idx, element: el, role: n.0, frame: n.1, actions: n.2, valueSettable: n.3)
            lineByIndex[idx] = line
            indexByElement[el] = idx
            listing.append(line)
        }

        // Elements pushed past max_elements keep their numbers for when
        // they're listed again, and aren't reported as removed.
        var unlisted = Set<Int>()
        if !renumber, let prev = previous {
            for el in overflow {
                if let old = prev.indexByElement[el], !used.contains(old) {
                    used.insert(old)
                    indexByElement[el] = old
                    unlisted.insert(old)
                }
            }
        }

        var header = "Window \(windowID) \"\(clean(title, 80))\" of \(appName) (pid \(pid)), \(Int(windowFrame.width))x\(Int(windowFrame.height)) points. Coordinates are window-relative points; the screenshot is 1 pixel per point."
        if listed == 0 { header += "\nNo accessible elements found. Use the screenshot and x/y clicks." }
        var footer: [String] = []
        if truncated { footer.append("(more elements not listed; raise max_elements or scroll)") }
        if skippedOffscreen > 0 { footer.append("(\(skippedOffscreen) elements scrolled out of view not listed)") }
        let text = ([header] + listing + footer).joined(separator: "\n")
        return AXSnapshotResult(windowID: windowID, nodes: nodes, text: text, visited: visited, header: header, footer: footer,
                                lines: lineByIndex, indexByElement: indexByElement, unlisted: unlisted, nextIndex: next, renumbered: renumber && previous != nil)
    }

    /// What changed between two reads of the same window, or nil when the
    /// full listing is the better answer (renumbered, or most lines changed).
    public static func diff(from old: AXSnapshotResult, to new: AXSnapshotResult) -> String? {
        if new.renumbered { return nil }
        let order = new.lines.keys.sorted()
        let added = order.filter { old.lines[$0] == nil }
        let changed = order.filter { old.lines[$0] != nil && old.lines[$0] != new.lines[$0] }
        let removed = old.lines.keys.sorted().filter { new.lines[$0] == nil && !new.unlisted.contains($0) }
        let pushedOut = old.lines.keys.filter { new.unlisted.contains($0) }.count
        let touched = added.count + changed.count + removed.count
        if touched > max(20, new.lines.count / 2) { return nil }
        var out = [new.header]
        if touched == 0 {
            out.append("No changes since your last get_window_state of this window.")
        } else {
            out.append("Changes since your last get_window_state of this window. The other \(new.lines.count - added.count - changed.count) elements are unchanged and keep their numbers; pass full=true for the whole list.")
            let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespaces) }
            for i in removed { out.append("- " + trim(old.lines[i]!)) }
            for i in added { out.append("+ " + trim(new.lines[i]!)) }
            for i in changed { out.append("~ " + trim(new.lines[i]!)) }
        }
        if pushedOut > 0 { out.append("(\(pushedOut) elements from your last read are still there but past max_elements now; they keep their numbers)") }
        out += new.footer
        return out.joined(separator: "\n")
    }
}
