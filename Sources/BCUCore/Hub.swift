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
    /// Connections carrying each session's calls right now.
    private var attached: [String: Int] = [:]
    /// When each session's last connection went away.
    private var departedAtMs: [String: Double] = [:]
    /// A session whose agent went away keeps its windows this long, in case
    /// the agent's connection comes back (its `bcu mcp` restarting).
    public static let orphanGraceMs: Double = 30_000
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

    /// A connection began carrying this session's calls, or one that did
    /// went away (`SocketServer.sessionHandler`). When the last one goes the
    /// agent is gone: nobody is left to release its windows, and they'd hold
    /// a display, an app's key window and the app itself back from the
    /// front for good. Its display goes at once if it has no windows, and
    /// its windows after `orphanGraceMs`. Not the default session
    /// (`bcu call`), which is a new connection every call.
    public func sessionAttached(_ id: String, _ on: Bool) {
        guard id != Self.defaultSession else { return }
        lock.lock()
        let n = max(0, (attached[id] ?? 0) + (on ? 1 : -1))
        attached[id] = n == 0 ? nil : n
        departedAtMs[id] = n == 0 && !on ? nowMs() : nil
        let e = byID[id]
        lock.unlock()
        guard !on, n == 0, let e else { return }
        Log.info("session \(Self.short(id)): its agent went away")
        e.agentLeft(graceMs: Self.orphanGraceMs) { [weak self, weak e] in e.flatMap { self?.isAttached($0) } ?? true }
    }

    /// Whether a connection carries this session's calls now, under any id
    /// (a restarted agent's session goes on under its new one, see `takeOver`).
    private func isAttached(_ e: Engine) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return byID.contains { $0.value === e && (attached[$0.key] ?? 0) > 0 }
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
        var caller = engine(for: id, client: client, label: label, host: host)
        // An agent can hand a window to its subagent (or back): the call goes
        // to the session that owns the window, on that session's display.
        if let windowID = (args["window_id"] as? NSNumber)?.uint32Value, caller.windows.window(windowID) == nil {
            if let owner = relative(of: id, owning: windowID) {
                return owner.call(tool: tool, args: args)
            }
            caller = takeOver(windowID, for: caller, id: id)
        }
        return caller.call(tool: tool, args: args)
    }

    /// An agent whose `bcu mcp` was restarted (its client does that after a
    /// call times out or the server dies) comes back as a new session, and
    /// the windows it's working in belong to the old one: every call on them
    /// failed with "isn't one of yours", and the old session held them and
    /// its display with nobody left to release them. So a call that names a
    /// window of a session whose agent has gone away, from the same kind of
    /// client, makes the caller that session again: same display, windows
    /// and what it last read in them. (Only the agent that opened a window
    /// was ever told its id.) A caller that already has a display or
    /// windows of its own, or a host app's session (the app knows it by its
    /// id), gets the windows instead. Returns the session to run the call.
    private func takeOver(_ window: CGWindowID, for caller: Engine, id callerID: String) -> Engine {
        lock.lock()
        let departed = byID.first { id, e in
            id != Self.defaultSession && e !== caller && (attached[id] ?? 0) == 0 && e.host == caller.host
                && Self.kind(e.label) == Self.kind(caller.label) && e.windows.window(window) != nil
        }
        guard let (oldID, old) = departed else { lock.unlock(); return caller }
        if caller.host == nil, !caller.display.isRunning, caller.windows.windows.isEmpty {
            byID[callerID] = old
            byID[oldID] = nil
            departedAtMs[oldID] = nil
            parentOf[oldID] = nil
            order.removeAll { $0 == callerID }
            if let i = order.firstIndex(of: oldID) { order[i] = callerID } else { order.append(callerID) }
            lock.unlock()
            Log.info("session \(Self.short(callerID)) is session \(Self.short(oldID)) back after its agent restarted: it keeps its display and \(old.windows.windows.count) window(s)")
            changed()
            return old
        }
        lock.unlock()
        let moved = caller.windows.takeOver(from: old.windows)
        Log.info("session \(Self.short(callerID)) took over \(moved) window(s) of session \(Self.short(oldID)), whose agent went away")
        changed()
        return caller
    }

    /// A session label without its number ("Claude Code 2" and "Claude Code").
    static func kind(_ label: String) -> String {
        let parts = label.split(separator: " ")
        if parts.count > 1, let last = parts.last, Int(last) != nil { return parts.dropLast().joined(separator: " ") }
        return label
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
        // A display with nothing on it shouldn't be what keeps a closed
        // laptop awake, or what macOS makes the main display while the
        // user's sleep.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            AgentDisplay.reapSpares(all: true)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.ticks += 1
            self.changed()
            self.routeAudio()
            AgentDisplay.tend()
            if AgentDisplay.someoneWaiting {
                // Another agent needs a display: one with no windows goes
                // sooner, and so does one whose agent went away (an agent
                // that's coming back is back within a few seconds).
                for e in self.engines { e.tearDownIfIdle(idleMs: Self.busyTeardownMs) }
                self.lock.lock()
                let now = nowMs()
                let departed = self.departedAtMs.filter { now - $0.value > Self.busyTeardownMs }.compactMap { id, _ in self.byID[id].map { (id, $0) } }
                self.lock.unlock()
                for (_, e) in departed { e.releaseAbandoned { [weak self, weak e] in e.flatMap { self?.isAttached($0) } ?? true } }
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
        for id in gone { byID[id]?.audio.end(); byID[id] = nil; parentOf[id] = nil; departedAtMs[id] = nil }
        order.removeAll { gone.contains($0) }
        lock.unlock()
        for id in gone { Log.info("session \(Self.short(id)) ended") }
        if !gone.isEmpty { changed() }
    }

    /// Main thread. Releases every session's windows, then removes the displays.
    public func shutdown() {
        // First: no app stays kept from the front once the engine is gone.
        focusGuard.gate.stop()
        let group = DispatchGroup()
        let all = engines
        for e in all { e.releaseForShutdown(group) }
        if group.wait(timeout: .now() + 4) == .timedOut { Log.info("shutdown: gave up waiting for windows to be released") }
        for e in all { e.finishShutdown() }
        AgentDisplay.reapSpares(all: true)
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
