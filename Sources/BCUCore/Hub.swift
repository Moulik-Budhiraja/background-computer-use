import AppKit
import CoreAudio
import BCUShared

/// Every agent session. Each MCP connection (`bcu mcp`) names its own
/// session and gets its own display, windows, pause and take-over; calls
/// without a session (`bcu call`) share a default one. One focus guard
/// watches over all of them.
///
/// A session can belong to a host app (`bcu mcp --host <id>`), which shows
/// it in its own UI. While that host is connected and subscribed (see
/// `HostServer`), the session is left out of `shownEngines`, which is what
/// the menu bar app shows.
public final class Hub {
    public let focusGuard = FocusGuard()
    /// Main thread: status, activity or sessions changed.
    public var onChange: (() -> Void)?
    private var observers: [Int: () -> Void] = [:]
    private var nextObserver = 0
    /// Live subscriptions per host ID.
    private var claims: [String: Int] = [:]
    /// Where each host keeps its sessions' recordings, by host ID ("" for
    /// sessions without a host: the menu bar app's). A host without one
    /// isn't recorded.
    private var recordings: [String: Recordings] = [:]

    public static let defaultSession = "default"
    /// A display with no windows and no calls for this long is removed.
    public static let idleTeardownMs: Double = 60_000
    /// The same, while another agent is waiting for a display.
    public static let busyTeardownMs: Double = 5_000

    private let lock = NSLock()
    private var byID: [String: Engine] = [:]
    /// Each subagent session's parent: the session of the connection it
    /// came in on (see `bcu mcp`).
    private var parentOf: [String: String] = [:]
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

    /// Sessions no connected host app shows itself: the menu bar app's.
    public var shownEngines: [Engine] {
        lock.lock(); defer { lock.unlock() }
        return order.compactMap { byID[$0] }.filter { e in e.host.map { (claims[$0] ?? 0) == 0 } ?? true }
    }

    /// `activeEngines`, of the shown ones.
    public var shownActiveEngines: [Engine] {
        shownEngines.filter { $0.display.isRunning || !$0.windows.windows.isEmpty }
    }

    public func engine(id: String) -> Engine? {
        lock.lock(); defer { lock.unlock() }
        return byID[id]
    }

    /// The session a subagent's session came from, if it's a subagent's.
    public func parent(of id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return parentOf[id]
    }

    /// A host app shows its sessions itself until the returned release is called.
    public func claim(host: String) -> () -> Void {
        lock.lock(); claims[host, default: 0] += 1; lock.unlock()
        changed()
        var released = false
        return { [weak self] in
            guard let self, !released else { return }
            released = true
            self.lock.lock()
            self.claims[host, default: 1] -= 1
            if self.claims[host] == 0 { self.claims[host] = nil }
            self.lock.unlock()
            self.changed()
        }
    }

    /// Record the sessions of `host` (nil: those without a host, which the
    /// menu bar app shows) into `store` from now on, or stop recording them
    /// (nil). Sessions already running switch too.
    public func setRecordings(host: String?, _ store: Recordings?) {
        lock.lock()
        recordings[host ?? ""] = store
        let affected = order.compactMap { byID[$0] }.filter { $0.host == host }
        lock.unlock()
        for e in affected { e.setRecordings(store) }
        store?.maintain()
    }

    public func recordings(host: String?) -> Recordings? {
        lock.lock(); defer { lock.unlock() }
        return recordings[host ?? ""]
    }

    /// Called on the main thread on every change, like `onChange`, for as
    /// long as the returned ID isn't removed.
    public func addObserver(_ f: @escaping () -> Void) -> Int {
        lock.lock(); defer { lock.unlock() }
        nextObserver += 1
        observers[nextObserver] = f
        return nextObserver
    }

    public func removeObserver(_ id: Int) {
        lock.lock(); observers[id] = nil; lock.unlock()
    }

    public func engine(for id: String, client: String?, label wanted: String? = nil, host: String? = nil) -> Engine {
        lock.lock()
        if let e = byID[id] { lock.unlock(); return e }
        let label = Self.label(for: wanted ?? client, taken: Set(byID.values.map(\.label)), exact: wanted != nil)
        let e = Engine(sessionID: id, label: label, focusGuard: focusGuard, host: host)
        e.onChange = { [weak self] in self?.changed() }
        e.setRecordings(recordings[host ?? ""])
        byID[id] = e
        order.append(id)
        lock.unlock()
        Log.info("session \(Self.short(id)) started: \(label)")
        changed()
        return e
    }

    /// A session ID for the log: its first 8 characters, and a subagent's own part.
    static func short(_ id: String) -> String {
        let parts = id.split(separator: "/", maxSplits: 1)
        return parts.count == 2 ? "\(parts[0].prefix(8))/\(parts[1].prefix(8))" : String(id.prefix(8))
    }

