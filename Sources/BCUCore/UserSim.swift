import AppKit
import BCUShared
import CPrivate

/// Test only (`admin_user_sim`): plays a scripted user through the global
/// HID stream (typing with keys held like a person's, clicks, double clicks,
/// trackpad scrolls with momentum, opening a menu bar menu) and keeps a
/// timeline of it next to the agent's key-focus covers and waits, so a test
/// can check that the agent's swaps only land when the user pauses.
final class UserSim {
    static let shared = UserSim()

    private let lock = NSLock()
    private var running = false
    private var stopping = false
    /// Only ever post input while this app is in front.
    private var onlyPid: pid_t = 0
    /// Or one of these (test fixtures the user switches between).
    private var alsoPids: Set<pid_t> = []
    /// Held while posting one event, so `Chaos` can switch apps between
    /// events and never under one.
    let postLock = NSLock()
    /// And, if set, only while this window is that app's key window.
    private var onlyWindow: CGWindowID = 0
    /// And, if set, only while that window's title contains this (a
    /// browser tab the test owns, not one something else opened).
    private var onlyTitle: String?
    private var epoch = 0.0
    private var timeline: [(t: Double, what: String)] = []
    private var covers: [(from: Double, to: Double, causes: [String])] = []
    private var openCover: (from: Double, causes: [String])?
    private var waits: [(from: Double, to: Double, note: String)] = []

    private func t() -> Double { nowMs() - epoch }

    private func note(_ s: String) {
        lock.lock(); timeline.append((t(), s)); lock.unlock()
    }

    // MARK: Agent side, called by the engine

    func coverOpened(_ cause: String) {
        lock.lock(); if epoch > 0 { openCover = (t(), [cause]) }; lock.unlock()
    }

    func coverUsed(_ cause: String) {
        lock.lock(); openCover?.causes.append(cause); lock.unlock()
    }

    func coverClosed() {
        lock.lock()
        if let c = openCover { covers.append((c.from, t(), c.causes)) }
        openCover = nil
        lock.unlock()
    }

    func waited(fromMs: Double, _ note: String) {
        lock.lock(); if epoch > 0 { waits.append((fromMs - epoch, t(), note)) }; lock.unlock()
    }

    // MARK: Script

    func start(_ script: [JSONObject], pid: pid_t, window: CGWindowID = 0, title: String? = nil, also: [pid_t] = []) -> ToolResult {
        lock.lock()
        if running { lock.unlock(); return .error("already running") }
        onlyPid = pid
        alsoPids = Set(also)
        onlyWindow = window
        onlyTitle = title
        running = true
        stopping = false
        epoch = nowMs()
        timeline = []; covers = []; waits = []; openCover = nil
        lock.unlock()
        let thread = Thread { [weak self] in
            guard let self else { return }
            self.run(script)
            self.note("end")
            self.lock.lock(); self.running = false; self.lock.unlock()
        }
        thread.qualityOfService = .userInteractive
        thread.start()
        return ToolResult(text: "started")
    }

    func stop() -> ToolResult {
        lock.lock(); stopping = true; lock.unlock()
        return ToolResult(text: "stopping")
    }

    /// Stop when asked, or the moment another app is in front, so input
    /// never reaches anything but the test's app.
    private var shouldStop: Bool {
        lock.lock(); let stop = stopping; let pid = onlyPid; let window = onlyWindow; let title = onlyTitle; let also = alsoPids; lock.unlock()
        if stop { return true }
        var front = BCUFrontProcessPID()
        // Chaos put this app in front for a moment: wait for it to end.
        let waitUntil = nowMs() + 3000
        while front == getpid() && Chaos.shared.flipping && nowMs() < waitUntil { sleepMs(5); front = BCUFrontProcessPID() }
        if also.contains(front) { return false }
        var why: String?
        if front != pid {
            why = "\(NSRunningApplication(processIdentifier: front)?.localizedName ?? "pid \(front)") is in front"
        } else if window != 0, let key = AX.focusedWindowID(pid), key != window, !FocusGuard.onAgentDisplay(key) {
            // (An agent window is key only during a swap, while input is held.)
            why = "window \(key) is key instead of \(window)"
        } else if window != 0, let title, let w = AX.window(pid: pid, id: window),
                  !(AX.string(w, "AXTitle") ?? "").contains(title) {
            why = "window \(window) shows \"\(AX.string(w, "AXTitle") ?? "")\""
        }
        guard let why else { return false }
        note("stopped: \(why)")
        lock.lock(); stopping = true; lock.unlock()
        return true
    }

