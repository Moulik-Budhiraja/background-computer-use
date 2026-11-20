import AppKit
import ApplicationServices
import CPrivate

/// Small typed layer over the Accessibility C API.
public enum AX {
    public static func app(_ pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 1.5)
        return el
    }

    public static func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(el, name as CFString, &value)
        return err == .success ? value : nil
    }

    public static func string(_ el: AXUIElement, _ name: String) -> String? {
        guard let v = attr(el, name) else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    public static func bool(_ el: AXUIElement, _ name: String) -> Bool? {
        (attr(el, name) as? NSNumber)?.boolValue
    }

    public static func double(_ el: AXUIElement, _ name: String) -> Double? {
        (attr(el, name) as? NSNumber)?.doubleValue
    }

    public static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attr(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(v, to: AXUIElement.self)
    }

    public static func elements(_ el: AXUIElement, _ name: String) -> [AXUIElement] {
        guard let v = attr(el, name) as? [AnyObject] else { return [] }
        return v.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? unsafeBitCast(item, to: AXUIElement.self) : nil
        }
    }

    public static func children(_ el: AXUIElement) -> [AXUIElement] {
        elements(el, "AXChildren")
    }

    private static func axValue(_ v: AnyObject?) -> AXValue? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(v, to: AXValue.self)
    }

    public static func position(_ el: AXUIElement) -> CGPoint? {
        guard let v = axValue(attr(el, "AXPosition")) else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v, .cgPoint, &p) ? p : nil
    }

    public static func size(_ el: AXUIElement) -> CGSize? {
        guard let v = axValue(attr(el, "AXSize")) else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v, .cgSize, &s) ? s : nil
    }

    public static func range(_ el: AXUIElement, _ name: String) -> CFRange? {
        guard let v = axValue(attr(el, name)) else { return nil }
        var r = CFRange()
        return AXValueGetValue(v, .cfRange, &r) ? r : nil
    }

    public static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = position(el), let s = size(el) else { return nil }
        return CGRect(origin: p, size: s)
    }

    @discardableResult
    public static func set(_ el: AXUIElement, _ name: String, _ value: AnyObject) -> AXError {
        AXUIElementSetAttributeValue(el, name as CFString, value)
    }

    @discardableResult
    public static func setPosition(_ el: AXUIElement, _ point: CGPoint) -> Bool {
        var p = point
        guard let v = AXValueCreate(.cgPoint, &p) else { return false }
        return set(el, "AXPosition", v) == .success
    }

    @discardableResult
    public static func setSize(_ el: AXUIElement, _ size: CGSize) -> Bool {
        var s = size
        guard let v = AXValueCreate(.cgSize, &s) else { return false }
        return set(el, "AXSize", v) == .success
    }

    /// What a plain click on `el` in a sheet (a file picker, a save panel)
    /// would select, when selecting it is all the click would do: a row of
    /// a native table or outline, or an item of a native list (a picker's
    /// column), reached from `el` or passive content of it (a cell, its
    /// label or icon, a file name). A sheet's window can't be made key from
    /// outside the app while it's up, so a click there can't land; selecting
    /// through accessibility needs no key focus.
    ///
    /// Nil outside a sheet, where a real click also moves keyboard focus to
    /// the list, which later keys rely on. Nil for a control in a row (a
    /// checkbox, a button), which a click operates rather than selects, and
    /// in web content, where clicking a row usually does more than select it.
    public static func selectable(_ el: AXUIElement) -> Selectable? {
        // Web content, or a sheet, above it?
        var inSheet = false
        var up = element(el, "AXParent")
        for _ in 0..<60 {
            guard let p = up else { break }
            let role = string(p, "AXRole")
            if role == "AXWebArea" { return nil }
            if role == "AXSheet" { inSheet = true }
            up = element(p, "AXParent")
        }
        guard inSheet else { return nil }
        var node = el
        for _ in 0..<4 {
            let role = string(node, "AXRole") ?? ""
            if role == "AXRow" {
                return isSettable(node, "AXSelected") ? .row(node) : nil
            }
            guard passiveContent.contains(role), let parent = element(node, "AXParent") else { return nil }
            if string(parent, "AXRole") == "AXList", isSettable(parent, "AXSelectedChildren") {
                return .item(node, list: parent, name: name(of: node))
            }
            node = parent
        }
        return nil
    }

    public enum Selectable {
        case row(AXUIElement)
        /// `name`: the item's text (a file name), to find it again (a
        /// picker's column redraws as it selects).
        case item(AXUIElement, list: AXUIElement, name: String?)
    }

    /// An item's text, from it or the content in it (a file name next to an
    /// icon), to find it again after its list redraws.
    private static func name(of item: AXUIElement) -> String? {
        var queue = [item]
        for _ in 0..<12 {
            guard !queue.isEmpty else { break }
            let el = queue.removeFirst()
            let role = string(el, "AXRole")
            let value = role == "AXTextField" || role == "AXStaticText" ? string(el, "AXValue") : nil
            if let text = value ?? string(el, "AXTitle"), !text.isEmpty { return text }
            queue.append(contentsOf: children(el))
        }
        return nil
    }

    /// What a click on a row's or a list item's content only selects it through.
    private static let passiveContent: Set<String> = ["AXCell", "AXStaticText", "AXTextField", "AXImage", "AXGroup"]

    /// Selects `s` and nothing else in its list, the way a plain click does:
    /// in a list that allows several (a picker that takes many files), adding
    /// one to the selection would keep the others.
    public static func selectOnly(_ s: Selectable) -> AXError {
        let err: AXError
        switch s {
        case .item(let item, let list, _):
            err = set(list, "AXSelectedChildren", [item] as CFArray)
        case .row(let row):
            let list = element(row, "AXParent")
            if let list, isSettable(list, "AXSelectedRows"),
               set(list, "AXSelectedRows", [row] as CFArray) == .success, bool(row, "AXSelected") == true {
                return .success
            }
            let e = set(row, "AXSelected", kCFBooleanTrue)
            if e == .success, let list {
                for other in elements(list, "AXSelectedRows") where !CFEqual(other, row) {
                    set(other, "AXSelected", kCFBooleanFalse)
                }
            }
            err = e
        }
        // A file picker's list (drawn by another process) can report a
        // failure although the file got selected: "unsupported" when nothing
        // was selected before, or a timeout while it shows the file. Look
        // before calling it a failure.
        guard err != .success else { return err }
        let deadline = Date().addingTimeInterval(3)
        repeat {
            if isSelected(s) { return .success }
            usleep(100_000)
        } while Date() < deadline
        return err
    }

    /// Whether `s` is selected now. A picker's column redraws as it selects,
    /// so an item is also found by the text clicked on, in it or its children.
    private static func isSelected(_ s: Selectable) -> Bool {
        switch s {
        case .row(let row):
            return bool(row, "AXSelected") == true
        case .item(let item, let list, let name):
            func says(_ el: AXUIElement) -> Bool { name != nil && self.name(of: el) == name }
            return elements(list, "AXSelectedChildren").contains { CFEqual($0, item) || says($0) }
        }
    }

    public static func isSettable(_ el: AXUIElement, _ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(el, name as CFString, &settable) == .success && settable.boolValue
    }

    @discardableResult
    public static func perform(_ el: AXUIElement, _ action: String) -> AXError {
        AXUIElementPerformAction(el, action as CFString)
    }

    /// Whether the element is still there: .success, or the error reading
    /// its role (.invalidUIElement once it's gone).
    public static func liveness(_ el: AXUIElement) -> AXError {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(el, "AXRole" as CFString, &v)
    }

    public static func actions(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success, let list = names as? [String] else { return [] }
        return list
    }

    public static func windowID(_ el: AXUIElement) -> CGWindowID? {
        var id: UInt32 = 0
        return BCUAXGetWindowID(el, &id) ? id : nil
    }

    /// The app's element under a global point.
    public static func element(at point: CGPoint, pid: pid_t) -> AXUIElement? {
        var el: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(app(pid), Float(point.x), Float(point.y), &el)
        return err == .success ? el : nil
    }

    public static func windows(_ pid: pid_t) -> [AXUIElement] {
        elements(app(pid), "AXWindows")
    }

    public static func window(pid: pid_t, id: CGWindowID) -> AXUIElement? {
        windows(pid).first { windowID($0) == id }
    }

    /// The sheet over `window` (a file picker, a save panel, an alert), if one is up.
    public static func sheet(of window: AXUIElement) -> AXUIElement? {
        children(window).first { string($0, "AXRole") == "AXSheet" }
    }

    /// The window id of the sheet over window `id` of `pid`. A sheet is a
    /// window of its own, and while it's up it, not the window it's over,
    /// is the one that can be key.
    public static func sheetWindowID(pid: pid_t, window id: CGWindowID) -> CGWindowID? {
        guard let w = window(pid: pid, id: id), let s = sheet(of: w), let sid = windowID(s), sid != id else { return nil }
        return sid
    }

    /// The app's key window as accessibility reports it.
    public static func focusedWindowID(_ pid: pid_t) -> CGWindowID? {
        guard let w = element(app(pid), "AXFocusedWindow") else { return nil }
        return windowID(w)
    }

    /// The window holding the app's focused element.
    public static func focusedElementWindowID(_ pid: pid_t) -> CGWindowID? {
        guard let el = element(app(pid), "AXFocusedUIElement") else { return nil }
        if let w = element(el, "AXWindow") { return windowID(w) }
        return nil
    }

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    public static func errorName(_ e: AXError) -> String {
        switch e {
        case .success: return "success"
        case .failure: return "failure"
        case .illegalArgument: return "illegal argument"
        case .invalidUIElement: return "element no longer exists"
        case .cannotComplete: return "cannot complete (app busy or not responding)"
        case .attributeUnsupported: return "attribute unsupported"
        case .actionUnsupported: return "action unsupported"
        case .notImplemented: return "not implemented"
        case .apiDisabled: return "accessibility permission missing"
        default: return "AX error \(e.rawValue)"
        }
    }
}
