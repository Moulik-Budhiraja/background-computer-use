import AppKit
import CoreGraphics
import CPrivate

/// Background input posted to one process. Nothing here moves the real
/// cursor, activates the app or goes through the global HID stream.
///
/// The event recipes follow trycua/cua's cua-driver (MIT):
/// - mouse events carry the target pid (field 40), the window id (51, 91, 92),
///   the point inside that window and the time they were posted, and are
///   preceded by a mouseMoved and an off-screen primer click;
/// - keyboard events carry SkyLight's authentication message, except menu
///   shortcuts, which only reach NSMenu without it.
public enum Input {
    public enum Button { case left, right }

    private static func source() -> CGEventSource? {
        CGEventSource(stateID: .hidSystemState)
    }

    /// Where a window is in global points, to turn a global point into one
    /// inside the window. Nil when the window is gone.
    static func origin(of windowID: CGWindowID) -> CGPoint? {
        WindowList.info(windowID)?.bounds.origin
    }

    /// Stamp a mouse event for one window of one process.
    ///
    /// The event carries the point inside the window (top-left origin;
    /// `origin` is the window's top left in global points). That's where the
    /// app takes the event to be: on macOS 26 and later the window server
    /// passes it on as given, so a global point there lands outside the
    /// window and no view gets the click.
    ///
    /// The timestamp is the time now, as on a real event: a posted mouse
    /// down or up keeps the one it's given, and apps that order input by
    /// time drop a click from long ago. It's also event field 58, so nothing
    /// else may be put there.
    static func stampMouse(_ e: CGEvent, pid: pid_t, windowID: CGWindowID, phase: Int64, clickState: Int64, button: Int64,
                           at point: CGPoint, origin: CGPoint) {
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
        BCUEventSetWindowLocation(e, CGPoint(x: point.x - origin.x, y: point.y - origin.y))
        e.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        e.flags = []
    }

    /// Click at a global screen point inside `windowID`. `check` runs before
    /// anything is posted and again right before the button goes down.
    /// `origin`: the window's top left, for a window the window list
    /// doesn't give (a panel service's, drawn into a sheet).
    public static func click(pid: pid_t, windowID: CGWindowID, at point: CGPoint, button: Button = .left, count: Int = 1,
                             origin known: CGPoint? = nil, check: () throws -> Void = {}) throws {
        try check()
        guard let src = source() else { throw ToolError("could not create an event source") }
        guard let origin = known ?? origin(of: windowID) else { throw ToolError("window \(windowID) is gone") }
        let offScreen = CGPoint(x: -1, y: -1)
        let (downType, upType, cgButton, buttonNumber): (CGEventType, CGEventType, CGMouseButton, Int64) =
            button == .left ? (.leftMouseDown, .leftMouseUp, .left, 0) : (.rightMouseDown, .rightMouseUp, .right, 1)

        func post(_ type: CGEventType, _ at: CGPoint, phase: Int64, state: Int64, btn: Int64, mouseButton: CGMouseButton) {
            guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: at, mouseButton: mouseButton) else { return }
            stampMouse(e, pid: pid, windowID: windowID, phase: phase, clickState: state, button: btn, at: at, origin: origin)
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
        try check()
        let pairs = max(1, min(count, 3))
        for i in 1...pairs {
            post(downType, point, phase: 3, state: Int64(i), btn: buttonNumber, mouseButton: cgButton)
            sleepMs(1)
            post(upType, point, phase: 3, state: Int64(i), btn: buttonNumber, mouseButton: cgButton)
            if i < pairs { sleepMs(80) }
        }
    }

    /// The most wheel notches one scroll posts on each axis (30 ms each).
    public static let maxScrollNotches = 100

