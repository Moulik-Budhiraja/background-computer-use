import AppKit
import CoreAudio
import BCUShared

/// Every agent session. Each MCP connection (`bcu mcp`) names its own
/// session and gets its own display, windows, pause and take-over; calls
/// without a session (`bcu call`) share a default one. One focus guard
/// watches over all of them.
public final class Hub {
    public let focusGuard = FocusGuard()
    /// Main thread: status, activity or sessions changed.
    public var onChange: (() -> Void)?

    public static let defaultSession = "default"
    /// A display with no windows and no calls for this long is removed.
    public static let idleTeardownMs: Double = 60_000

    private let lock = NSLock()
    private var byID: [String: Engine] = [:]
    private var order: [String] = []
    private var timer: Timer?
    private var ticks = 0

    public init() {
        focusGuard.onEvent = { [weak self] _ in self?.changed() }
    }

    public var engines: [Engine] {
        lock.lock(); defer { lock.unlock() }
        return order.compactMap { byID[$0] }
    }

    /// Sessions with something to show: a display, windows, or recent calls.
    public var activeEngines: [Engine] {
        engines.filter { $0.display.isRunning || !$0.windows.windows.isEmpty }
    }

    public func engine(for id: String, client: String?) -> Engine {
        lock.lock()
        if let e = byID[id] { lock.unlock(); return e }
        let label = Self.label(for: client, taken: Set(byID.values.map(\.label)))
        let e = Engine(sessionID: id, label: label, focusGuard: focusGuard)
        e.onChange = { [weak self] in self?.changed() }
        byID[id] = e
        order.append(id)
        lock.unlock()
        Log.info("session \(id.prefix(8)) started: \(label)")
        changed()
        return e
    }

    /// "Claude Code", "Codex", or the client's own name; numbered when two
    /// sessions would share one.
    static func label(for client: String?, taken: Set<String>) -> String {
        let name = client ?? ""
        let lower = name.lowercased()
        let base: String
        if lower.contains("claude") { base = "Claude Code" }
        else if lower.contains("codex") { base = "Codex" }
        else if name.isEmpty { base = "Agent" }
        else { base = name }
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// A tool call from the socket. `_session` and `_client` say which session it's for.
    public func call(tool: String, args: JSONObject) -> ToolResult {
        var args = args
        let id = (args.removeValue(forKey: "_session") as? String) ?? Self.defaultSession
        let client = args.removeValue(forKey: "_client") as? String
        return engine(for: id, client: client).call(tool: tool, args: args)
    }

    /// Main thread.
    public func start() {
        // Before any display exists, so the cursor can never be on one unwatched.
        focusGuard.startCursorWatch()
        let recovered = WindowManager.recoverFromPreviousRun()
        if !recovered.isEmpty { Log.info("Cleaned up after the last run: " + recovered.joined(separator: "; ")) }
        focusGuard.start()
        // An app starting to play sound gets a new audio process object; route
        // it right away instead of on the next tick, so little reaches the speakers.
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            self?.routeAudio()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.ticks += 1
            self.changed()
            self.routeAudio()
            if self.ticks % 5 == 0 {
                for e in self.engines { e.tearDownIfIdle(idleMs: Self.idleTeardownMs) }
                self.forgetDormant()
            }
        }
    }

    /// Apps whose every window is on an agent display play into their
    /// session's audio file instead of the speakers. Apps the user also has
    /// windows in (minimized and hidden ones count) are left alone.
    private func routeAudio() {
        let displays = AgentDisplay.running.map(\.bounds)
        let engines = self.engines.filter { $0.display.isRunning }
        guard !engines.isEmpty else { return }
        var onAgent: [pid_t: Bool] = [:]
        for w in WindowList.all() where w.layer == 0 && w.bounds.width > 40 && w.bounds.height > 40 {
            let c = CGPoint(x: w.bounds.midX, y: w.bounds.midY)
            let mine = displays.contains { $0.contains(c) }
            onAgent[w.pid] = (onAgent[w.pid] ?? true) && mine
        }
        for e in engines {
            let pids = Set(e.windows.windows.filter { !$0.handedOff }.map(\.pid)).filter { onAgent[$0] == true }
            e.audio.route(pids.compactMap { NSRunningApplication(processIdentifier: $0) })
        }
    }

    /// Sessions whose agent has gone away (its display removed, nothing open)
    /// are dropped, which also frees their names.
    private func forgetDormant() {
        lock.lock()
        let gone = byID.filter { $0.key != Self.defaultSession && $0.value.isDormant(idleMs: Self.idleTeardownMs * 2) }.map(\.key)
        for id in gone { byID[id]?.audio.end(); byID[id] = nil }
        order.removeAll { gone.contains($0) }
        lock.unlock()
        for id in gone { Log.info("session \(id.prefix(8)) ended") }
        if !gone.isEmpty { changed() }
    }

    /// Main thread. Releases every session's windows, then removes the displays.
    public func shutdown() {
        let group = DispatchGroup()
        let all = engines
        for e in all { e.releaseForShutdown(group) }
        if group.wait(timeout: .now() + 4) == .timedOut { Log.info("shutdown: gave up waiting for windows to be released") }
        for e in all { e.finishShutdown() }
    }

    public var allPaused: Bool {
        let a = activeEngines
        return !a.isEmpty && a.allSatisfy(\.paused)
    }

    public func setPausedAll(_ value: Bool) {
        for e in engines { e.setPaused(value) }
    }

    public func stopAll() {
        for e in engines { e.stopAll() }
    }

    public var isActive: Bool { engines.contains { $0.isActive } }

    /// For the menu bar icon: anything waiting on the user wins, then
    /// take-over, then work, then pause.
    public var status: EngineStatus {
        let all = engines.map(\.status)
        if let w = all.first(where: { if case .waiting = $0 { return true }; return false }) { return w }
        if all.contains(.userInControl) { return .userInControl }
        if let w = all.first(where: { if case .working = $0 { return true }; return false }) { return w }
        if !activeEngines.isEmpty && allPaused { return .paused }
        return .idle
    }

    private func changed() {
        if Thread.isMainThread { onChange?() } else { DispatchQueue.main.async { self.onChange?() } }
    }
}