    /// "Claude Code", "Codex", or the client's own name; numbered when two
    /// sessions would share one.
    static func label(for client: String?, taken: Set<String>, exact: Bool = false) -> String {
        let name = client ?? ""
        let lower = name.lowercased()
        let base: String
        if exact && !name.isEmpty { base = name }
        else if lower.contains("claude") { base = "Claude Code" }
        else if lower.contains("codex") { base = "Codex" }
        else if name.isEmpty { base = "Agent" }
        else { base = name }
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// A tool call from the socket. `_session` and `_client` say which
    /// session it's for; `_parent`, that it's a subagent's of that session.
    public func call(tool: String, args: JSONObject) -> ToolResult {
        var args = args
        let id = (args.removeValue(forKey: "_session") as? String) ?? Self.defaultSession
        let client = args.removeValue(forKey: "_client") as? String
        let parent = args.removeValue(forKey: "_parent") as? String
        let label = args.removeValue(forKey: "_label") as? String
        let host = (args.removeValue(forKey: "_host") as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let parent {
            lock.lock(); parentOf[id] = parent; lock.unlock()
        }
        let caller = engine(for: id, client: client, label: label, host: host)
        // An agent can hand a window to its subagent (or back): the call goes
        // to the session that owns the window, on that session's display.
        if let windowID = (args["window_id"] as? NSNumber)?.uint32Value, caller.windows.window(windowID) == nil,
           let owner = relative(of: id, owning: windowID) {
            return owner.call(tool: tool, args: args)
        }
        return caller.call(tool: tool, args: args)
    }

    /// The session in the same agent family as `id` (its parent, its
    /// subagents, their siblings) that has this window.
    private func relative(of id: String, owning window: CGWindowID) -> Engine? {
        lock.lock()
        let root = parentOf[id] ?? id
        let family = byID.filter { $0.key != id && ($0.key == root || parentOf[$0.key] == root) }.map(\.value)
        lock.unlock()
        return family.first { $0.windows.window(window) != nil }
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
            if AgentDisplay.someoneWaiting {
                // Another agent needs a display: one with no windows goes sooner.
                for e in self.engines { e.tearDownIfIdle(idleMs: Self.busyTeardownMs) }
            }
            if self.ticks % 3600 == 0 {
                self.lock.lock(); let stores = Array(self.recordings.values); self.lock.unlock()
                for r in stores { r.maintain() }
            }
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
            let pids = Set(e.windows.windows.filter { !$0.withUser }.map(\.pid)).filter { onAgent[$0] == true }
            e.audio.route(pids.compactMap { NSRunningApplication(processIdentifier: $0) })
        }
    }

    /// Sessions whose agent has gone away (its display removed, nothing open)
    /// are dropped, which also frees their names.
    private func forgetDormant() {
        lock.lock()
        let gone = byID.filter { $0.key != Self.defaultSession && $0.value.isDormant(idleMs: Self.idleTeardownMs * 2) }.map(\.key)
        for id in gone { byID[id]?.audio.end(); byID[id] = nil; parentOf[id] = nil }
        order.removeAll { gone.contains($0) }
        lock.unlock()
        for id in gone { Log.info("session \(Self.short(id)) ended") }
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

    /// The menu bar's pause and stop act on the sessions it shows; a host
    /// app pauses and stops its own.
    public var allPaused: Bool {
        let a = shownActiveEngines
        return !a.isEmpty && a.allSatisfy(\.paused)
    }

    public func setPausedAll(_ value: Bool) {
        for e in shownEngines { e.setPaused(value) }
    }

    public func stopAll() {
        for e in shownEngines { e.stopAll() }
    }

    /// Any session working, shown or not (for updates, which wait for every agent).
    public var isActive: Bool { engines.contains { $0.isActive } }

    /// A session the menu bar shows is working.
    public var shownIsActive: Bool { shownEngines.contains { $0.isActive } }

    /// For the menu bar icon: anything waiting on the user wins, then
    /// take-over, then work, then pause.
    public var status: EngineStatus {
        let all = shownEngines.map(\.status)
        if let w = all.first(where: { if case .waiting = $0 { return true }; return false }) { return w }
        if all.contains(.userInControl) { return .userInControl }
        if let w = all.first(where: { if case .working = $0 { return true }; return false }) { return w }
        if !shownActiveEngines.isEmpty && allPaused { return .paused }
        return .idle
    }

    private func changed() {
        func notify() {
            onChange?()
            lock.lock(); let all = Array(observers.values); lock.unlock()
            for f in all { f() }
        }
        if Thread.isMainThread { notify() } else { DispatchQueue.main.async { notify() } }
    }
}