    /// Clock for the test: ms since the script started.
    func clock() -> Double { lock.lock(); defer { lock.unlock() }; return epoch > 0 ? t() : 0 }

    func status() -> ToolResult {
        lock.lock(); defer { lock.unlock() }
        var out: [JSONObject] = []
        for e in timeline { out.append(["t": e.t, "what": e.what]) }
        let c = covers.map { ["from": $0.from, "to": $0.to, "causes": $0.causes] as JSONObject }
        let w = waits.map { ["from": $0.from, "to": $0.to, "note": $0.note] as JSONObject }
        let obj: JSONObject = ["running": running, "now": epoch > 0 ? t() : 0, "timeline": out, "covers": c, "waits": w]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [])) ?? Data()
        return ToolResult(text: "sim \(running ? "running" : "done")\n" + (String(data: data, encoding: .utf8) ?? "{}"))
    }

    private let src = CGEventSource(stateID: .hidSystemState)

    private func run(_ ops: [JSONObject]) {
        for op in ops {
            if shouldStop { return }
            let a = Args(op)
            switch a.string("op") ?? "" {
            case "pause":
                sleepMs((a.double("ms") ?? 100) + Double.random(in: 0...max(0, a.double("jitter_ms") ?? 0)))
            case "mark":
                note("mark \(a.string("label") ?? "")")
            case "repeat":
                let inner = (op["ops"] as? [JSONObject]) ?? []
                for _ in 0..<(a.int("times") ?? 1) { run(inner) }
            case "type":
                type(a.string("text") ?? "", intervalMs: a.double("interval_ms") ?? 120, holdMs: a.double("hold_ms") ?? 60,
                     jitterMs: a.double("jitter_ms") ?? 0, wordPauseMs: a.double("word_pause_ms") ?? 0)
            case "key":
                if let (code, _) = try? KeyMap.code(for: a.string("key") ?? "escape") {
                    note("key \(a.string("key") ?? "")")
                    let flags = KeyMap.flags(a.strings("modifiers") ?? [])
                    key(code, down: true, flags: flags); sleepMs(a.double("hold_ms") ?? 60); key(code, down: false, flags: flags)
                }
            case "click":
                click(CGPoint(x: a.double("x") ?? 0, y: a.double("y") ?? 0), count: a.int("count") ?? 1, holdMs: a.double("hold_ms") ?? 70)
            case "scroll":
                scroll(CGPoint(x: a.double("x") ?? 0, y: a.double("y") ?? 0), events: a.int("events") ?? 20,
                       momentum: a.int("momentum") ?? 30, dy: Int32(a.int("dy") ?? 6))
            case "menu":
                openMenu(a.string("title") ?? "Format")
            case "activate":
                // Switch to a test fixture app, the way a click on it would.
                let pid = pid_t(a.int("pid") ?? 0)
                lock.lock(); let ok = pid == onlyPid || alsoPids.contains(pid); lock.unlock()
                guard ok else { note("activate: pid \(pid) isn't allowed"); break }
                note("activate \(pid)")
                // As a click on its window would: the gate opens for the user.
                FocusGuard.shared?.noteUserSwitch()
                _ = BCUSetFrontProcess(pid, CGWindowID(a.int("window_id") ?? 0), 0x200)
                if let wid = a.int("window_id") { _ = BCUPostMakeKeyRecords(pid, CGWindowID(wid)) }
                let deadline = nowMs() + 1000
                while BCUFrontProcessPID() != pid && nowMs() < deadline { sleepMs(5) }
            case "cmd_tab":
                // To the app used before this one (the test sets that up).
                note("cmd_tab")
                let cmd = CGEventFlags.maskCommand
                func post(_ code: CGKeyCode, _ down: Bool, _ flags: CGEventFlags, _ type: CGEventType? = nil) {
                    guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { return }
                    if let type { e.type = type }
                    e.flags = flags
                    postLock.lock(); e.post(tap: .cghidEventTap); postLock.unlock()
                }
                post(55, true, cmd, .flagsChanged); sleepMs(40)
                post(48, true, cmd); sleepMs(50)
                post(48, false, cmd); sleepMs(60)
                post(55, false, [], .flagsChanged)
                sleepMs(a.double("settle_ms") ?? 300)
                note("front \(BCUFrontProcessPID())")
            case "watch_menu":
                watchMenu(ms: a.double("ms") ?? 3000)
            default:
                note("unknown op \(a.string("op") ?? "")")
            }
        }
    }

    private func key(_ code: CGKeyCode, down: Bool, char: String? = nil, flags: CGEventFlags = []) {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { return }
        if let char {
            let u = Array(char.utf16)
            e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
        }
        e.flags = flags
        postLock.lock(); e.post(tap: .cghidEventTap); postLock.unlock()
    }

    /// `jitterMs`: up to this much extra before each key; `wordPauseMs`: up
    /// to this much extra after a space, like a person thinking.
    private func type(_ text: String, intervalMs: Double, holdMs: Double, jitterMs: Double, wordPauseMs: Double) {
        note("type start \(text.count)")
        for ch in text {
            if shouldStop { break }
            note("key down")
            // The key a person would press for it, so the system sees one
            // physical key per character (and shift where it takes one).
            let (code, shift) = (try? KeyMap.code(for: String(ch))) ?? (0, false)
            let flags: CGEventFlags = shift ? .maskShift : []
            key(code, down: true, char: String(ch), flags: flags)
            sleepMs(holdMs)
            key(code, down: false, char: String(ch), flags: flags)
            var gap = max(0, intervalMs - holdMs) + Double.random(in: 0...max(0, jitterMs))
            if ch == " " { gap += Double.random(in: 0...max(0, wordPauseMs)) }
            sleepMs(gap)
        }
        note("type end")
    }

    private func mouse(_ type: CGEventType, _ p: CGPoint, state: Int64) {
        guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: state)
        postLock.lock(); e.post(tap: .cghidEventTap); postLock.unlock()
    }

    private func click(_ p: CGPoint, count: Int, holdMs: Double, menuBar: Bool = false) {
        // Only where the test app's own window is on top.
        let me = getpid()
        let top = WindowList.all(onScreenOnly: true).first { $0.pid != me && $0.layer >= 0 && $0.layer < 20 && $0.alpha > 0 && $0.bounds.contains(p) }
        let allowed = top.map { $0.pid == onlyPid ? (onlyWindow == 0 || $0.id == onlyWindow) : alsoPids.contains($0.pid) } ?? false
        if !menuBar && !allowed {
            note("stopped: \(top?.owner ?? "nothing") is on top at \(Int(p.x)),\(Int(p.y))")
            lock.lock(); stopping = true; lock.unlock()
            return
        }
        mouse(.mouseMoved, p, state: 0)
        sleepMs(20)
        for i in 1...max(1, count) {
            note("mouse down")
            mouse(.leftMouseDown, p, state: Int64(i))
            sleepMs(holdMs)
            mouse(.leftMouseUp, p, state: Int64(i))
            note("mouse up")
            if i < count { sleepMs(90) }
            if shouldStop { return }
        }
    }

    /// A two-finger swipe: began, changed, ended, then momentum that slows down.
    private func scroll(_ p: CGPoint, events: Int, momentum: Int, dy: Int32) {
        mouse(.mouseMoved, p, state: 0)
        func post(_ delta: Int32, phase: Int64, momentum m: Int64) {
            guard let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 1, wheel1: -delta, wheel2: 0, wheel3: 0) else { return }
            e.location = p
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: m)
            e.post(tap: .cghidEventTap)
        }
        note("scroll start")
        post(0, phase: 128, momentum: 0)
        sleepMs(16)
        for i in 0..<events {
            if shouldStop { break }
            post(dy, phase: i == 0 ? 1 : 2, momentum: 0)
            sleepMs(16)
        }
        post(0, phase: 4, momentum: 0)
        note("scroll fingers up")
        sleepMs(16)
        for i in 0..<momentum {
            let d = max(1, Int32(Double(dy) * (1 - Double(i) / Double(momentum))))
            post(d, phase: 0, momentum: i == 0 ? 1 : 2)
            sleepMs(16)
        }
        post(0, phase: 0, momentum: 3)
        note("scroll end")
    }

    /// Click a menu bar title of the front app, which leaves its menu open.
    private func openMenu(_ title: String) {
        let pid = BCUFrontProcessPID()
        guard let bar = AX.element(AX.app(pid), "AXMenuBar"),
              let item = AX.children(bar).first(where: { AX.string($0, "AXTitle") == title }),
              let f = AX.frame(item) else { note("no menu \(title)"); return }
        note("menu click \(title)")
        click(CGPoint(x: f.midX, y: f.midY), count: 1, holdMs: 80, menuBar: true)
    }

    /// Sample whether a menu is open, noting each change.
    private func watchMenu(ms: Double) {
        let end = nowMs() + ms
        var last: Bool?
        while nowMs() < end {
            let open = QuietWait.menuOpen()
            if open != last { note(open ? "menu open" : "menu closed"); last = open }
            sleepMs(15)
        }
    }
}
