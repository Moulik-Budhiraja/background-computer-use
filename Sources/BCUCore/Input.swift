import AppKit
import CoreGraphics
import CPrivate

/// Background input posted to one process. Nothing here moves the real
/// cursor, activates the app or goes through the global HID stream.
///
/// The event recipes follow trycua/cua's cua-driver (MIT):
/// - mouse events carry the target pid (field 40) and window id (51, 91, 92)
///   and are preceded by a mouseMoved and an off-screen primer click;
/// - keyboard events carry SkyLight's authentication message, except menu
///   shortcuts, which only reach NSMenu without it.
public enum Input {
    public enum Button { case left, right }

    private static func source() -> CGEventSource? {
        CGEventSource(stateID: .hidSystemState)
    }

    private static func stampMouse(_ e: CGEvent, pid: pid_t, windowID: CGWindowID, phase: Int64, clickState: Int64, button: Int64, group: Int64, location: CGPoint) {
        BCUEventSetIntegerField(e, 0, phase)        // gesture phase
        BCUEventSetIntegerField(e, 1, clickState)   // kCGMouseEventClickState
        BCUEventSetIntegerField(e, 3, button)       // kCGMouseEventButtonNumber
        BCUEventSetIntegerField(e, 7, 3)            // NSEventSubtypeTouch
        BCUEventSetIntegerField(e, 40, Int64(pid))  // target pid
        if windowID != 0 {
            BCUEventSetIntegerField(e, 51, Int64(windowID))  // windowNumber
            BCUEventSetIntegerField(e, 91, Int64(windowID))  // window under pointer
            BCUEventSetIntegerField(e, 92, Int64(windowID))  // window that can handle it
        }
        BCUEventSetIntegerField(e, 58, group)       // click group
        BCUEventSetWindowLocation(e, location)
        e.flags = []
    }

    /// Click at a global screen point inside `windowID`.
    public static func click(pid: pid_t, windowID: CGWindowID, at point: CGPoint, button: Button = .left, count: Int = 1) throws {
        guard let src = source() else { throw ToolError("could not create an event source") }
        let group = Int64(DispatchTime.now().uptimeNanoseconds & 0x7fff_ffff)
        let offScreen = CGPoint(x: -1, y: -1)
        let (downType, upType, cgButton, buttonNumber): (CGEventType, CGEventType, CGMouseButton, Int64) =
            button == .left ? (.leftMouseDown, .leftMouseUp, .left, 0) : (.rightMouseDown, .rightMouseUp, .right, 1)

        func post(_ type: CGEventType, _ at: CGPoint, phase: Int64, state: Int64, btn: Int64, mouseButton: CGMouseButton) {
            guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: at, mouseButton: mouseButton) else { return }
            stampMouse(e, pid: pid, windowID: windowID, phase: phase, clickState: state, button: btn, group: group, location: at)
            BCUPostEventToPid(pid, e, false)
        }

