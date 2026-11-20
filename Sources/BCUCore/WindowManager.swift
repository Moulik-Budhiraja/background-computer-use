import AppKit
import ApplicationServices
import BCUShared
import CPrivate

public final class AgentWindow {
    public enum Kind: String { case opened, borrowed, caught }
    public let id: CGWindowID
    public let pid: pid_t
    public let appName: String
    public let bundleID: String?
    public let kind: Kind
    public var originalFrame: CGRect?
    public var handedOff = false
    public var handoffReason: String?
    /// The user brought the handed-off window onto their screen.
    public var withUser = false

    init(id: CGWindowID, pid: pid_t, appName: String, bundleID: String?, kind: Kind, originalFrame: CGRect? = nil) {
        self.id = id
        self.pid = pid
        self.appName = appName
        self.bundleID = bundleID
        self.kind = kind
        self.originalFrame = originalFrame
    }
}

/// Owns which windows belong to one agent session and keeps them on its display.
public final class WindowManager {
    let display: AgentDisplay
    let focusGuard: FocusGuard
    /// Names this session's crash-recovery file.
    let sessionKey: String
    private let lock = NSLock()
    private var registry: [CGWindowID: AgentWindow] = [:]
    /// When each window was registered (`nowMs`).
    private var registeredAt: [CGWindowID: Double] = [:]
    /// The watchdog leaves a window this new alone: an app launched hidden
    /// has windows accessibility sees before the window server lists them.
    static let newWindowGraceMs = 5000.0
    /// The app's windows when this session last began acting on it, and when.
    private var knownBefore: [pid_t: (ids: Set<CGWindowID>, ms: Double)] = [:]
    private var nextSlot = 0
    private var watchdog: Timer?