    /// Scroll wheel at a global point, in wheel notches of 3 lines each, at
    /// most `maxScrollNotches` on each axis. Positive dy scrolls content down
    /// (towards the end).
    public static func scroll(pid: pid_t, windowID: CGWindowID, at point: CGPoint, dx: Int, dy: Int, origin known: CGPoint? = nil) throws {
        let dx = max(-maxScrollNotches, min(dx, maxScrollNotches))
        let dy = max(-maxScrollNotches, min(dy, maxScrollNotches))
        guard let src = source() else { throw ToolError("could not create an event source") }
        guard let origin = known ?? origin(of: windowID) else { throw ToolError("window \(windowID) is gone") }
        if let move = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            stampMouse(move, pid: pid, windowID: windowID, phase: 2, clickState: 0, button: 0, at: point, origin: origin)
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
            // Chromium ignores wheel events that don't carry the point inside the target window.
            BCUEventSetWindowLocation(e, CGPoint(x: point.x - origin.x, y: point.y - origin.y))
            BCUPostEventToPid(pid, e, false)
            sleepMs(30)
        }
    }

    /// Press, move in steps, release.
    public static func drag(pid: pid_t, windowID: CGWindowID, from: CGPoint, to: CGPoint, steps: Int = 20, durationMs: Double = 300,
                            origin known: CGPoint? = nil) throws {
        guard let src = source() else { throw ToolError("could not create an event source") }
        guard let origin = known ?? origin(of: windowID) else { throw ToolError("window \(windowID) is gone") }
        func post(_ type: CGEventType, _ at: CGPoint, phase: Int64, state: Int64) {
            guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: at, mouseButton: .left) else { return }
            stampMouse(e, pid: pid, windowID: windowID, phase: phase, clickState: state, button: 0, at: at, origin: origin)
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
    /// Name the window a key event is for, as mouse events do: without it
    /// the window server fills in the window it thinks has keyboard focus
    /// in the app, which can still be the user's while ours is key.
    static func stampKey(_ e: CGEvent, windowID: CGWindowID) {
        guard windowID != 0 else { return }
        BCUEventSetIntegerField(e, 51, Int64(windowID))
        BCUEventSetIntegerField(e, 91, Int64(windowID))
        BCUEventSetIntegerField(e, 92, Int64(windowID))
    }

    /// `shortcutsToMenu`: false for a process with no menu bar of its own
    /// (an open or save panel's), where a shortcut is an ordinary key.
    public static func pressKey(pid: pid_t, key: String, modifiers: [String], windowID: CGWindowID = 0, shortcutsToMenu: Bool = true) throws {
        let (code, flags) = try KeyMap.press(key: key, modifiers: modifiers)
        let menuRoute = shortcutsToMenu && (flags.contains(.maskCommand) || flags.contains(.maskControl))
        try postKey(pid: pid, code: code, down: true, flags: flags, auth: !menuRoute, windowID: windowID)
        sleepMs(keyGapMs)
        try postKey(pid: pid, code: code, down: false, flags: flags, auth: !menuRoute, windowID: windowID)
    }

    public static func postKey(pid: pid_t, code: CGKeyCode, down: Bool, flags: CGEventFlags, auth: Bool, windowID: CGWindowID = 0) throws {
        guard let src = source(), let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else {
            throw ToolError("could not create a keyboard event")
        }
        // Always overwrite flags so the user's physically held modifiers can't leak in.
        e.flags = flags
        stampKey(e, windowID: windowID)
        BCUPostEventToPid(pid, e, auth)
    }

    /// A line break that types as Return. "\r\n" is one Character in Swift.
    public static func isReturn(_ ch: Character) -> Bool {
        ch == "\n" || ch == "\r" || ch == "\r\n"
    }

    /// Type text as Unicode payloads on key code 0; newline and tab become
    /// real keys. `before(i)` runs before character `i`: it throws to stop
    /// (nothing more is posted) or returns false to end early. Returns how
    /// many characters were typed.
    @discardableResult
    public static func typeText(pid: pid_t, _ text: String, windowID: CGWindowID = 0, before: (Int) throws -> Bool = { _ in true }) throws -> Int {
        guard let src = source() else { throw ToolError("could not create an event source") }
        var typed = 0
        for ch in text {
            guard try before(typed) else { return typed }
            defer { typed += 1 }
            if isReturn(ch) {
                try pressKey(pid: pid, key: "return", modifiers: [], windowID: windowID)
                sleepMs(keyGapMs)
                continue
            }
            if ch == "\t" {
                try pressKey(pid: pid, key: "tab", modifiers: [], windowID: windowID)
                sleepMs(keyGapMs)
                continue
            }
            let utf16 = Array(String(ch).utf16)
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
                e.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                e.flags = []
                stampKey(e, windowID: windowID)
                BCUPostEventToPid(pid, e, true)
                sleepMs(keyGapMs)
            }
        }
        return typed
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

    /// The key code and flags press_key sends. An unknown modifier throws
    /// rather than leaving it out and pressing the bare key. A shifted
    /// character ("?", "A") adds Shift on its own, except that with other
    /// modifiers a letter's case doesn't matter: cmd+"A" is Cmd+A, and
    /// Cmd+Shift+A needs "shift" in the list.
    public static func press(key: String, modifiers: [String]) throws -> (CGKeyCode, CGEventFlags) {
        let (code, implicitShift) = try code(for: key)
        var flags = try modifierFlags(modifiers)
        let letter = key.count == 1 && key.first!.isLetter
        if implicitShift && !(letter && !flags.isEmpty) { flags.insert(.maskShift) }
        return (code, flags)
    }

    static let modifierNames: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "meta": .maskCommand, "super": .maskCommand, "⌘": .maskCommand,
        "shift": .maskShift, "⇧": .maskShift,
        "option": .maskAlternate, "opt": .maskAlternate, "alt": .maskAlternate, "⌥": .maskAlternate,
        "ctrl": .maskControl, "control": .maskControl, "⌃": .maskControl,
        "fn": .maskSecondaryFn,
    ]

    /// Modifier names to flags; throws on a name it doesn't know.
    public static func modifierFlags(_ modifiers: [String]) throws -> CGEventFlags {
        var f: CGEventFlags = []
        for m in modifiers {
            guard let flag = modifierNames[m.trimmingCharacters(in: .whitespaces).lowercased()] else {
                throw ToolError("unknown modifier \"\(m)\". Use any of: cmd, shift, option, ctrl, fn. Nothing was pressed.")
            }
            f.insert(flag)
        }
        return f
    }

    /// Modifier names to flags, leaving out names it doesn't know.
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