        // Without a move first, AppKit ignores a synthetic mouseDown on a background control.
        post(.mouseMoved, point, phase: 2, state: 0, btn: 0, mouseButton: .left)
        sleepMs(15)
        // Off-screen primer pair: opens Chromium's user-activation gate; harmless elsewhere.
        post(.leftMouseDown, offScreen, phase: 1, state: 1, btn: 0, mouseButton: .left)
        sleepMs(1)
        post(.leftMouseUp, offScreen, phase: 2, state: 1, btn: 0, mouseButton: .left)
        sleepMs(100)
        let pairs = max(1, min(count, 3))
        for i in 1...pairs {
            post(downType, point, phase: 3, state: Int64(i), btn: buttonNumber, mouseButton: cgButton)
            sleepMs(1)
            post(upType, point, phase: 3, state: Int64(i), btn: buttonNumber, mouseButton: cgButton)
            if i < pairs { sleepMs(80) }
        }
    }

    /// Scroll wheel at a global point. Positive dy scrolls content down (towards the end).
    public static func scroll(pid: pid_t, windowID: CGWindowID, at point: CGPoint, dx: Int, dy: Int) throws {
        guard let src = source() else { throw ToolError("could not create an event source") }
        if let move = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            stampMouse(move, pid: pid, windowID: windowID, phase: 2, clickState: 0, button: 0, group: 0, location: point)
            BCUPostEventToPid(pid, move, false)
        }
        sleepMs(15)
        let steps = max(abs(dx), abs(dy))
        for i in 0..<steps {
            let vy: Int32 = i < abs(dy) ? (dy > 0 ? -1 : 1) : 0
            let vx: Int32 = i < abs(dx) ? (dx > 0 ? -1 : 1) : 0
            guard let e = CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 2, wheel1: vy * 3, wheel2: vx * 3, wheel3: 0) else { continue }
            e.location = point
            BCUEventSetIntegerField(e, 40, Int64(pid))
            if windowID != 0 {
                BCUEventSetIntegerField(e, 51, Int64(windowID))
                BCUEventSetIntegerField(e, 91, Int64(windowID))
                BCUEventSetIntegerField(e, 92, Int64(windowID))
            }
            BCUPostEventToPid(pid, e, false)
            e.postToPid(pid)
            sleepMs(30)
        }
    }

    /// Press, move in steps, release.
    public static func drag(pid: pid_t, windowID: CGWindowID, from: CGPoint, to: CGPoint, steps: Int = 20, durationMs: Double = 300) throws {
        guard let src = source() else { throw ToolError("could not create an event source") }
        let group = Int64(DispatchTime.now().uptimeNanoseconds & 0x7fff_ffff)
        func post(_ type: CGEventType, _ at: CGPoint, phase: Int64, state: Int64) {
            guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: at, mouseButton: .left) else { return }
            stampMouse(e, pid: pid, windowID: windowID, phase: phase, clickState: state, button: 0, group: group, location: at)
            BCUPostEventToPid(pid, e, false)
        }
        post(.mouseMoved, from, phase: 2, state: 0)
        sleepMs(15)
        post(.leftMouseDown, from, phase: 3, state: 1)
        sleepMs(50)
        let n = max(2, steps)
        for i in 1...n {
            let t = CGFloat(i) / CGFloat(n)
            let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            post(.leftMouseDragged, p, phase: 3, state: 1)
            sleepMs(durationMs / Double(n))
        }
        post(.leftMouseUp, to, phase: 3, state: 1)
    }

    // MARK: Keyboard

    private static let keyGapMs: Double = 8

    /// Press and release one key with modifiers. Shortcuts with cmd or ctrl go
    /// without the authentication message so menu key equivalents fire.
    public static func pressKey(pid: pid_t, key: String, modifiers: [String]) throws {
        let (code, implicitShift) = try KeyMap.code(for: key)
        var flags = KeyMap.flags(modifiers)
        if implicitShift { flags.insert(.maskShift) }
        let menuRoute = flags.contains(.maskCommand) || flags.contains(.maskControl)
        try postKey(pid: pid, code: code, down: true, flags: flags, auth: !menuRoute)
        sleepMs(keyGapMs)
        try postKey(pid: pid, code: code, down: false, flags: flags, auth: !menuRoute)
    }

    public static func postKey(pid: pid_t, code: CGKeyCode, down: Bool, flags: CGEventFlags, auth: Bool) throws {
        guard let src = source(), let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else {
            throw ToolError("could not create a keyboard event")
        }
        // Always overwrite flags so the user's physically held modifiers can't leak in.
        e.flags = flags
        BCUPostEventToPid(pid, e, auth)
    }

    /// Type text as Unicode payloads on key code 0; newline and tab become real keys.
    public static func typeText(pid: pid_t, _ text: String) throws {
        guard let src = source() else { throw ToolError("could not create an event source") }
        for ch in text {
            if ch == "\n" || ch == "\r" {
                try pressKey(pid: pid, key: "return", modifiers: [])
                sleepMs(keyGapMs)
                continue
            }
            if ch == "\t" {
                try pressKey(pid: pid, key: "tab", modifiers: [])
                sleepMs(keyGapMs)
                continue
            }
            let utf16 = Array(String(ch).utf16)
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
                e.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                e.flags = []
                BCUPostEventToPid(pid, e, true)
                sleepMs(keyGapMs)
            }
        }
    }
}

/// US-layout key codes.
public enum KeyMap {
    static let named: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53, "forwarddelete": 117, "home": 115, "end": 119,
        "pageup": 116, "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f19": 80, "help": 114, "keypadenter": 76,
    ]

    static let chars: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "`": 50,
    ]

    static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
        "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";",
        "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    public static func code(for key: String) throws -> (CGKeyCode, Bool) {
        let folded = key.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
        if key.count > 1, let c = named[folded] { return (c, false) }
        if key.count == 1, let ch = key.first {
            if let c = chars[Character(ch.lowercased())] { return (c, ch.isUppercase) }
            if let base = shifted[ch], let c = chars[base] { return (c, true) }
            if ch == " " { return (49, false) }
        }
        if let c = named[folded] { return (c, false) }
        throw ToolError("unknown key \"\(key)\". Use a letter, digit, punctuation, or one of: \(named.keys.sorted().joined(separator: ", "))")
    }

    public static func flags(_ modifiers: [String]) -> CGEventFlags {
        var f: CGEventFlags = []
        for m in modifiers {
            switch m.lowercased() {
            case "cmd", "command", "meta", "super": f.insert(.maskCommand)
            case "shift": f.insert(.maskShift)
            case "option", "opt", "alt": f.insert(.maskAlternate)
            case "ctrl", "control": f.insert(.maskControl)
            case "fn": f.insert(.maskSecondaryFn)
            default: break
            }
        }
        return f
    }
}
