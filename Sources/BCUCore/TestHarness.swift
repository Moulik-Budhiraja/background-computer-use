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

    func startTyping(_ text: String, intervalMs: Double) -> ToolResult {
        lock.lock()
        if running { lock.unlock(); return .error("already typing") }
        running = true
        typed = 0
        total = text.count
        lock.unlock()
        let thread = Thread { [weak self] in
            let src = CGEventSource(stateID: .hidSystemState)
            for ch in text {
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
    static func read(app: String, windows: WindowManager) throws -> ToolResult {
        guard let running = try windows.resolveApp(app).running else { throw ToolError("\(app) isn't running") }
        let appEl = AX.app(running.processIdentifier)
        guard let win = AX.element(appEl, "AXFocusedWindow") ?? AX.windows(running.processIdentifier).first else {
            throw ToolError("no window")
        }
        func find(_ el: AXUIElement, _ depth: Int) -> AXUIElement? {
            if depth > 12 { return nil }
            let role = AX.string(el, "AXRole") ?? ""
            if role == "AXTextArea" || role == "AXTextField" { return el }
            for c in AX.children(el) { if let f = find(c, depth + 1) { return f } }
            return nil
        }
        guard let area = find(win, 0) else { throw ToolError("no text area") }
        return ToolResult(text: AX.string(area, "AXValue") ?? "")
    }
}
