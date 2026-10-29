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