    init(display: AgentDisplay, focusGuard: FocusGuard, sessionKey: String) {
        self.display = display
        self.focusGuard = focusGuard
        self.sessionKey = sessionKey.filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    // MARK: Across sessions

    /// Apps some session is opening a window in. Another session's watchdog
    /// leaves new windows of these apps alone; they belong to the opener.
    private static let sharedLock = NSLock()
    private static var openingAnywhere: Set<pid_t> = []
    /// One window opening at a time across sessions, so one session's
    /// catcher can't take another's new window.
    static let openLock = NSLock()

    static func isOpening(_ pid: pid_t) -> Bool {
        sharedLock.lock(); defer { sharedLock.unlock() }
        return openingAnywhere.contains(pid)
    }

    /// Windows any session has registered: no other session catches them.
    private static var registeredAnywhere: [CGWindowID: (session: String, pid: pid_t)] = [:]

    static func isRegistered(_ id: CGWindowID, byOtherThan session: String) -> Bool {
        sharedLock.lock(); defer { sharedLock.unlock() }
        return registeredAnywhere[id].map { $0.session != session } ?? false
    }

    /// Windows a session opened or caught, whether or not it still has
    /// them: the only ones cleanup may close (any other is the user's).
    private static var agentMade: Set<CGWindowID> = []

    static func wasAgentMade(_ id: CGWindowID) -> Bool {
        sharedLock.lock(); defer { sharedLock.unlock() }
        return agentMade.contains(id)
    }

    /// Some session's window, as of right now.
    static func isRegistered(_ id: CGWindowID) -> Bool {
        sharedLock.lock(); defer { sharedLock.unlock() }
        return registeredAnywhere[id] != nil
    }

    /// The apps agents have windows in, across sessions.
    public static func agentPids() -> Set<pid_t> {
        sharedLock.lock(); defer { sharedLock.unlock() }
        return Set(registeredAnywhere.values.map(\.pid))
    }

    public var windows: [AgentWindow] {
        lock.lock(); defer { lock.unlock() }
        return Array(registry.values).sorted { $0.id < $1.id }
    }

    public func window(_ id: CGWindowID) -> AgentWindow? {
        lock.lock(); defer { lock.unlock() }
        return registry[id]
    }

    func register(_ w: AgentWindow) {
        lock.lock(); registry[w.id] = w; registeredAt[w.id] = nowMs(); lock.unlock()
        Self.sharedLock.lock()
        Self.registeredAnywhere[w.id] = (sessionKey, w.pid)
        if w.kind != .borrowed { Self.agentMade.insert(w.id) }
        Self.sharedLock.unlock()
        Self.ownedAgain(w.id)
        persist()
    }

    /// Move every window of `other` (a session whose agent is gone) to this
    /// session. They're on its display still; the sweep brings each onto
    /// this one. Returns how many.
    func takeOver(from other: WindowManager) -> Int {
        let theirs = other.windows
        for w in theirs {
            other.unregister(w.id)
            register(w)
        }
        return theirs.count
    }

    func unregister(_ id: CGWindowID) {
        lock.lock(); registry[id] = nil; registeredAt[id] = nil; lock.unlock()
        Self.sharedLock.lock()
        if Self.registeredAnywhere[id]?.session == sessionKey { Self.registeredAnywhere[id] = nil }
        Self.sharedLock.unlock()
        persist()
    }

    private var registryURL: URL { BCUPaths.supportDirectory.appendingPathComponent("windows-\(sessionKey).json") }

    /// Written on every change, so the next launch can clean up after a crash.
    private func persist() {
        lock.lock()
        let entries: [[String: Any]] = registry.values.map { w in
            var e: [String: Any] = ["id": Int(w.id), "pid": Int(w.pid), "app": w.appName, "kind": w.kind.rawValue]
            if let f = w.originalFrame { e["frame"] = [f.minX, f.minY, f.width, f.height] }
            return e
        }
        lock.unlock()
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: registryURL)
            return
        }
        if let data = try? JSONSerialization.data(withJSONObject: entries) {
            try? FileManager.default.createDirectory(at: BCUPaths.supportDirectory, withIntermediateDirectories: true)
            try? data.write(to: registryURL, options: .atomic)
        }
    }

    /// On launch: close windows a previous run opened, return ones it
    /// borrowed, for every session it had.
    public static func recoverFromPreviousRun() -> [String] {
        let dir = BCUPaths.supportDirectory
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("windows") && $0.hasSuffix(".json") }
        // Before this run has a display of its own, every BCU display is
        // one the last run left.
        let agentDisplays = AgentDisplay.strayIDs.map { CGDisplayBounds($0) }
        return files.flatMap { recover(dir.appendingPathComponent($0), agentDisplays: agentDisplays) }
    }

    /// Whether recovery closes (or answers for) a window the last run had:
    /// only one it opened or caught that's still on a display of its. Once
    /// its display is gone the window is on the user's screen, where they
    /// may be using it now.
    static func recoveryCloses(kind: String?, bounds: CGRect, agentDisplays: [CGRect]) -> Bool {
        kind != AgentWindow.Kind.borrowed.rawValue && agentDisplays.contains { $0.contains(CGPoint(x: bounds.midX, y: bounds.midY)) }
    }

    private static func recover(_ url: URL, agentDisplays: [CGRect]) -> [String] {
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var notes: [String] = []
        func live(_ e: [String: Any]) -> (id: CGWindowID, pid: pid_t, ax: AXUIElement)? {
            guard let id = (e["id"] as? Int).map({ CGWindowID($0) }), let pid = (e["pid"] as? Int).map({ pid_t($0) }),
                  WindowList.info(id)?.pid == pid, let ax = AX.window(pid: pid, id: id) else { return nil }
            return (id, pid, ax)
        }
        func closes(_ e: [String: Any], _ id: CGWindowID) -> Bool {
            guard let bounds = WindowList.info(id)?.bounds else { return false }
            return recoveryCloses(kind: e["kind"] as? String, bounds: bounds, agentDisplays: agentDisplays)
        }
        // A dialog the last run caught that's still asking whether to leave
        // a page would keep that page's window open: answer it first.
        for e in entries where e["kind"] as? String == AgentWindow.Kind.caught.rawValue {
            if let w = live(e), closes(e, w.id), answerLeave(w.ax) { sleepMs(400); notes.append("answered Leave for \(e["app"] ?? "?")") }
        }
        // The dialogs each app already had up before anything here is closed:
        // those are the user's (a "Leave site?" on a page of their own), and
        // answering one would throw away what they'd typed there.
        var dialogsBefore: [pid_t: Set<CGWindowID>] = [:]
        var closed: [(id: CGWindowID, pid: pid_t, app: Any)] = []
        for e in entries {
            guard let (id, pid, ax) = live(e) else { continue }
            if e["kind"] as? String == "borrowed", let f = e["frame"] as? [Double], f.count == 4 {
                AX.setPosition(ax, CGPoint(x: f[0], y: f[1]))
                AX.setSize(ax, CGSize(width: f[2], height: f[3]))
                notes.append("returned \(e["app"] ?? "?") window \(id)")
            } else if !closes(e, id) {
                notes.append("left \(e["app"] ?? "?") window \(id) where it is: it's on your screen now")
            } else if let close = AX.element(ax, "AXCloseButton") {
                if dialogsBefore[pid] == nil { dialogsBefore[pid] = Self.dialogIDs(pid) }
                AX.perform(close, "AXPress")
                closed.append((id, pid, e["app"] ?? "?"))
                notes.append("closed leftover \(e["app"] ?? "?") window \(id)")
            }
        }
        // A page that asks only now: its dialog is a new window of that app.
        // Only for a window closed here that's still open, and only a dialog
        // that wasn't there before the close (a window returned to the user
        // was never closed, so nothing is answered for it).
        sleepMs(500)
        for (id, pid, app) in closed {
            guard WindowList.info(id) != nil, let before = dialogsBefore[pid] else { continue }
            for other in AX.windows(pid) where AX.string(other, "AXSubrole") != "AXStandardWindow" {
                guard let otherID = AX.windowID(other), otherID != id,
                      Self.isNewDialog(otherID, before: before, closed: closed.map(\.id)) else { continue }
                let e: [String: Any] = ["app": app]
                if let size = AX.size(other), size.width < 700, size.height < 500, answerLeave(other) {
                    notes.append("answered Leave for \(e["app"] ?? "?") window \(id)")
                    sleepMs(400)
                }
            }
        }
        return notes
    }

    /// The ids of an app's windows that aren't standard ones (dialogs, sheets
    /// with a window of their own).
    static func dialogIDs(_ pid: pid_t) -> Set<CGWindowID> {
        Set(AX.windows(pid).filter { AX.string($0, "AXSubrole") != "AXStandardWindow" }.compactMap { AX.windowID($0) })
    }

    /// Whether a dialog seen after recovery closed some windows came up
    /// because of that: it wasn't there before, and isn't one of the windows
    /// closed.
    static func isNewDialog(_ id: CGWindowID, before: Set<CGWindowID>, closed: [CGWindowID]) -> Bool {
        !before.contains(id) && !closed.contains(id)
    }

    /// Close any window (used for one-off cleanup, not exposed to agents).
    public func closeAny(_ id: CGWindowID) -> Bool {
        guard let info = WindowList.info(id), let ax = AX.window(pid: info.pid, id: id),
              let close = AX.element(ax, "AXCloseButton") else { return false }
        unregister(id)
        return AX.perform(close, "AXPress") == .success
    }

    /// Move any window onto the user's main display (not exposed to agents).
    public func moveToUser(_ id: CGWindowID, frame: CGRect?) -> Bool {
        guard let info = WindowList.info(id), let ax = AX.window(pid: info.pid, id: id) else { return false }
        let main = CGDisplayBounds(CGMainDisplayID())
        let f = frame ?? CGRect(x: main.minX + 40, y: main.minY + 60, width: min(info.bounds.width, main.width - 80), height: min(info.bounds.height, main.height - 100))
        unregister(id)
        AX.setPosition(ax, f.origin)
        return AX.setSize(ax, f.size)
    }

    // MARK: App lookup

    public struct AppTarget {
        public let name: String
        public let bundleID: String?
        public let running: NSRunningApplication?
        public let url: URL?
    }

    public func resolveApp(_ query: String) throws -> AppTarget {
        let q = query.trimmingCharacters(in: .whitespaces)
        // A bundle id is matched as given ("com.example.app" ends in .app); a name without ".app".
        let name = AppNameMatch.stripped(q)
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }
        func target(_ app: NSRunningApplication) -> AppTarget {
            AppTarget(name: app.localizedName ?? q, bundleID: app.bundleIdentifier, running: app, url: app.bundleURL)
        }
        func target(_ url: URL) -> AppTarget {
            AppTarget(name: url.deletingPathExtension().lastPathComponent, bundleID: Bundle(url: url)?.bundleIdentifier, running: nil, url: url)
        }
        if let app = running.first(where: { AppNameMatch.sameBundleID($0.bundleIdentifier, q) })
            ?? running.first(where: { $0.localizedName.map { AppNameMatch.rank(name, name: $0) == .exact } ?? false }) {
            return target(app)
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: q) { return target(url) }
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                    "/Applications/Utilities", NSHomeDirectory() + "/Applications", "/System/Library/CoreServices"]
        for dir in dirs {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).app")
            if FileManager.default.fileExists(atPath: url.path) { return target(url) }
        }
        // No exact match: the running or installed app whose name matches
        // best ("Chrome" is Google Chrome, "Code" isn't Xcode when Visual
        // Studio Code is there), if just one does.
        var candidates: [String: AppTarget] = [:]
        for app in running { if let n = app.localizedName, candidates[n.lowercased()] == nil { candidates[n.lowercased()] = target(app) } }
        let runningPaths = Set(running.compactMap { $0.bundleURL?.standardizedFileURL.path })
        for dir in dirs {
            for file in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where file.hasSuffix(".app") {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(file)
                let n = url.deletingPathExtension().lastPathComponent
                guard candidates[n.lowercased()] == nil, !runningPaths.contains(url.standardizedFileURL.path) else { continue }
                candidates[n.lowercased()] = target(url)
            }
        }
        switch AppNameMatch.best(name, among: candidates.values.map(\.name)) {
        case .one(let n):
            if let t = candidates[n.lowercased()] { return t }
        case .ambiguous(let names):
            throw ToolError("\"\(q)\" could be \(names.map { "\"\($0)\"" }.joined(separator: ", ")). Give the app's full name or bundle id.")
        case .none: break
        }
        throw ToolError("no app named \"\(q)\" is running or installed. Use list_apps to see running apps.")
    }

    // MARK: Opening

    public struct OpenResult {
        public let window: AgentWindow
        public let notes: [String]
    }

    /// How a new window is steered onto the agent display.
    /// - space: assign the app to the agent display's Space while the window opens
    /// - anchor: make the agent's existing window of the app its key window first
    /// - plain: neither; only catch and move
    public struct Placement: OptionSet {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let space = Placement(rawValue: 1)
        public static let anchor = Placement(rawValue: 2)
        // Space assignment is not part of auto: SLSProcessAssignToSpace moves
        // every window of the process, including the user's, to that Space.
        public static let auto: Placement = [.anchor]

        public init(name: String?) {
            switch name?.lowercased() {
            case "space-unsafe": self = .space
            case "anchor": self = .anchor
            case "plain", "none": self = []
            default: self = .auto
            }
        }
    }

    /// `hold`: the user's input, when they're in that app. It's held only
    /// from when the new window could take key until key is back on theirs.
    /// `beforeAsk` runs once it's this session's turn to open a window,
    /// just before the app is asked for it (and before any input is held);
    /// if it throws, nothing is opened. `keyBack` runs once key is back on
    /// the window that had it (or that was given up on).
    public func open(app query: String, placement: Placement = .auto, trigger: String? = nil, hold: InputHold? = nil,
                     beforeAsk: (() throws -> Void)? = nil, keyBack: (() -> Void)? = nil) throws -> OpenResult {
        let target = try resolveApp(query)
        if let running = target.running {
            return try openNewWindow(pid: running.processIdentifier, name: target.name, bundleID: target.bundleID, placement: placement, trigger: trigger,
                                     hold: hold, beforeAsk: beforeAsk, keyBack: keyBack)
        }
        guard let url = target.url else { throw ToolError("can't find \(target.name) on disk") }
        return try launch(url: url, name: target.name, bundleID: target.bundleID)
    }

    /// Launch a not-running app hidden and without activation, move its first
    /// windows onto the agent display, then unhide it there.
    private func launch(url: URL, name: String, bundleID: String?) throws -> OpenResult {
        // An app that starts up brings itself forward when it's ready,
        // whatever it was asked: kept from the front from the moment it appears.
        if let bundleID { focusGuard.willLaunch(bundleID: bundleID) }
        defer { if let bundleID { focusGuard.launched(bundleID: bundleID) } }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        config.addsToRecentItems = false
        var launched: NSRunningApplication?
        var launchError: Error?
        let sem = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, err in
            launched = app
            launchError = err
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 20)
        guard let app = launched else {
            throw ToolError("could not launch \(name): \(launchError?.localizedDescription ?? "timed out")")
        }
        let pid = app.processIdentifier
        focusGuard.beginAction(pid: pid, cause: "launching \(name)")
        defer { focusGuard.endAction(pid: pid, graceMs: 2000) }

        // Wait for the app to answer accessibility and show its first
        // windows, then for it to finish showing them: an app restores
        // several (Chrome's last session, TextEdit's unsaved documents) one
        // after another.
        let deadline = nowMs() + 8000
        var axWindows: [AXUIElement] = []
        var lastChangeMs = nowMs()
        var settleBy = deadline
        while nowMs() < min(deadline, settleBy) {
            let now = AX.windows(pid).filter { AX.windowID($0) != nil }
            if Set(now.compactMap { AX.windowID($0) }) != Set(axWindows.compactMap { AX.windowID($0) }) {
                axWindows = now
                lastChangeMs = nowMs()
                if settleBy == deadline && !now.isEmpty { settleBy = nowMs() + 3000 }
            }
            if !axWindows.isEmpty && nowMs() - lastChangeMs >= 700 { break }
            sleepMs(100)
        }
        // What the app shows at startup is the user's, as if they'd opened
        // it: it stays on their screen and is never closed with the agent's
        // windows. The agent gets a window of its own. One restored where an
        // agent display is (or was) goes to the user's main display.
        let main = CGDisplayBounds(CGMainDisplayID())
        for w in axWindows {
            guard let f = AX.frame(w), AgentDisplay.containing(CGPoint(x: f.midX, y: f.midY)) != nil || !display.touchesUser(f) else { continue }
            let size = f.size
            AX.setSize(w, CGSize(width: min(size.width, main.width - 80), height: min(size.height, main.height - 100)))
            AX.setPosition(w, CGPoint(x: main.minX + 40, y: main.minY + 60))
        }
        app.unhide()
        var notes = ["launched \(name) hidden"]
        if !axWindows.isEmpty { notes.append("the \(axWindows.count) window(s) it opened at startup are the user's and stay on their screen") }
        do {
            // (It notes the startup windows as there before, so they aren't caught as the agent's.)
            let result = try openNewWindow(pid: pid, name: name, bundleID: bundleID)
            return OpenResult(window: result.window, notes: notes + result.notes)
        } catch {
            // An app with one window (Calculator, System Settings): borrow
            // it, so it goes back to the user rather than closing.
            let front = BCUFrontProcessPID()
            if axWindows.count == 1 && front == pid {
                throw ToolError("\(name) didn't open a new window, and the user is using it now, so its window wasn't borrowed. Retry later.")
            }
            guard Self.mayBorrowStartupWindow(startupWindows: axWindows.count, pid: pid, front: front),
                  let id = AX.windowID(axWindows[0]), WindowList.info(id) != nil else { throw error }
            let aw = try borrow(id)
            let title = AX.string(axWindows[0], "AXTitle") ?? ""
            notes.append("\(name) didn't open a new window, so its startup window \"\(title)\" is borrowed: it goes back to the user when released")
            return OpenResult(window: aw, notes: notes)
        }
    }

    /// Whether a cold launch that got no new window borrows the app's
    /// startup window instead: only an app's only one, and not while the
    /// user is in the app (they may have gone to it while the open waited
    /// its turn), as `borrow_window` asks.
    static func mayBorrowStartupWindow(startupWindows: Int, pid: pid_t, front: pid_t) -> Bool {
        startupWindows == 1 && front != pid
    }

    /// Open a new window of a running app and put it on the agent display.
    private func openNewWindow(pid: pid_t, name: String, bundleID: String?, placement: Placement = .auto, trigger: String? = nil,
                               hold: InputHold? = nil, beforeAsk: (() throws -> Void)? = nil, keyBack: (() -> Void)? = nil) throws -> OpenResult {
        // Not while displays are still being added (see `awaitSettled`):
        // before this session's turn, and again once it has it.
        var settledMs = AgentDisplay.awaitSettled()
        Self.openLock.lock()
        settledMs += AgentDisplay.awaitSettled()
        if settledMs > 100 { Log.info("open: waited \(Int(settledMs)) ms for the displays to settle") }
        // Which windows the app has now, taken once it's this session's turn:
        // taken before the wait, it would miss the window another session
        // opened meanwhile, and this one would catch that as its own (two
        // agents with one window, and the window it really opened left
        // wherever the app put it).
        let before = Set(WindowList.of(pid: pid).map(\.id))
        let catcher = WindowCatcher(pid: pid, before: before, manager: self)
        // A window built by script can't take key before it exists: hold the
        // user's input from the moment it shows up, not while it's asked for.
        catcher.onSeen = { hold?.start() }
        focusGuard.beginAction(pid: pid, cause: "opening a \(name) window")
        lock.lock(); opening.insert(pid); lock.unlock()
        Self.sharedLock.lock(); Self.openingAnywhere.insert(pid); Self.sharedLock.unlock()
        defer {
            focusGuard.endAction(pid: pid)
            lock.lock(); opening.remove(pid); lock.unlock()
            Self.sharedLock.lock(); Self.openingAnywhere.remove(pid); Self.sharedLock.unlock()
            Self.openLock.unlock()
        }
        noteBefore(pid: pid)
        var notes: [String] = []
        // With the user's input held, this thread is what they're waiting
        // on: at default QoS it waits hundreds of ms for a core while the
        // app draws its new window.
        let qos = qos_class_self()
        if hold != nil { pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0) }
        defer { if hold != nil { pthread_set_qos_class_self_np(qos, 0) } }

        // If an agent already has a window of this app, make it the app's key
        // window first: apps place new windows relative to their key window,
        // so the new one opens on an agent display instead of the user's
        // screen (where it would cover the pointer and end hover effects).
        // This session's own window first, else any agent's.
        // Key changes while opening must not interleave with another session
        // typing into a window of the same app, so hold the app's input lock
        // until key is handed back.
        let appLock = Engine.inputLock(pid)
        appLock.lock()
        // Only now, with the app to this session: another session's step
        // there can take seconds, and the caller's check (has the user
        // started typing?) and its cover over their window are for the
        // moment the window is asked for, not for that wait.
        do { try beforeAsk?() } catch { appLock.unlock(); throw error }
        var holdingInput = true
        // Keys typed into the app while its key window is moving are held,
        // even if the user wasn't in it.
        focusGuard.beginSwap(pid)
        defer { if holdingInput { focusGuard.endSwap(pid); appLock.unlock() } }
        // Read under the lock: another session's swap may have an agent
        // window key until it's done.
        let previousKey = AX.focusedWindowID(pid)
        // Apps that can be told where to build a new window (Chromium
        // browsers) open it straight on the agent display, so no anchor is
        // needed and nothing ever reaches the user's screen.
        let scripted = trigger == nil || trigger == "script" ? Self.scriptableBrowser(pid: pid, bundleID: bundleID) : nil
        // Without a New Window menu item there's nothing safe to press (see
        // below): say so before holding the user's input.
        if scripted == nil, trigger != "key", Self.newWindowMenuItem(pid: pid) == nil {
            throw ToolError("\(name) has no menu item for a new window, so no window was opened. It may not support multiple windows: use list_windows with app=\"\(name)\" and borrow_window.")
        }
        if scripted == nil { hold?.start() }
        var scope: KeyScope?
        if scripted == nil, placement.contains(.anchor), let anchor = anchorWindow(pid: pid) {
            scope = try? KeyScope.enter(pid: pid, window: anchor)
            if scope != nil { notes.append("anchored on window \(anchor)") }
        }
        // macOS opens a new window full screen, in a Space of its own, when
        // the app's key window is full screen, and may switch the user to
        // it. Take key from that window first (without activating anything)
        // so the new window opens as a normal one.
        var unkeyedFullScreen: CGWindowID?
        if scope == nil, let key = previousKey, let keyAX = AX.window(pid: pid, id: key),
           AX.bool(keyAX, "AXFullScreen") == true, BCUPostFocusRecord(pid, key, false) == 0 {
            unkeyedFullScreen = key
            KeyScope.awaitNoKey(pid: pid, budgetMs: 150)
            notes.append("took key from the app's full-screen window first")
        }
        // Assign the app to the agent display's Space so the window is created there.
        var assigned = false
        if placement.contains(.space) {
            let sid = BCUCurrentSpaceForDisplay(display.displayID)
            if sid != 0 && BCUProcessAssignToSpace(pid, sid) == 0 {
                assigned = true
                notes.append("assigned to the agent Space \(sid)")
            }
        }
        defer { if assigned { _ = BCUProcessAssignToSpace(pid, 0) } }
        catcher.start()
        // Also when asking for the window throws: a catcher left running
        // moves the app's windows, the user's too, for good.
        defer { catcher.stop() }
        var how = ""
        var caught: CGWindowID?
        var scriptFailed = scripted == nil
        if let scripted {
            how = "AppleScript, built at its place on the agent display"
            // The browser shows the window before it answers: ask alongside,
            // so key goes back as soon as the window is caught rather than
            // when the answer is in.
            let frame = nextFrame(size: CGSize(width: 1400, height: 900))
            let ok = Locked<Bool?>(nil)
            // Its answer names the window by the browser's own id, which
            // `navigate` needs; whichever comes last, the answer or the
            // catch, files it.
            let named = Locked<(id: String?, window: CGWindowID?)>((nil, nil))
            DispatchQueue.global(qos: .userInitiated).async {
                let answer = BrowserAutomation.makeWindow(bundleID: scripted, bounds: frame)
                if let id = answer.id {
                    let window = named.with { $0.id = id; return $0.window }
                    if let window { Self.noteBrowserID(id, of: window) }
                }
                ok.value = answer.made
            }
            // In the app the user is in, wait until it's shown too: it's
            // caught when created, before it can take key, and giving key
            // back then would end the hold just before the window takes it.
            caught = catcher.waitForWindow(timeoutMs: 6500, shown: hold != nil) { ok.value == false }
            scriptFailed = caught == nil && ok.value == false
            if let caught {
                let id = named.with { $0.window = caught; return $0.id }
                if let id { Self.noteBrowserID(id, of: caught) }
            }
        }
        if scriptFailed {
            // Only a menu item the app names: a bare cmd+N goes to the app's
            // key window, which is often the user's, and in an app without
            // such an item it does something else there (a new thread, a new
            // note) while their input is held waiting for a window.
            if trigger != "key", let item = Self.newWindowMenuItem(pid: pid) {
                hold?.start()
                let err = AX.perform(item.element, "AXPress")
                how = "menu \"\(item.title)\"" + (err == .success ? "" : " (\(AX.errorName(err)))")
                caught = catcher.waitForWindow(timeoutMs: 5000)
            } else if trigger == "key" {
                hold?.start()
                try Input.pressKey(pid: pid, key: "n", modifiers: ["cmd"])
                how = "cmd+N"
                caught = catcher.waitForWindow(timeoutMs: 5000)
            } else {
                how = "nothing: it has no menu item for a new window"
            }
        }
        // Give key back right away: while the new window is key, the user's
        // window in the same app is blurred.
        scope?.exit()
        // In the app the user is in, no check first that the new window is
        // key: asking a browser busy building a window takes ~100 ms of their
        // held input, and records to their window only ever give key back.
        if let id = caught, let previousKey, previousKey != id, WindowList.info(previousKey) != nil,
           hold != nil || AX.focusedWindowID(pid) == id {
            // Quick records first (the user's window never repaints as
            // inactive), then KeyScope's slower settle if those didn't land.
            for settle in [5.0, 120.0] {
                KeyScope.postRecords(pid: pid, from: id, to: previousKey, settle: settle)
                KeyScope.awaitKey(pid: pid, target: previousKey, budgetMs: settle < 50 ? 150 : 300)
                if AX.focusedWindowID(pid) == previousKey { break }
            }
        }
        keyBack?()
        focusGuard.endSwap(pid)
        appLock.unlock()
        holdingInput = false
        // The app the user is in must end with their window key.
        if BCUFrontProcessPID() == pid { focusGuard.reclaimWhenSafe(pid) }
        if let ms = hold?.end() { Log.info("open_window: held the user's input \(Int(ms)) ms") }
        // Keep watching a moment in case the app moves or resizes the window back.
        sleepMs(250)
        catcher.stop()
        if assigned {
            _ = BCUProcessAssignToSpace(pid, 0)
            assigned = false
        }
        guard let id = caught else {
            if let key = unkeyedFullScreen, WindowList.info(key) != nil { KeyScope.postRecords(pid: pid, from: nil, to: key) }
            throw ToolError("\(name) didn't open a new window (tried \(how)). It may not support multiple windows: use list_windows with app=\"\(name)\" and borrow_window.")
        }
        // Give the app's key window back to whatever had it, so switching to
        // the app lands the user on their own window.
        if let key = unkeyedFullScreen, WindowList.info(key) != nil, AX.focusedWindowID(pid) != key {
            KeyScope.postRecords(pid: pid, from: nil, to: key)
        }
        let aw = AgentWindow(id: id, pid: pid, appName: name, bundleID: bundleID, kind: .opened)
        register(aw)
        notes.insert("opened with \(how)", at: 0)
        notes.append(catcher.flashReport)
        return OpenResult(window: aw, notes: notes)
    }

    /// The bundle id of an app that can be told where to build a new window
    /// (global points, top-left origin) before it shows it: Chromium
    /// browsers (`make new window with properties {bounds:…}`). Most apps'
    /// scripting (Finder's, TextEdit's) places a new window where it always
    /// would and applies the bounds after it's on screen, which is no better
    /// than moving it. Nil for those.
    static func scriptableBrowser(pid: pid_t, bundleID: String?) -> String? {
        guard let bundleID, let url = NSRunningApplication(processIdentifier: pid)?.bundleURL,
              BrowserAutomation.isScriptableChromium(url), mayScript(bundleID, app: url) else { return nil }
        return bundleID
    }

    /// The browser's own ids (`id of window` in its scripting) of windows it
    /// built when asked to, by window id.
    private static var browserIDs: [CGWindowID: String] = [:]

    static func noteBrowserID(_ id: String, of window: CGWindowID) {
        sharedLock.lock(); defer { sharedLock.unlock() }
        // (Window ids aren't reused while the Mac is up; this only keeps the
        // table from growing.)
        if browserIDs.count > 500 { browserIDs = browserIDs.filter { WindowList.info($0.key) != nil } }
        browserIDs[window] = id
    }

    static func browserID(of window: CGWindowID) -> String? {
        sharedLock.lock(); defer { sharedLock.unlock() }
        return browserIDs[window]
    }

    private static let askedLock = NSLock()
    private static var asked: Set<String> = []

    /// Whether this app may control the browser. When the user hasn't been
    /// asked (setup asks for their default browser), asks once in the
    /// background (the window being opened now goes the usual way) and says
    /// no for now.
    static func mayScript(_ bundleID: String, app: URL) -> Bool {
        switch BrowserAutomation.permission(bundleID) {
        case .allowed: return true
        case .denied: return false
        case .notAsked:
            askedLock.lock()
            let first = asked.insert(bundleID).inserted
            askedLock.unlock()
            if first {
                Log.info("asking to control \(bundleID), so its new windows can open on the agent display")
                BrowserAutomation.request(bundleID, app: app) { _ in }
            }
            return false
        }
    }

    /// A window of `pid` on an agent display to open the new window next to.
    private func anchorWindow(pid: pid_t) -> CGWindowID? {
        if let own = windows.first(where: { $0.pid == pid && !$0.handedOff && WindowList.info($0.id) != nil }) { return own.id }
        let displays = AgentDisplay.running.map(\.bounds)
        return WindowList.of(pid: pid, onScreenOnly: true).first { w in
            w.layer == 0 && w.bounds.width > 100 && w.bounds.height > 100
                && displays.contains { $0.contains(CGPoint(x: w.bounds.midX, y: w.bounds.midY)) }
        }?.id
    }

    struct MenuItemRef {
        let element: AXUIElement
        let title: String
    }

    /// The app's menu item for a new window (see `newWindowRank`).
    static func newWindowMenuItem(pid: pid_t) -> MenuItemRef? {
        guard let bar = AX.element(AX.app(pid), "AXMenuBar") else { return nil }
        var best: (rank: Int, item: MenuItemRef)?
        for top in AX.children(bar) {
            for menu in AX.children(top) {
                for item in AX.children(menu) {
                    let title = AX.string(item, "AXTitle") ?? ""
                    guard AX.bool(item, "AXEnabled") ?? true,
                          let rank = newWindowRank(title: title, key: AX.string(item, "AXMenuItemCmdChar") ?? "",
                                                   modifiers: (AX.attr(item, "AXMenuItemCmdModifiers") as? NSNumber)?.intValue ?? -1)
                    else { continue }
                    // A submenu ("New Window" in Terminal: one per profile):
                    // its cmd+N item, else its first one that names a window.
                    var ref = MenuItemRef(element: item, title: title)
                    let subitems = AX.children(item).flatMap { AX.children($0) }.filter { AX.bool($0, "AXEnabled") ?? true }
                    if !subitems.isEmpty {
                        let n = subitems.first { (AX.string($0, "AXMenuItemCmdChar") ?? "").uppercased() == "N" }
                            ?? subitems.first { (AX.string($0, "AXTitle") ?? "").lowercased().contains("window") }
                        guard let n else { continue }
                        ref = MenuItemRef(element: n, title: "\(title) > \(AX.string(n, "AXTitle") ?? "")")
                    }
                    if rank == 0 { return ref }
                    if best == nil || rank < best!.rank { best = (rank, ref) }
                }
            }
        }
        return best?.item
    }

    /// Whether a menu item opens a new window, best first: 0 "New Window"
    /// (or, in another language, an item naming a window with cmd+N: "Neues
    /// Fenster", "Nouvelle fenêtre"), 1 one that names a window ("New Finder
    /// Window", "New Viewer Window", or in another language with N as its
    /// key), 2 a document app's plain "New" (cmd+N, in the languages macOS
    /// ships in); nil for anything else. Not any cmd+N item: in many apps it
    /// makes something inside the window that has key, often the user's
    /// ("New Chat", "New Message" in Messages, "New Note", "New Event").
    static func newWindowRank(title: String, key: String, modifiers: Int) -> Int? {
        let lower = title.lowercased().trimmingCharacters(in: .whitespaces)
        if lower.isEmpty || privateWords.contains(where: lower.contains) { return nil }
        let cmdN = key.uppercased() == "N"
        if lower == "new window" { return 0 }
        let namesWindow = windowWords.contains(where: lower.contains)
        if namesWindow && cmdN && modifiers == 0 { return 0 }
        if lower.hasSuffix(" window") && (lower.hasPrefix("new ") || lower.hasPrefix("open ")) { return 1 }
        if namesWindow && cmdN { return 1 }
        if cmdN && modifiers == 0 && documentNew.contains(lower) { return 2 }
        return nil
    }

    /// "Window" in the languages macOS ships in.
    private static let windowWords = [
        "window", "fenster", "fenêtre", "ventana", "finestra", "janela", "venster", "fönster", "vindue", "vindu",
        "ikkuna", "okno", "okna", "окно", "вікно", "ablak", "fereastră", "prozor", "pencere", "παράθυρο", "חלון",
        "نافذة", "หน้าต่าง", "cửa sổ", "jendela", "tetingkap", "विंडो", "ウインドウ", "ウィンドウ", "窗口", "視窗", "윈도우",
    ]
    /// Private and incognito windows, which aren't the agent's to open.
    private static let privateWords = [
        "private", "incognito", "privé", "privat", "privad", "privat", "priva", "inkognito", "incógnito",
        "приват", "инкогнито", "プライベート", "シークレット", "无痕", "隐私", "隱私", "私密", "시크릿", "gizli",
    ]
    /// A document app's "New" and "New Document" in those languages.
    private static let documentNew: Set<String> = [
        "new", "new document", "neu", "neues dokument", "nouveau", "nouveau document", "nuevo", "nuevo documento",
        "nuovo", "nuovo documento", "novo", "novo documento", "nieuw", "nieuw document", "ny", "nytt dokument",
        "nyt dokument", "uusi", "uusi dokumentti", "nowy", "nowy dokument", "nový", "nový dokument", "новый",
        "новый документ", "новий", "новий документ", "új", "új dokumentum", "nou", "document nou", "novi", "yeni",
        "yeni belge", "νέο", "νέο έγγραφο", "חדש", "جديد", "ใหม่", "mới", "baru", "dokumen baru", "新規", "新規書類",
        "新建", "新建文稿", "新增", "新增文件", "새로 만들기", "신규",
    ]

    /// Move a window onto the agent display, keeping its size where it fits.
    @discardableResult
    func moveToAgent(_ window: AXUIElement, size: CGSize) -> Bool {
        moveToAgent(window, frame: nextFrame(size: size))
    }

    /// The next cascade position on the agent display for a window this size.
    func nextFrame(size: CGSize) -> CGRect {
        lock.lock()
        let slot = nextSlot
        nextSlot += 1
        lock.unlock()
        return display.slotFrame(size: size, slot: slot)
    }

    @discardableResult
    func moveToAgent(_ window: AXUIElement, frame: CGRect) -> Bool {
        let size = AX.size(window) ?? frame.size
        // Shrink first: AppKit puts a window that's too big for the agent
        // display back on a screen it fits, which is the user's.
        if size != frame.size { AX.setSize(window, frame.size) }
        let ok = AX.setPosition(window, frame.origin)
        // Some apps clamp the first move; check and retry once.
        if let p = AX.position(window), !display.bounds.contains(p) {
            if let s = AX.size(window), s != frame.size { AX.setSize(window, frame.size) }
            AX.setPosition(window, frame.origin)
        }
        return ok
    }

    // MARK: Borrow, release, handoff

    public func borrow(_ id: CGWindowID) throws -> AgentWindow {
        if let existing = window(id) { return existing }
        guard let info = WindowList.info(id) else { throw ToolError("no window \(id)") }
        guard let ax = AX.window(pid: info.pid, id: id) else { throw ToolError("window \(id) isn't reachable through accessibility") }
        let original = AX.frame(ax) ?? info.bounds
        let app = NSRunningApplication(processIdentifier: info.pid)
        if Self.isRegistered(id, byOtherThan: sessionKey) { throw ToolError("window \(id) is another agent's") }
        // Every other window of the app is the user's, not one this spawned.
        noteBefore(pid: info.pid)
        focusGuard.beginAction(pid: info.pid, cause: "borrowing a window")
        defer { focusGuard.endAction(pid: info.pid) }
        moveToAgent(ax, size: original.size)
        let aw = AgentWindow(id: id, pid: info.pid, appName: app?.localizedName ?? info.owner, bundleID: app?.bundleIdentifier, kind: .borrowed, originalFrame: original)
        register(aw)
        return aw
    }

    public func release(_ id: CGWindowID, keepOpen: Bool) throws -> String {
        guard let w = window(id) else { throw ToolError("window \(id) isn't one of yours") }
        guard let ax = AX.window(pid: w.pid, id: id) else {
            // (Gone only if the window server says so: see `Engine.agentWindow`.)
            if WindowList.info(id) == nil {
                unregister(id)
                return "window \(id) is already gone"
            }
            throw ToolError("\(w.appName) isn't answering right now, so window \(id) is still open. It may be showing a dialog that has to be answered first (list_windows shows a dialog of yours). Try again in a moment.")
        }
        focusGuard.unpark(w.pid, window: id, reason: "window released")
        noteBefore(pid: w.pid)
        focusGuard.beginAction(pid: w.pid, cause: "releasing a window")
        defer { focusGuard.endAction(pid: w.pid) }
        switch w.kind {
        case .borrowed:
            if let f = w.originalFrame {
                AX.setPosition(ax, f.origin)
                AX.setSize(ax, f.size)
            }
            unregister(id)
            Self.returnedToUser(id)
            return "returned window \(id) to where it was"
        case .opened, .caught:
            if keepOpen {
                // Kept open for the user to see: on their screen, since
                // nothing brings it off this display later (and a spare
                // display with a window on it is never removed).
                Self.keep(id)
                lock.lock(); seenOnUser[id] = -1; spawnedAfter[id] = nil; lock.unlock()
                unregister(id)
                if w.withUser { return "left window \(id) open on the user's screen" }
                let moved = WindowList.info(id).map { Self.putOnUserScreen(ax, bounds: $0.bounds) } ?? false
                return moved ? "left window \(id) open and moved it to the user's screen" : "left window \(id) open"
            }
            let before = Set(AX.windows(w.pid).compactMap { AX.windowID($0) })
            let onScreenBefore = Set(WindowList.of(pid: w.pid).map(\.id))
            if let close = AX.element(ax, "AXCloseButton") {
                AX.perform(close, "AXPress")
            } else {
                AX.perform(ax, "AXCancel")
            }
            // A page can ask whether to leave it ("Leave site?"), in a dialog
            // that comes up on the user's screen. The agent asked to close
            // its own window, so the answer is yes, given the moment the
            // dialog shows rather than when the wait runs out: it's gone
            // from their screen within a frame or two.
            var asked: String?
            var looked: Set<CGWindowID> = []
            func closed(withinMs ms: Double) -> Bool {
                let deadline = nowMs() + ms
                while WindowList.info(id) != nil && nowMs() < deadline {
                    for info in WindowList.of(pid: w.pid, onScreenOnly: true)
                    where info.layer <= 8 && !onScreenBefore.contains(info.id) && !looked.contains(info.id) {
                        // (Not in accessibility yet: look again next time round.)
                        guard let dialog = AX.window(pid: w.pid, id: info.id) else { continue }
                        looked.insert(info.id)
                        let said = Self.texts(in: dialog).joined(separator: " ")
                        if Self.answerLeave(dialog) { asked = said }
                    }
                    sleepMs(10)
                }
                return WindowList.info(id) == nil
            }
            if closed(withinMs: 1500) {
                unregister(id)
                for other in windows where other.kind == .caught && WindowList.info(other.id) == nil { unregister(other.id) }
                if let asked { return "closed window \(id) (the page asked \"\(asked)\"; answered Leave)" }
                return "closed window \(id)"
            }
            // The app asked before closing, in a window of its own that can
            // be anywhere (Chromium's "Leave site?" comes up on the user's
            // screen). Left unanswered it holds the app's key window, so no
            // agent's keys reach the app and no window of it closes.
            for dialog in dialogs(pid: w.pid, notIn: before) {
                let said = Self.texts(in: dialog.ax)
                let buttons = Self.buttons(in: dialog.ax)
                // A page asking whether to leave it: the agent asked to
                // close its own window, so yes.
                if Self.answerLeave(dialog.ax) {
                    if closed(withinMs: 1500) {
                        unregister(id)
                        if window(dialog.id) != nil { unregister(dialog.id) }
                        return "closed window \(id) (the page asked \"\(said.joined(separator: " "))\"; answered Leave)"
                    }
                    continue
                }
                // Anything else is the agent's to answer: put it where the agent looks.
                let frame = WindowList.info(id)?.bounds ?? display.bounds
                let size = AX.size(dialog.ax) ?? CGSize(width: 400, height: 300)
                AX.setPosition(dialog.ax, CGPoint(x: frame.midX - size.width / 2, y: frame.minY + 80))
                if window(dialog.id) == nil {
                    register(AgentWindow(id: dialog.id, pid: w.pid, appName: w.appName, bundleID: w.bundleID, kind: .caught))
                }
                return "window \(id) didn't close: \(w.appName) is asking \"\(said.joined(separator: " "))\" (\(buttons.map(\.title).joined(separator: " / "))). The dialog is over window \(id) on your display now: get_window_state window_id=\(id) lists its buttons. Press one, then release again."
            }
            return "window \(id) didn't close. A dialog may be asking something (unsaved changes?): check get_window_state, answer it, then release again."
        }
    }

    /// Windows of `pid` that aren't ordinary ones (dialogs, alerts) and
    /// could be asking about a window of this session's: ones that weren't
    /// there `before`, and ones this session's watchdog already caught (it
    /// can get to a new dialog first). Never another session's.
    private func dialogs(pid: pid_t, notIn before: Set<CGWindowID>) -> [(ax: AXUIElement, id: CGWindowID)] {
        AX.windows(pid).compactMap { ax in
            guard let wid = AX.windowID(ax), AX.string(ax, "AXSubrole") != "AXStandardWindow",
                  !Self.isRegistered(wid, byOtherThan: sessionKey),
                  !before.contains(wid) || window(wid)?.kind == .caught else { return nil }
            return (ax, wid)
        }
    }

    private static func walk(_ el: AXUIElement, depth: Int = 0, _ visit: (AXUIElement, String) -> Void) {
        guard depth < 8 else { return }
        visit(el, AX.string(el, "AXRole") ?? "")
        for child in AX.children(el) { walk(child, depth: depth + 1, visit) }
    }

    static func buttons(in el: AXUIElement) -> [(title: String, element: AXUIElement)] {
        var out: [(String, AXUIElement)] = []
        walk(el) { e, role in
            if role == "AXButton", let t = AX.string(e, "AXTitle"), !t.isEmpty { out.append((t, e)) }
        }
        return out
    }

    /// A small dialog asking whether to leave a page (Chromium's "Leave
    /// site?", with Leave and Cancel): press Leave. Only ever for a window
    /// known to be an agent's (a session's own, or on an agent display),
    /// about a window the agent is done with.
    @discardableResult
    static func answerLeave(_ dialog: AXUIElement) -> Bool {
        let found = buttons(in: dialog)
        guard found.count <= 4, let leave = found.first(where: { $0.title == "Leave" }),
              found.contains(where: { $0.title == "Cancel" }) else { return false }
        return AX.perform(leave.element, "AXPress") == .success
    }

    static func texts(in el: AXUIElement) -> [String] {
        var out: [String] = []
        walk(el) { e, role in
            if role == "AXStaticText", let t = AX.string(e, "AXValue"), !t.isEmpty, out.count < 4 { out.append(String(t.prefix(160))) }
        }
        return out
    }

    private static let leftoverLock = NSLock()

    /// Windows on a display that nobody should have left there: ordinary
    /// ones and dialogs, of any app but this one.
    /// When each window was first seen on a spare display (see `rescue`).
    nonisolated(unsafe) private static var seenOnSpare: [CGWindowID: Double] = [:]

    /// A display kept as a spare has no agent and nothing sweeping it, but
    /// apps still open new windows where their last one was: a window the
    /// user opens in an app an agent used can land there, where they can't
    /// see it (and it would be closed with the display later). One that's
    /// new there, a standard window, from the app the user is in, is
    /// theirs: put it on their screen, as `sweep` does for a display in use.
    /// Asked every second while there are spares; done off the caller's
    /// thread (it asks the app over accessibility, which can take a while).
    static func rescue(fromSpares spares: [CGRect]) {
        rescueQueue.async { rescueNow(fromSpares: spares) }
    }

    private static let rescueQueue = DispatchQueue(label: "bcu.spare-rescue", qos: .utility)

    private static func rescueNow(fromSpares spares: [CGRect]) {
        guard !spares.isEmpty, let guardian = FocusGuard.shared else {
            if !seenOnSpare.isEmpty { seenOnSpare = [:] }
            return
        }
        let front = BCUFrontProcessPID()
        let now = nowMs()
        let there = WindowList.all(onScreenOnly: true).filter { info in
            info.layer == 0 && spares.contains { $0.contains(CGPoint(x: info.bounds.midX, y: info.bounds.midY)) }
        }
        seenOnSpare = seenOnSpare.filter { id, _ in there.contains { $0.id == id } }
        for info in there where !isRegistered(info.id) && !isOpening(info.pid) {
            let firstSeen = seenOnSpare[info.id] ?? now
            if seenOnSpare[info.id] == nil { seenOnSpare[info.id] = firstSeen }
            // Judged for a few seconds from when it shows up (this looks
            // once a second, and the guard learns the user's app a moment
            // after it changes); what was there before isn't touched.
            guard now - firstSeen < 3000, info.pid == front, info.pid == guardian.userFront,
                  info.bounds.width > 100, info.bounds.height > 100,
                  let ax = AX.window(pid: info.pid, id: info.id),
                  AX.string(ax, "AXSubrole") == "AXStandardWindow" else { continue }
            let main = CGDisplayBounds(CGMainDisplayID())
            let w = min(info.bounds.width, main.width - 80), h = min(info.bounds.height, main.height - 120)
            AX.setPosition(ax, CGPoint(x: main.midX - w / 2, y: main.midY - h / 2))
            AX.setSize(ax, CGSize(width: w, height: h))
            seenOnSpare[info.id] = -1e12
            guardian.record("moved a new \(info.owner) window you opened from a spare agent display to your screen")
        }
    }

    static func windows(on bounds: CGRect) -> [WindowInfo] {
        guard !bounds.isEmpty else { return [] }
        return WindowList.all(onScreenOnly: true).filter { w in
            w.pid != getpid() && w.layer >= 0 && w.layer <= 8 && w.alpha > 0 && w.bounds.width > 40 && w.bounds.height > 40
                && bounds.contains(CGPoint(x: w.bounds.midX, y: w.bounds.midY)) && w.owner != "Window Server" && w.owner != "Dock"
        }
    }

    /// Windows an agent released with `keep_open`, and others put on the
    /// user's screen from an agent display: theirs now. Never closed or
    /// answered for, and no session catches them again.
    private static let keptLock = NSLock()
    private static var keptOpen: Set<CGWindowID> = []
    static func keep(_ id: CGWindowID) { keptLock.lock(); keptOpen.insert(id); keptLock.unlock() }
    static func isKept(_ id: CGWindowID) -> Bool { keptLock.lock(); defer { keptLock.unlock() }; return keptOpen.contains(id) }
    /// A session has the window again (`register`): not kept any more, so
    /// its sweep looks after it.
    static func ownedAgain(_ id: CGWindowID) { keptLock.lock(); keptOpen.remove(id); keptLock.unlock() }
    /// A borrowed window went back to the user (`release`): theirs again,
    /// so kept, as one released with `keep_open` is. It may have been
    /// opened by an agent (and kept) before it was borrowed, and cleanup
    /// mustn't close it.
    static func returnedToUser(_ id: CGWindowID) { keep(id) }

    /// What cleanup does with a window nobody has left on an agent display:
    /// close one an agent opened or caught (and didn't keep open); put any
    /// other on the user's screen. It may be theirs (a window an app opened
    /// where its last one was, or every window macOS moved there when a
    /// display was unplugged), and closing it could lose their work.
    enum LeftoverFate: Equatable { case close, giveToUser }
    static func leftoverFate(_ id: CGWindowID, agentMade: Bool, kept: Set<CGWindowID>) -> LeftoverFate {
        agentMade && !kept.contains(id) ? .close : .giveToUser
    }

    /// Center a window on the user's main display, shrunk to fit (shrunk
    /// first, so AppKit doesn't push it back to a screen it fits).
    @discardableResult
    static func putOnUserScreen(_ ax: AXUIElement, bounds: CGRect) -> Bool {
        guard let target = userScreen(main: CGMainDisplayID(), users: AgentDisplay.userDisplayIDs()) else { return false }
        let main = CGDisplayBounds(target)
        let w = min(bounds.width, main.width - 80), h = min(bounds.height, main.height - 120)
        AX.setSize(ax, CGSize(width: w, height: h))
        return AX.setPosition(ax, CGPoint(x: (main.midX - w / 2).rounded(), y: (main.midY - h / 2).rounded()))
    }

    /// The display `putOnUserScreen` puts a window on: the main one, unless
    /// that's an agent's (with the user's displays asleep, macOS can make
    /// one main), then another of the user's. None: the window stays.
    static func userScreen(main: CGDirectDisplayID, users: [CGDirectDisplayID]) -> CGDirectDisplayID? {
        users.contains(main) ? main : users.first
    }

    /// One stray rescue queued or running at a time (`rescue(fromStrays:)`):
    /// one can wait on an app that isn't answering for longer than the
    /// second between asks, and they'd pile up ahead of spare rescues.
    private static let strayTurnLock = NSLock()
    private static var strayTurnTaken = false
    static func takeStrayTurn() -> Bool {
        strayTurnLock.lock(); defer { strayTurnLock.unlock() }
        if strayTurnTaken { return false }
        strayTurnTaken = true
        return true
    }
    static func endStrayTurn() { strayTurnLock.lock(); strayTurnTaken = false; strayTurnLock.unlock() }

    /// Clean up what's left on a display no agent is using any more: when
    /// the display goes, macOS moves every window on it to the user's
    /// screen. Returns how many are still there. Not on the main thread.
    @discardableResult
    static func closeLeftovers(on bounds: CGRect) -> Int {
        // One sweep at a time: each can wait a second or two on an app.
        guard leftoverLock.try() else { return windows(on: bounds).count }
        defer { leftoverLock.unlock() }
        keptLock.lock(); let kept = keptOpen; keptLock.unlock()
        // Not a window some session has: it's on this display for a moment
        // (macOS put it here, or it's being taken over), and its session
        // moves it to its own. It counts as left, so the display stays
        // until it's gone.
        let found = windows(on: bounds).filter { !isRegistered($0.id) }
            .compactMap { info in AX.window(pid: info.pid, id: info.id).map { (info, $0) } }
        let present = Set(found.map(\.0.id))
        let toClose = found.filter { leftoverFate($0.0.id, agentMade: wasAgentMade($0.0.id), kept: kept) == .close }
        for (info, ax) in found where !toClose.contains(where: { $0.0.id == info.id }) {
            keep(info.id)
            putOnUserScreen(ax, bounds: info.bounds)
            // (Told once: one that won't move is tried again next time.)
            guard !kept.contains(info.id) else { continue }
            Log.info("moved \(info.owner) window \(info.id) from an agent display to the user's screen")
            FocusGuard.shared?.record("moved a \(info.owner) window from an agent display to your screen")
        }
        // Dialogs first: one that's asking about a window keeps it open.
        for (_, ax) in toClose where answerLeave(ax) { sleepMs(400) }
        for (info, ax) in toClose where WindowList.info(info.id) != nil {
            if let close = AX.element(ax, "AXCloseButton") { AX.perform(close, "AXPress") } else { AX.perform(ax, "AXCancel") }
            let deadline = nowMs() + 1200
            while WindowList.info(info.id) != nil && nowMs() < deadline { sleepMs(50) }
        }
        // A page that only now asks whether to leave, about a window closed
        // here: nobody is left to say no.
        if !toClose.isEmpty {
            for info in windows(on: bounds) where !isRegistered(info.id) && !present.contains(info.id) {
                if let ax = AX.window(pid: info.pid, id: info.id), answerLeave(ax) { sleepMs(400) }
            }
        }
        let left = windows(on: bounds)
        if !left.isEmpty {
            Log.info("leftover windows on an agent display are still there: \(left.map { "\($0.owner) \($0.id) \"\($0.title.prefix(30))\"" }.joined(separator: ", "))")
        }
        return left.count
    }

    /// Windows on BCU displays a crashed copy left (see
    /// `AgentDisplay.strayIDs`): the user can't see or reach them, and
    /// nobody else will move them. Put them on the user's screen (once the
    /// last run's own windows are closed, see `recoverFromPreviousRun`).
    /// Done off the caller's thread.
    static func rescue(fromStrays strays: [CGRect]) {
        guard !strays.isEmpty, takeStrayTurn() else { return }
        rescueQueue.async {
            defer { endStrayTurn() }
            let users = AgentDisplay.userDisplayIDs().map { CGDisplayBounds($0) }
            for bounds in strays {
                for info in windows(on: bounds) where !isRegistered(info.id) && !isOpening(info.pid)
                    && strandedOnStray(info.bounds, userDisplays: users) {
                    guard let ax = AX.window(pid: info.pid, id: info.id) else { continue }
                    let first = !isKept(info.id)
                    guard claimForRescue(info.id, registered: isRegistered) else { continue }
                    putOnUserScreen(ax, bounds: info.bounds)
                    guard first else { continue }
                    Log.info("moved \(info.owner) window \(info.id) from a display a crashed copy left to the user's screen")
                    FocusGuard.shared?.record("moved a \(info.owner) window from a leftover agent display to your screen")
                }
            }
        }
    }

    /// Mark a window on a stray display kept, for the user, before moving
    /// it there. False: don't move it, a session has it since the rescue
    /// picked it (it may have waited on the app for a while).
    static func claimForRescue(_ id: CGWindowID, registered: (CGWindowID) -> Bool) -> Bool {
        guard !registered(id) else { return false }
        keep(id)
        return true
    }

    /// Whether a window on a stray display is stranded there. A stray
    /// macOS left on top of a user display (see `AgentDisplay.tend`) holds
    /// windows the user can see: those stay where they are.
    static func strandedOnStray(_ bounds: CGRect, userDisplays: [CGRect]) -> Bool {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        return !userDisplays.contains { $0.contains(center) }
    }

    /// The window stays on the agent display until the user asks for it
    /// (`bringToUser`), so nothing appears on their screen unasked.
    public func handoff(_ id: CGWindowID, reason: String) throws {
        guard let w = window(id), AX.window(pid: w.pid, id: id) != nil else { throw ToolError("window \(id) isn't one of yours") }
        focusGuard.unpark(w.pid, window: id, reason: "window handed to the user")
        w.handedOff = true
        w.handoffReason = reason
        w.withUser = false
    }

    /// The user asked for a handed-off window: center it on `area` (global
    /// points, top-left origin) and make it the front window.
    public func bringToUser(_ id: CGWindowID, area: CGRect) throws {
        guard let w = window(id), w.handedOff, let ax = AX.window(pid: w.pid, id: id) else { throw ToolError("window \(id) isn't handed off") }
        if !w.withUser {
            let size = AX.size(ax) ?? CGSize(width: 1000, height: 700)
            let w2 = min(size.width, area.width - 80), h2 = min(size.height, area.height - 80)
            // Shrink first, so AppKit doesn't push it back to a screen it fits.
            AX.setSize(ax, CGSize(width: w2, height: h2))
            AX.setPosition(ax, CGPoint(x: (area.midX - w2 / 2).rounded(), y: (area.midY - h2 / 2).rounded()))
            w.withUser = true
        }
        // The user asked for it, so it takes the front.
        focusGuard.noteUserSwitch()
        _ = BCUSetFrontProcess(w.pid, id, 0x200)
        // The make-key records once the app is active (see `FocusGuard.makeKeyAgain`).
        let deadline = nowMs() + 400
        while BCUFrontProcessPID() != w.pid && nowMs() < deadline { sleepMs(2) }
        sleepMs(FocusGuard.activationSettleMs)
        _ = BCUPostMakeKeyRecords(w.pid, id)
        AX.perform(ax, "AXRaise")
    }

    public func takeBack(_ id: CGWindowID) throws {
        guard let w = window(id), let ax = AX.window(pid: w.pid, id: id) else { throw ToolError("window \(id) isn't one of yours") }
        let wasWithUser = w.withUser
        w.handedOff = false
        w.handoffReason = nil
        w.withUser = false
        if wasWithUser { moveToAgent(ax, size: AX.size(ax) ?? CGSize(width: 1200, height: 800)) }
    }

    /// Close opened windows and return borrowed ones.
    public func releaseAll() -> [String] {
        windows.map { (try? release($0.id, keepOpen: false)) ?? "window \($0.id): failed" }
    }

    // MARK: Watchdog

    func noteBefore(pid: pid_t) {
        let ids = Set(WindowList.of(pid: pid).map(\.id))
        lock.lock(); knownBefore[pid] = (ids, nowMs()); lock.unlock()
    }

    func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            DispatchQueue.global(qos: .userInitiated).async { self?.sweep() }
        }
    }

    private var sweeping = false
    /// The user is moving and resizing windows from the expanded view, so
    /// don't fit them back inside the display. Apps also round a size by a
    /// point or two, so a window just past the edge is left alone.
    public var userArranging = false
    /// Windows the user moved or resized from the expanded view. They stay
    /// where the user put them, even hanging off an edge.
    private var userPlaced: Set<CGWindowID> = []

    public func noteUserPlaced(_ id: CGWindowID) {
        lock.lock(); userPlaced.insert(id); lock.unlock()
    }
    private var fitTries: [CGWindowID: (count: Int, lastMs: Double)] = [:]
    private var seenOnAgent: [CGWindowID: Double] = [:]
    /// When a new window in an app this session acted on was first seen on
    /// the user's screen; -1 once judged.
    private var seenOnUser: [CGWindowID: Double] = [:]
    /// For a window first seen on this display that wasn't there when this
    /// session's last step on its app began: when that step began.
    private var spawnedAfter: [CGWindowID: Double] = [:]

    /// Shrink and shift an agent window that sticks out past the agent
    /// display's edge (apps can undo the first resize while a new window
    /// settles, or animate from their old size). Tries at most every 300 ms,
    /// so an animation can finish, and gives up after 5 tries so an app that
    /// refuses isn't resized every sweep.
    private func fitInside(_ w: AgentWindow, frame: CGRect) {
        lock.lock()
        if userPlaced.contains(w.id) { lock.unlock(); return }
        let prior = fitTries[w.id] ?? (0, -1e12)
        let due = prior.count < 5 && nowMs() - prior.lastMs >= 300
        if due { fitTries[w.id] = (prior.count + 1, nowMs()) }
        lock.unlock()
        guard due, let ax = AX.window(pid: w.pid, id: w.id) else { return }
        let b = display.bounds
        let inset: CGFloat = 24
        let size = CGSize(width: min(frame.width, b.width - inset * 2), height: min(frame.height, b.height - inset * 2 - 30))
        let x = min(max(frame.minX, b.minX + inset), b.maxX - inset - size.width)
        let y = min(max(frame.minY, b.minY + inset + 30), b.maxY - inset - size.height)
        if size != frame.size { AX.setSize(ax, size) }
        AX.setPosition(ax, CGPoint(x: x, y: y))
        Log.info("fit \(w.appName) window \(w.id) from \(frame.short) to \(Int(x)),\(Int(y)) \(Int(size.width))x\(Int(size.height))")
    }
    private var opening: Set<pid_t> = []
    /// A window a step opened on this display becomes the session's once
    /// it's been there this long, and is no longer looked at after
    /// `agentJudgeMs`.
    private static let agentSettleMs = 400.0
    private static let agentJudgeMs = 5000.0

    /// Whether the sweep still treats a window in its copy of the registry
    /// as the session's. One released since the copy (kept open and moved
    /// to the user's screen, or closing) isn't: moving it back would leave
    /// it on the agent display with nobody to bring it off.
    static func sweepStillOwns(registeredNow: Bool, kept: Bool) -> Bool { registeredNow && !kept }

    /// Keep agent windows off the user's displays and catch new windows an
    /// agent action spawned there (dialogs, popups, extra windows).
    private func sweep() {
        lock.lock()
        if sweeping { lock.unlock(); return }
        sweeping = true
        let agent = registry
        lock.unlock()
        defer { lock.lock(); sweeping = false; lock.unlock() }
        guard display.isRunning else { return }

        let onScreen = WindowList.all(onScreenOnly: true)

        // Reverse catch: apps place new windows next to their last window, so
        // after the agent used an app, a window the USER opens in it can land on
        // the agent display. A new, unregistered window there, from the app the
        // user is in, is theirs: move it to their screen.
        let front = BCUFrontProcessPID()
        for info in onScreen where info.layer == 0 && agent[info.id] == nil && display.holds(info.bounds) {
            // Asked afresh, and in this order: `agent` is from the start of
            // this sweep, and an open that finished since has registered its
            // window before saying it's done. Reading the older copy and the
            // newer flag took an agent's new window for one the user opened,
            // and put it on their screen.
            lock.lock(); let mine = opening.contains(info.pid); lock.unlock()
            if mine || Self.isOpening(info.pid) || Self.isRegistered(info.id) || Self.isKept(info.id) { continue }
            // Judge each new window for 1.5 s: the guard learns the user's front
            // app a moment after it changes.
            lock.lock()
            let firstSeen = seenOnAgent[info.id] ?? nowMs()
            if seenOnAgent[info.id] == nil {
                seenOnAgent[info.id] = firstSeen
                // What this session was doing in the app when it showed up
                // (the next step's note of the app's windows will include it).
                if let known = knownBefore[info.pid], !known.ids.contains(info.id) { spawnedAfter[info.id] = known.ms }
            }
            let agentBegan = spawnedAfter[info.id]
            lock.unlock()
            // "The user is in this app": WindowServer's front app is it AND the
            // guard counts it as the user's (not a self-activation it's undoing).
            // Only standard windows: popups the agent's own window opens
            // (suggestion lists, menus) are separate windows too.
            let age = nowMs() - firstSeen
            guard age < Self.agentJudgeMs, info.bounds.width > 100, info.bounds.height > 100 else { continue }
            let cause = NewWindow.cause(NewWindow.Facts(
                firstSeenMs: firstSeen, userInApp: info.pid == front && info.pid == focusGuard.userFront,
                userOpenInputMs: focusGuard.lastUserOpenInputMs, agentBeganMs: agentBegan))
            if cause == .agent {
                // What this session's step opened (a sign-in popup, a second
                // window) is the session's: its agent finds it in
                // list_windows, and it's closed with the rest. Not in its
                // first moments: the guard may not know yet that the user
                // just came to the app.
                guard age >= Self.agentSettleMs, let ax = AX.window(pid: info.pid, id: info.id),
                      ["AXStandardWindow", "AXDialog", "AXSystemDialog"].contains(AX.string(ax, "AXSubrole") ?? "") else { continue }
                let app = NSRunningApplication(processIdentifier: info.pid)
                register(AgentWindow(id: info.id, pid: info.pid, appName: app?.localizedName ?? info.owner, bundleID: app?.bundleIdentifier, kind: .caught))
                lock.lock(); seenOnAgent[info.id] = -1e12; lock.unlock()
                Log.info("session \(sessionKey.prefix(8)): \(info.owner) window \(info.id) came up on the agent display after this session's step in that app; it's the session's now")
                continue
            }
            guard cause == .user, age < 1500,
                  let ax = AX.window(pid: info.pid, id: info.id),
                  AX.string(ax, "AXSubrole") == "AXStandardWindow" else { continue }
            let main = CGDisplayBounds(CGMainDisplayID())
            let w = min(info.bounds.width, main.width - 80), h = min(info.bounds.height, main.height - 120)
            AX.setPosition(ax, CGPoint(x: main.midX - w / 2, y: main.midY - h / 2))
            AX.setSize(ax, CGSize(width: w, height: h))
            lock.lock(); seenOnAgent[info.id] = -1e12; lock.unlock()
            focusGuard.record("moved a new \(info.owner) window you opened from the agent display to your screen")
        }

        // Up to the modal-panel level: an alert the app raises (Chromium's
        // "Leave site?", a save or permission dialog) sits above ordinary
        // windows, comes up on the user's screen, and takes the app's key
        // window. Missed, it stays there, and every agent in the app is stuck.
        for info in onScreen where info.layer >= 0 && info.layer <= 8 {
            if let w = agent[info.id] {
                // `agent` is from the start of this sweep: asked afresh.
                lock.lock(); let registeredNow = registry[info.id] != nil; lock.unlock()
                guard Self.sweepStillOwns(registeredNow: registeredNow, kept: Self.isKept(info.id)) else { continue }
                if !w.handedOff && display.touchesUser(info.bounds) && !display.holds(info.bounds),
                   let ax = AX.window(pid: w.pid, id: w.id) {
                    moveToAgent(ax, size: info.bounds.size)
                    focusGuard.record("moved your agent's \(w.appName) window back off your display")
                } else if !w.handedOff && !userArranging && !display.bounds.insetBy(dx: -8, dy: -8).contains(info.bounds) {
                    fitInside(w, frame: info.bounds)
                }
                continue
            }
            lock.lock()
            let midOpen = opening.contains(info.pid) || Self.isOpening(info.pid)
            lock.unlock()
            guard !midOpen, !Self.isRegistered(info.id, byOtherThan: sessionKey), !Self.isKept(info.id),
                  display.touchesUser(info.bounds), !display.holds(info.bounds),
                  info.bounds.width > 40, info.bounds.height > 40 else { continue }
            // Only windows that appeared since this session began acting on
            // the app (another session's action, or none on record, says
            // nothing about which windows are new), and never another
            // session's window. Noted when first seen: the session's next
            // step notes the app's windows again, this one among them.
            lock.lock()
            if seenOnUser[info.id] == nil, let known = knownBefore[info.pid] {
                seenOnUser[info.id] = nowMs()
                if !known.ids.contains(info.id) { spawnedAfter[info.id] = known.ms }
            }
            let firstSeen = seenOnUser[info.id], agentBegan = spawnedAfter[info.id]
            lock.unlock()
            guard let firstSeen, firstSeen > 0, agentBegan != nil else { continue }
            let userInApp = info.pid == front && info.pid == focusGuard.userFront
            guard let cause = NewWindow.fromUserScreen(NewWindow.Facts(
                firstSeenMs: firstSeen, userInApp: userInApp,
                userOpenInputMs: focusGuard.lastUserOpenInputMs, agentBeganMs: agentBegan), nowMs: nowMs()) else { continue }
            // Judged once: a window the user's input explains stays theirs.
            // The step's is looked at again until accessibility answers (an
            // app can be busy while it shows a dialog), for at most
            // `agentJudgeMs`.
            func retire() { lock.lock(); seenOnUser[info.id] = -1; lock.unlock() }
            guard cause == .agent, nowMs() - firstSeen < Self.agentJudgeMs else { retire(); continue }
            guard let ax = AX.window(pid: info.pid, id: info.id) else { continue }
            // In the app the user is in, only whole windows and dialogs: a
            // browser's hover cards and bubbles over their window are
            // windows too.
            if userInApp {
                guard let subrole = AX.string(ax, "AXSubrole") else { continue }
                guard ["AXStandardWindow", "AXDialog", "AXSystemDialog"].contains(subrole) else { retire(); continue }
            }
            // A dialog goes over the window it's about (where the agent
            // will find it listed with that window's elements), another
            // window to the next free place.
            let dialog = info.layer > 0 || AX.string(ax, "AXSubrole") != "AXStandardWindow"
            if dialog, let about = agent.values.filter({ $0.pid == info.pid && !$0.handedOff }).compactMap({ WindowList.info($0.id)?.bounds }).first {
                AX.setPosition(ax, CGPoint(x: about.midX - info.bounds.width / 2, y: about.minY + 80))
            } else {
                moveToAgent(ax, size: info.bounds.size)
            }
            let app = NSRunningApplication(processIdentifier: info.pid)
            register(AgentWindow(id: info.id, pid: info.pid, appName: app?.localizedName ?? info.owner, bundleID: app?.bundleIdentifier, kind: .caught))
            focusGuard.record("caught a new \(app?.localizedName ?? info.owner) \(dialog ? "dialog" : "window") on your display and moved it to the agent display")
        }

        lock.lock()
        let now = nowMs()
        let ids = registry.keys.filter { now - (registeredAt[$0] ?? 0) >= Self.newWindowGraceMs }
        lock.unlock()
        for id in ids where WindowList.info(id) == nil { unregister(id) }
    }
}

