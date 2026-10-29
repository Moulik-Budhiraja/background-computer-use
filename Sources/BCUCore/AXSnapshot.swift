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
    public let text: String
    public let visited: Int
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

    public static func take(window: AXUIElement, windowID: CGWindowID, title: String, appName: String, pid: pid_t, maxElements: Int = 250) -> AXSnapshotResult {
        let windowFrame = AX.frame(window) ?? .zero
        var nodes: [Int: AXNode] = [:]
        var lines: [String] = []
        var visited = 0
        var listed = 0
        var skippedOffscreen = 0
        var truncated = false

        func clean(_ s: String, _ limit: Int = 100) -> String {
            let one = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return one.count > limit ? String(one.prefix(limit)) + "…" : one
        }

        func walk(_ el: AXUIElement, depth: Int, indent: Int) {
            guard visited < 6000, depth < 60 else { return }
            visited += 1
            let raw = read(el)
            var childIndent = indent
            let label = [raw.title, raw.desc].first { !$0.isEmpty } ?? ""
            let hasText = !label.isEmpty || !raw.value.isEmpty || !raw.placeholder.isEmpty
            let interesting = interactiveRoles.contains(raw.role) && (raw.role != "AXStaticText" || hasText) && (raw.role != "AXImage" || !label.isEmpty)
            if interesting, let f = raw.frame, f.width > 0, f.height > 0 {
                let visible = f.intersects(windowFrame.insetBy(dx: -2, dy: -2))
                if !visible {
                    skippedOffscreen += 1
                } else if listed >= maxElements {
                    truncated = true
                } else {
                    listed += 1
                    let idx = listed
                    let actions = AX.actions(el)
                    let settable = AX.isSettable(el, "AXValue")
                    nodes[idx] = AXNode(index: idx, element: el, role: raw.role, frame: f, actions: actions, valueSettable: settable)
                    var line = String(repeating: "  ", count: min(indent, 12)) + "[\(idx)] \(raw.role.replacingOccurrences(of: "AX", with: ""))"
                    if !raw.subrole.isEmpty && raw.subrole != "AXUnknown" { line += "(\(raw.subrole.replacingOccurrences(of: "AX", with: "")))" }
                    if !label.isEmpty { line += " \"\(clean(label))\"" }
                    if !raw.value.isEmpty && raw.value != label { line += " value=\"\(clean(raw.value, 160))\"" }
                    if raw.value.isEmpty && !raw.placeholder.isEmpty { line += " placeholder=\"\(clean(raw.placeholder))\"" }
                    let local = CGRect(x: f.minX - windowFrame.minX, y: f.minY - windowFrame.minY, width: f.width, height: f.height)
                    line += " @(\(Int(local.minX)),\(Int(local.minY)) \(Int(local.width))x\(Int(local.height)))"
                    var flags: [String] = []
                    if !raw.enabled { flags.append("disabled") }
                    if raw.focused { flags.append("focused") }
                    if raw.selected { flags.append("selected") }
                    if settable { flags.append("settable") }
                    let acts = actions.filter { $0 != "AXScrollToVisible" && $0 != "AXShowDefaultUI" && $0 != "AXShowAlternateUI" }
                        .map { $0.replacingOccurrences(of: "AX", with: "").lowercased() }
                    if !acts.isEmpty { flags.append(acts.joined(separator: ",")) }
                    if !flags.isEmpty { line += " [\(flags.joined(separator: " "))]" }
                    lines.append(line)
                    childIndent = indent + 1
                }
            }
            for child in raw.children { walk(child, depth: depth + 1, indent: childIndent) }
        }

        walk(window, depth: 0, indent: 0)
        var header = "Window \(windowID) \"\(clean(title, 80))\" of \(appName) (pid \(pid)), \(Int(windowFrame.width))x\(Int(windowFrame.height)) points. Coordinates are window-relative points; the screenshot is 1 pixel per point."
        if listed == 0 { header += "\nNo accessible elements found. Use the screenshot and x/y clicks." }
        var footer: [String] = []
        if truncated { footer.append("(more elements not listed; raise max_elements or scroll)") }
        if skippedOffscreen > 0 { footer.append("(\(skippedOffscreen) elements scrolled out of view not listed)") }
        let text = ([header] + lines + footer).joined(separator: "\n")
        return AXSnapshotResult(windowID: windowID, nodes: nodes, text: text, visited: visited)
    }
}
