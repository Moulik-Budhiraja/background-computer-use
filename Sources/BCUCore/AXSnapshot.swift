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
    /// Numbered elements still in the window but scrolled out of view.
    let scrolledOut: Set<Int>
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
    /// its number, even while it's scrolled out of view or past max_elements,
    /// and new elements get new ones, so a diff between two reads is
    /// meaningful. When most elements are new and most of the old ones are
    /// gone (another page), numbering restarts at 1.
    public static func take(window: AXUIElement, windowID: CGWindowID, title: String, appName: String, pid: pid_t, maxElements: Int = 250, popups: [AXUIElement] = [], previous: AXSnapshotResult? = nil) -> AXSnapshotResult {
        let windowFrame = AX.frame(window) ?? .zero
        // Collected first and numbered after the walk. `element` is nil for a
        // plain text line (the popup heading).
        struct Entry { let element: AXUIElement?; let indent: String; let body: String; let node: (String, CGRect, [String], Bool)? }
        var entries: [Entry] = []
        var overflow: [(element: AXUIElement, role: String, frame: CGRect)] = []
        var outOfView: [AXUIElement] = []
        var visited = 0
        var listed = 0
        var skippedOffscreen = 0
        var truncated = false

        func clean(_ s: String, _ limit: Int = 100) -> String {
            let one = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return one.count > limit ? String(one.prefix(limit)) + "…" : one
        }

        // Walked on their own, so not again as part of the window.
        var walkedApart = Set<AXUIElement>()
        /// `clip`: what of the window can show this element, the window cut
        /// down to every scroll area it's in. A row scrolled out of a list
        /// is inside the window's frame but hidden, and a click there would
        /// land on whatever is drawn over it.
        func walk(_ el: AXUIElement, depth: Int, indent: Int, clip: CGRect) {
            guard visited < 6000, depth < 60, !walkedApart.contains(el) else { return }
            visited += 1
            let raw = read(el)
            var childIndent = indent
            let label = [raw.title, raw.desc].first { !$0.isEmpty } ?? ""
            let hasText = !label.isEmpty || !raw.value.isEmpty || !raw.placeholder.isEmpty
            let interesting = interactiveRoles.contains(raw.role) && (raw.role != "AXStaticText" || hasText) && (raw.role != "AXImage" || !label.isEmpty)
            if interesting, let f = raw.frame, f.width > 0, f.height > 0 {
                let visible = f.intersects(clip.insetBy(dx: -2, dy: -2))
                if !visible {
                    skippedOffscreen += 1
                    outOfView.append(el)
                } else if listed >= maxElements {
                    truncated = true
                    overflow.append((el, raw.role, f))
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
            var childClip = clip
            if raw.role == "AXScrollArea", let f = raw.frame, f.width > 0, f.height > 0 { childClip = clip.intersection(f) }
            for child in raw.children { walk(child, depth: depth + 1, indent: childIndent, clip: childClip) }
        }

        // A sheet (a file picker, a save panel, an alert) is the window's last
        // child, after everything else in it, and in a big web page the walk
        // would hit max_elements or its visit budget before getting there.
        // The window takes no input until the sheet is answered: list it first.
        let sheets = AX.children(window).filter { AX.string($0, "AXRole") == "AXSheet" }
        for sheet in sheets {
            // A sheet can reach past a small window's edges.
            let clip = AX.frame(sheet).map { $0.union(windowFrame) } ?? windowFrame
            entries.append(Entry(element: nil, indent: "", body: "Sheet over this window (the window behind it takes no input until it closes):", node: nil))
            walk(sheet, depth: 0, indent: 1, clip: clip)
            walkedApart.insert(sheet)
        }
        if !sheets.isEmpty {
            entries.append(Entry(element: nil, indent: "", body: "The window behind the sheet:", node: nil))
        }
        walk(window, depth: 0, indent: 0, clip: windowFrame)
        // Popups the window opened (suggestion lists, menus, dropdowns) are
        // separate windows; list them after it so their rows can be pressed.
        for popup in popups where !walkedApart.contains(popup) {
            entries.append(Entry(element: nil, indent: "", body: "Popup over this window:", node: nil))
            walk(popup, depth: 0, indent: 1, clip: AX.frame(popup) ?? windowFrame)
        }
        // Number the elements.
        let elements = entries.compactMap(\.element)
        let renumber = previous.map { prev in
            Self.renumbers(listed: elements.count, listedKnown: elements.filter { prev.indexByElement[$0] != nil }.count,
                           known: prev.indexByElement.count,
                           stillThere: (elements + overflow.map(\.element) + outOfView).filter { prev.indexByElement[$0] != nil }.count)
        } ?? true
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

        // Elements pushed past max_elements or scrolled out of view keep
        // their numbers for when they're listed again, and aren't reported
        // as removed. The agent was told those past max_elements keep their
        // numbers, so they can be acted on by them.
        var unlisted = Set<Int>()
        var scrolledOut = Set<Int>()
        if !renumber, let prev = previous {
            for o in overflow {
                if let old = prev.indexByElement[o.element], !used.contains(old) {
                    used.insert(old)
                    indexByElement[o.element] = old
                    unlisted.insert(old)
                    nodes[old] = AXNode(index: old, element: o.element, role: o.role, frame: o.frame,
                                        actions: AX.actions(o.element), valueSettable: AX.isSettable(o.element, "AXValue"))
                }
            }
            for el in outOfView {
                if let old = prev.indexByElement[el], !used.contains(old) {
                    used.insert(old)
                    indexByElement[el] = old
                    scrolledOut.insert(old)
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
                                lines: lineByIndex, indexByElement: indexByElement, unlisted: unlisted, scrolledOut: scrolledOut, nextIndex: next, renumbered: renumber && previous != nil)
    }

    /// Numbering restarts only when most listed elements are new and most
    /// elements the last read numbered are gone: another page. Scrolling
    /// lists mostly new elements, but the old ones are still there, out of
    /// view, and keep their numbers.
    static func renumbers(listed: Int, listedKnown: Int, known: Int, stillThere: Int) -> Bool {
        if listed == 0 && stillThere == 0 { return true }
        let mostlyNew = Double(listedKnown) < 0.4 * Double(listed)
        let mostlyGone = known == 0 || Double(stillThere) < 0.4 * Double(known)
        return mostlyNew && mostlyGone
    }

    /// What changed between two reads of the same window, or nil when the
    /// full listing is the better answer (renumbered, or most lines changed).
    public static func diff(from old: AXSnapshotResult, to new: AXSnapshotResult) -> String? {
        if new.renumbered { return nil }
        let order = new.lines.keys.sorted()
        let added = order.filter { old.lines[$0] == nil }
        let changed = order.filter { old.lines[$0] != nil && old.lines[$0] != new.lines[$0] }
        let removed = old.lines.keys.sorted().filter { new.lines[$0] == nil && !new.unlisted.contains($0) && !new.scrolledOut.contains($0) }
        let pushedOut = old.lines.keys.filter { new.unlisted.contains($0) }.count
        let scrolledAway = old.lines.keys.filter { new.scrolledOut.contains($0) }.count
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
        if scrolledAway > 0 { out.append("(\(scrolledAway) elements from your last read are scrolled out of view now; they keep their numbers)") }
        out += new.footer
        return out.joined(separator: "\n")
    }
}