/// Watches one app while it opens a window: catches the new window through an
/// AXObserver the moment it's created, moves it to the agent display, and
/// measures whether (and for how long) it was ever on the user's displays.
final class WindowCatcher {
    let pid: pid_t
    let before: Set<CGWindowID>
    weak var manager: WindowManager?

    private let lock = NSLock()
    private var caughtID: CGWindowID?
    private var observer: AXObserver?
    private var polling = false
    private var startMs = 0.0
    private var firstSeenMs: Double?
    /// Runs (on the polling thread) when the new window is first on screen.
    /// Not on accessibility's "created": that comes before the window is
    /// shown (a browser, ~250 ms), and a window that isn't shown can't take key.
    var onSeen: (() -> Void)?
    private var firstOnUserMs: Double?
    private var lastOnUserMs: Double?
    private var movedMs: Double?
    /// Move attempts per window: how many, and when the last one ended.
    private var moved: [CGWindowID: (count: Int, lastMs: Double)] = [:]
    /// Where the new window goes; the same frame for every retry.
    private var target: CGRect?

    init(pid: pid_t, before: Set<CGWindowID>, manager: WindowManager) {
        self.pid = pid
        self.before = before
        self.manager = manager
    }

    func start() {
        startMs = nowMs()
        polling = true
        // Not while BCU quits (see `onMainUnlessQuitting`): then polling alone catches the window.
        onMainUnlessQuitting {
            var obs: AXObserver?
            guard AXObserverCreate(self.pid, catcherCallback, &obs) == .success, let obs else { return }
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            AXObserverAddNotification(obs, AX.app(self.pid), kAXWindowCreatedNotification as CFString, refcon)
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
            self.observer = obs
        }
        let thread = Thread { [weak self] in self?.poll() }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Safe to call twice.
    func stop() {
        polling = false
        if let obs = observer {
            observer = nil
            // Without waiting for the main thread, which may be waiting on
            // this one (quitting). It holds the catcher until then, and
            // `created` ignores the window from now on.
            DispatchQueue.main.async {
                AXObserverRemoveNotification(obs, AX.app(self.pid), kAXWindowCreatedNotification as CFString)
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
            }
        }
    }

    /// AXObserver path: runs on the main thread right after the window is created.
    fileprivate func created(_ element: AXUIElement) {
        guard polling, let id = AX.windowID(element), !before.contains(id), !WindowManager.isRegistered(id) else { return }
        catchWindow(id: id, element: element)
    }

    private func catchWindow(id: CGWindowID, element: AXUIElement) {
        lock.lock()
        // Only the one window asked for: another new window of the app
        // while this one settles is the user's (or the app's own), not this.
        if !Self.mayMove(id, caught: caughtID) { lock.unlock(); return }
        if caughtID == nil { caughtID = id }
        // Apps can reset a new window's position just after creating it,
        // undoing the move, so a window still on the user's screen is moved
        // again, every 30 ms, up to 10 times.
        if let m = moved[id], m.count >= 10 || nowMs() - m.lastMs < 30 || m.lastMs == 0 { lock.unlock(); return }
        let count = (moved[id]?.count ?? 0) + 1
        moved[id] = (count, 0)  // 0: a move is in progress
        lock.unlock()
        if target == nil {
            target = manager?.nextFrame(size: AX.size(element) ?? CGSize(width: 1200, height: 800))
        }
        if let target { manager?.moveToAgent(element, frame: target) }
        lock.lock()
        moved[id] = (count, nowMs())
        if movedMs == nil { movedMs = nowMs() }
        lock.unlock()
    }

    /// Whether the catcher may move window `id`, having caught `caught`.
    static func mayMove(_ id: CGWindowID, caught: CGWindowID?) -> Bool {
        caught == nil || caught == id
    }

    /// Polls the window list every ~2 ms to measure exposure, and catches the
    /// window itself if the observer didn't fire.
    private func poll() {
        while polling {
            let now = nowMs()
            // (Never a window some session already has, whenever it appeared.)
            for info in WindowList.of(pid: pid, onScreenOnly: true) where info.layer == 0 && !before.contains(info.id)
                && !WindowManager.isRegistered(info.id) {
                lock.lock()
                if !Self.mayMove(info.id, caught: caughtID) { lock.unlock(); continue }
                let first = firstSeenMs == nil
                if first { firstSeenMs = now }
                lock.unlock()
                if first { onSeen?() }
                if manager?.display.touchesUser(info.bounds) == true && manager?.display.holds(info.bounds) == false {
                    lock.lock()
                    if firstOnUserMs == nil { firstOnUserMs = now }
                    lastOnUserMs = now
                    let m = moved[info.id]
                    lock.unlock()
                    let due = m == nil ? now - (firstOnUserMs ?? now) > 15 : (m!.lastMs > 0 && now - m!.lastMs >= 30 && m!.count < 10)
                    if due, let ax = AX.window(pid: pid, id: info.id) {
                        catchWindow(id: info.id, element: ax)
                    }
                } else if manager?.display.holds(info.bounds) == true {
                    lock.lock()
                    if caughtID == nil { caughtID = info.id }
                    let m = moved[info.id]
                    let t = target
                    lock.unlock()
                    // Chromium also resets the size after the move. A window
                    // wider than the agent display gets put back on the
                    // user's screen, and the next window copies its size.
                    if let m, let t, m.lastMs > 0, now - m.lastMs >= 30, m.count < 10,
                       abs(info.bounds.width - t.width) > 2 || abs(info.bounds.height - t.height) > 2,
                       let ax = AX.window(pid: pid, id: info.id) {
                        catchWindow(id: info.id, element: ax)
                    }
                } else if AgentDisplay.containing(CGPoint(x: info.bounds.midX, y: info.bounds.midY)) != nil {
                    // Opened next to another session's window: bring it to ours.
                    lock.lock()
                    let m = moved[info.id]
                    lock.unlock()
                    if m == nil || (m!.lastMs > 0 && now - m!.lastMs >= 30 && m!.count < 10), let ax = AX.window(pid: pid, id: info.id) {
                        catchWindow(id: info.id, element: ax)
                    }
                }
            }
            usleep(2000)
        }
    }

    /// The new window once it's on the agent display. Gives up early when
    /// `stop` says the request for it failed.
    /// `shown`: also wait until it's on screen (1.5 s at most after it's in
    /// place), since only a shown window can take key.
    func waitForWindow(timeoutMs: Double, shown: Bool = false, stop: () -> Bool = { false }) -> CGWindowID? {
        let deadline = nowMs() + timeoutMs
        var placedMs: Double?
        while nowMs() < deadline && !stop() {
            lock.lock()
            let id = caughtID
            lock.unlock()
            if let id, let info = WindowList.info(id), manager?.display.holds(info.bounds) == true {
                if placedMs == nil { placedMs = nowMs() }
                if !shown || info.onScreen || nowMs() - (placedMs ?? 0) > 1500 { return id }
            }
            sleepMs(10)
        }
        lock.lock(); defer { lock.unlock() }
        return caughtID
    }

    var flashReport: String {
        lock.lock(); defer { lock.unlock() }
        guard let first = firstOnUserMs, let last = lastOnUserMs else {
            return "the window never appeared on your displays"
        }
        return "the window was on your display for about \(Int(last - first + 2)) ms before it was moved (first seen \(Int(first - startMs)) ms after the request)"
    }
}

private func catcherCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    Unmanaged<WindowCatcher>.fromOpaque(refcon).takeUnretainedValue().created(element)
}
