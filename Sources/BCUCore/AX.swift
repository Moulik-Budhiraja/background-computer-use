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

    /// The row a click on `el` would select, when selecting it is all the
    /// click would do: `el` is a row of a native list, table or outline, or
    /// passive content of one (a cell, its label or icon), and accessibility
    /// can set the row's selection. Selecting it that way needs no key focus,
    /// which matters in a sheet: its window can't be made key from outside the
    /// app while it's up. Nil for a control in a row (a checkbox, a button, a
    /// field the user can edit), which a click operates rather than selects,
    /// and nil in web content, where clicking a row usually does more than
    /// select it (opens an email, follows a link).
    public static func selectableRow(_ el: AXUIElement) -> AXUIElement? {
        var row: AXUIElement? = el
        // Up from a cell, or from a label or image in a cell.
        for _ in 0..<3 {
            guard let r = row else { break }
            let role = string(r, "AXRole") ?? ""
            if role == "AXRow" { break }
            guard passiveRowContent.contains(role), role != "AXTextField" || !isSettable(r, "AXValue") else { return nil }
            row = element(r, "AXParent")
        }
        guard let row, string(row, "AXRole") == "AXRow", isSettable(row, "AXSelected") else { return nil }
        var up = element(row, "AXParent")
        for _ in 0..<60 {
            guard let p = up else { break }
            if string(p, "AXRole") == "AXWebArea" { return nil }
            up = element(p, "AXParent")
        }
        return row
    }

    /// What a click on a row's content only selects the row through. A text
    /// field counts only when it can't be edited (a file name in a list).
    private static let passiveRowContent: Set<String> = ["AXCell", "AXStaticText", "AXTextField", "AXImage", "AXGroup"]

    /// Selects `row` and nothing else in its list, the way a plain click does:
    /// in a list that allows several (a picker that takes many files), setting
    /// one row's selection would add to it instead.
    public static func selectOnly(_ row: AXUIElement) -> AXError {
        let list = element(row, "AXParent")
        if let list, isSettable(list, "AXSelectedRows"),
           set(list, "AXSelectedRows", [row] as CFArray) == .success, bool(row, "AXSelected") == true {
            return .success
        }
        let err = set(row, "AXSelected", kCFBooleanTrue)
        guard err == .success, let list else { return err }
        for other in elements(list, "AXSelectedRows") where !CFEqual(other, row) {
            set(other, "AXSelected", kCFBooleanFalse)
        }
        return .success
    }

    public static func isSettable(_ el: AXUIElement, _ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(el, name as CFString, &settable) == .success && settable.boolValue
    }

    @discardableResult
    public static func perform(_ el: AXUIElement, _ action: String) -> AXError {
        AXUIElementPerformAction(el, action as CFString)
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
