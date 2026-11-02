import AppKit
import BCUShared
import CPrivate

/// Maintenance tools for the focus test (not in the agent tool catalog).
/// Simulates the user typing into the front app through the global HID
/// stream, so the guard sees it exactly like real keystrokes.
final class TestHarness {
    static let shared = TestHarness()
    private let lock = NSLock()
    private var typed = 0
    private var total = 0
    private var running = false

    /// Types `text` as real HID keystrokes. With `onlyPid`, stops the moment
    /// another app is in front, so stray keys never reach the user's apps.
    func startTyping(_ text: String, intervalMs: Double, onlyPid: pid_t? = nil) -> ToolResult {
        lock.lock()
        if running { lock.unlock(); return .error("already typing") }
        running = true
        typed = 0
        total = text.count
        lock.unlock()
        let thread = Thread { [weak self] in
            let src = CGEventSource(stateID: .hidSystemState)
            for ch in text {
                if let pid = onlyPid, BCUFrontProcessPID() != pid {
                    Log.info("admin_type_hid: stopped, \(BCUFrontProcessPID()) is in front instead of \(pid)")
                    break
                }
                let utf16 = Array(String(ch).utf16)
                for down in [true, false] {
                    guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
                    e.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                    e.flags = []
                    e.post(tap: .cghidEventTap)
                    usleep(4000)
                }
                self?.lock.lock(); self?.typed += 1; self?.lock.unlock()
                usleep(useconds_t(intervalMs * 1000))
            }
            self?.lock.lock(); self?.running = false; self?.lock.unlock()
        }
        thread.start()
        return ToolResult(text: "typing \(text.count) characters")
    }

    func typingStatus() -> ToolResult {
        lock.lock(); defer { lock.unlock() }
        return ToolResult(text: "\(running ? "typing" : "done") \(typed)/\(total)")
    }

    /// Text of the first text area in an app's focused window.
    /// With `windowID`, that window's instead; `all` lists every text field and area.
    /// `set`: replace the text area's text first (test setup).
    static func read(app: String, windows: WindowManager, windowID: CGWindowID? = nil, all: Bool = false, set: String? = nil) throws -> ToolResult {
        guard let running = try windows.resolveApp(app).running else { throw ToolError("\(app) isn't running") }
        let appEl = AX.app(running.processIdentifier)
        let chosen = windowID.flatMap { AX.window(pid: running.processIdentifier, id: $0) }
        guard let win = chosen ?? AX.element(appEl, "AXFocusedWindow") ?? AX.windows(running.processIdentifier).first else {
            throw ToolError("no window")
        }
        if all {
            var out: [String] = []
            func walk(_ el: AXUIElement, _ depth: Int) {
                if depth > 14 { return }
                let role = AX.string(el, "AXRole") ?? ""
                if role == "AXTextArea" || role == "AXTextField" { out.append("\(role): \(AX.string(el, "AXValue") ?? "")") }
                for c in AX.children(el) { walk(c, depth + 1) }
            }
            walk(win, 0)
            return ToolResult(text: out.joined(separator: "\n"))
        }
        func find(_ el: AXUIElement, _ depth: Int) -> AXUIElement? {
            if depth > 12 { return nil }
            let role = AX.string(el, "AXRole") ?? ""
            if role == "AXTextArea" || role == "AXTextField" { return el }
            for c in AX.children(el) { if let f = find(c, depth + 1) { return f } }
            return nil
        }
        guard let area = find(win, 0) else { throw ToolError("no text area") }
        if let set { _ = AX.set(area, "AXValue", set as CFString); sleepMs(100) }
        return ToolResult(text: AX.string(area, "AXValue") ?? "")
    }
}
