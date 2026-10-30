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

    init(id: CGWindowID, pid: pid_t, appName: String, bundleID: String?, kind: Kind, originalFrame: CGRect? = nil) {
        self.id = id
        self.pid = pid
        self.appName = appName
        self.bundleID = bundleID
        self.kind = kind
        self.originalFrame = originalFrame
    }
}

/// Owns which windows belong to the agent and keeps them on the agent display.
public final class WindowManager {
    let display: AgentDisplay
    let focusGuard: FocusGuard
    private let lock = NSLock()
    private var registry: [CGWindowID: AgentWindow] = [:]
    private var knownBefore: [pid_t: Set<CGWindowID>] = [:]
    private var nextSlot = 0
    private var watchdog: Timer?

    init(display: AgentDisplay, focusGuard: FocusGuard) {
        self.display = display
        self.focusGuard = focusGuard
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
        lock.lock(); registry[w.id] = w; lock.unlock()
        persist()
    }

    func unregister(_ id: CGWindowID) {
        lock.lock(); registry[id] = nil; lock.unlock()
        persist()
    }

    private var registryURL: URL { BCUPaths.supportDirectory.appendingPathComponent("windows.json") }

    /// Written on every change, so the next launch can clean up after a crash.
    private func persist() {
        lock.lock()
        let entries: [[String: Any]] = registry.values.map { w in
            var e: [String: Any] = ["id": Int(w.id), "pid": Int(w.pid), "app": w.appName, "kind": w.kind.rawValue]
            if let f = w.originalFrame { e["frame"] = [f.minX, f.minY, f.width, f.height] }
            return e
        }
        lock.unlock()
        if let data = try? JSONSerialization.data(withJSONObject: entries) {
            try? FileManager.default.createDirectory(at: BCUPaths.supportDirectory, withIntermediateDirectories: true)
            try? data.write(to: registryURL, options: .atomic)
        }
    }

    /// On launch: close windows a previous run opened, return ones it borrowed.
    public func recoverFromPreviousRun() -> [String] {
        guard let data = try? Data(contentsOf: registryURL),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var notes: [String] = []
        for e in entries {
            guard let id = (e["id"] as? Int).map({ CGWindowID($0) }), let pid = (e["pid"] as? Int).map({ pid_t($0) }),
                  WindowList.info(id)?.pid == pid, let ax = AX.window(pid: pid, id: id) else { continue }
            if e["kind"] as? String == "borrowed", let f = e["frame"] as? [Double], f.count == 4 {
                AX.setPosition(ax, CGPoint(x: f[0], y: f[1]))
                AX.setSize(ax, CGSize(width: f[2], height: f[3]))
                notes.append("returned \(e["app"] ?? "?") window \(id)")
            } else if let close = AX.element(ax, "AXCloseButton") {
                AX.perform(close, "AXPress")
                notes.append("closed leftover \(e["app"] ?? "?") window \(id)")
            }
        }
        try? FileManager.default.removeItem(at: registryURL)
        return notes
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
        let lower = q.lowercased().replacingOccurrences(of: ".app", with: "")
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }
        if let app = running.first(where: { $0.bundleIdentifier?.lowercased() == lower })
            ?? running.first(where: { $0.localizedName?.lowercased() == lower }) {
            return AppTarget(name: app.localizedName ?? q, bundleID: app.bundleIdentifier, running: app, url: app.bundleURL)
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: q) {
            return AppTarget(name: url.deletingPathExtension().lastPathComponent, bundleID: q, running: nil, url: url)
        }
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                    "/Applications/Utilities", NSHomeDirectory() + "/Applications", "/System/Library/CoreServices"]
        for dir in dirs {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(q.replacingOccurrences(of: ".app", with: "")).app")
            if FileManager.default.fileExists(atPath: url.path) {
                let bundle = Bundle(url: url)
                return AppTarget(name: url.deletingPathExtension().lastPathComponent, bundleID: bundle?.bundleIdentifier, running: nil, url: url)
            }
        }
        if let app = running.first(where: { ($0.localizedName ?? "").lowercased().contains(lower) }) {
            return AppTarget(name: app.localizedName ?? q, bundleID: app.bundleIdentifier, running: app, url: app.bundleURL)
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

    public func open(app query: String, placement: Placement = .auto, trigger: String? = nil) throws -> OpenResult {
        let target = try resolveApp(query)
        if let running = target.running {
            return try openNewWindow(pid: running.processIdentifier, name: target.name, bundleID: target.bundleID, placement: placement, trigger: trigger)
        }
        guard let url = target.url else { throw ToolError("can't find \(target.name) on disk") }
        return try launch(url: url, name: target.name, bundleID: target.bundleID)
    }

    /// Launch a not-running app hidden and without activation, move its first
    /// windows onto the agent display, then unhide it there.
    private func launch(url: URL, name: String, bundleID: String?) throws -> OpenResult {
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

        // Wait for the app to answer accessibility and show its first windows.
        let deadline = nowMs() + 8000
        var axWindows: [AXUIElement] = []
        while nowMs() < deadline {
            axWindows = AX.windows(pid).filter { AX.windowID($0) != nil }
            if !axWindows.isEmpty { break }
            sleepMs(100)
        }
        var notes = ["launched \(name) hidden"]
        var first: AgentWindow?
        for w in axWindows {
            guard let id = AX.windowID(w) else { continue }
            let size = AX.size(w) ?? CGSize(width: 1200, height: 800)
            moveToAgent(w, size: size)
            let aw = AgentWindow(id: id, pid: pid, appName: name, bundleID: bundleID, kind: .opened)
            register(aw)
            if first == nil { first = aw }
        }
        app.unhide()
        sleepMs(250)
        for w in axWindows { if let id = AX.windowID(w), let info = WindowList.info(id), !display.holds(info.bounds) { moveToAgent(w, size: info.bounds.size) } }
        if let first {
            let title = AX.window(pid: pid, id: first.id).flatMap { AX.string($0, "AXTitle") } ?? ""
            notes.append("its startup window \"\(title)\" is on your display; if it's not the window you need, use press_menu_item or press_key in it")
            return OpenResult(window: first, notes: notes)
        }
        // No startup window: open one the normal way.
        let result = try openNewWindow(pid: pid, name: name, bundleID: bundleID)
        return OpenResult(window: result.window, notes: notes + result.notes)
    }

    /// Open a new window of a running app and put it on the agent display.
    private func openNewWindow(pid: pid_t, name: String, bundleID: String?, placement: Placement = .auto, trigger: String? = nil) throws -> OpenResult {
        let before = Set(WindowList.of(pid: pid).map(\.id))
        let previousKey = AX.focusedWindowID(pid)
        let catcher = WindowCatcher(pid: pid, before: before, manager: self)
        focusGuard.beginAction(pid: pid, cause: "opening a \(name) window")
        lock.lock(); opening.insert(pid); lock.unlock()
        defer {
            focusGuard.endAction(pid: pid)
            lock.lock(); opening.remove(pid); lock.unlock()
        }
        noteBefore(pid: pid)
        var notes: [String] = []

        // If the agent already has a window of this app, make it the app's key
        // window first: apps place new windows relative to their key window.
        var scope: KeyScope?
        if placement.contains(.anchor),
           let anchor = windows.first(where: { $0.pid == pid && !$0.handedOff && WindowList.info($0.id) != nil }) {
            scope = try? KeyScope.enter(pid: pid, window: anchor.id)
            if scope != nil { notes.append("anchored on window \(anchor.id)") }
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
        var how = ""
        if trigger != "key", let item = Self.newWindowMenuItem(pid: pid) {
            let err = AX.perform(item.element, "AXPress")
            how = "menu \"\(item.title)\"" + (err == .success ? "" : " (\(AX.errorName(err)))")
        } else {
            try Input.pressKey(pid: pid, key: "n", modifiers: ["cmd"])
            how = "cmd+N"
        }
        let caught = catcher.waitForWindow(timeoutMs: 5000)
        catcher.stop()
        if assigned {
            _ = BCUProcessAssignToSpace(pid, 0)
            assigned = false
        }
        scope?.exit()
        guard let id = caught else {
            if let key = unkeyedFullScreen, WindowList.info(key) != nil { KeyScope.postRecords(pid: pid, from: nil, to: key) }
            throw ToolError("\(name) didn't open a new window (tried \(how)). It may not support multiple windows: use list_windows with app=\"\(name)\" and borrow_window.")
        }
        // Give the app's key window back to whatever had it, so switching to
        // the app lands the user on their own window.
        if let previousKey, previousKey != id, WindowList.info(previousKey) != nil, AX.focusedWindowID(pid) == id {
            KeyScope.postRecords(pid: pid, from: id, to: previousKey)
        } else if let key = unkeyedFullScreen, WindowList.info(key) != nil, AX.focusedWindowID(pid) != key {
            KeyScope.postRecords(pid: pid, from: nil, to: key)
        }
        let aw = AgentWindow(id: id, pid: pid, appName: name, bundleID: bundleID, kind: .opened)
        register(aw)
        notes.insert("opened with \(how)", at: 0)
        notes.append(catcher.flashReport)
        return OpenResult(window: aw, notes: notes)
    }

    struct MenuItemRef {
        let element: AXUIElement
        let title: String
    }

    /// The app's "New Window" menu item, else its plain cmd+N item.
    static func newWindowMenuItem(pid: pid_t) -> MenuItemRef? {
        guard let bar = AX.element(AX.app(pid), "AXMenuBar") else { return nil }
        var cmdN: MenuItemRef?
        for top in AX.children(bar) {
            for menu in AX.children(top) {
                for item in AX.children(menu) {
                    let title = AX.string(item, "AXTitle") ?? ""
                    let enabled = AX.bool(item, "AXEnabled") ?? true
                    guard enabled, !title.isEmpty else { continue }
                    let lower = title.lowercased()
                    if lower == "new window" { return MenuItemRef(element: item, title: title) }
                    let char = AX.string(item, "AXMenuItemCmdChar") ?? ""
                    let mods = (AX.attr(item, "AXMenuItemCmdModifiers") as? NSNumber)?.intValue ?? -1
                    if cmdN == nil && char.uppercased() == "N" && mods == 0
                        && !lower.contains("private") && !lower.contains("incognito") {
                        cmdN = MenuItemRef(element: item, title: title)
                    }
                }
            }
        }
        return cmdN
    }

    /// Move a window onto the agent display, keeping its size where it fits.
    @discardableResult
    func moveToAgent(_ window: AXUIElement, size: CGSize) -> Bool {
        lock.lock()
        let slot = nextSlot
        nextSlot += 1
        lock.unlock()
        let frame = display.slotFrame(size: size, slot: slot)
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
            unregister(id)
            return "window \(id) is already gone"
        }
        focusGuard.beginAction(pid: w.pid, cause: "releasing a window")
        defer { focusGuard.endAction(pid: w.pid) }
        switch w.kind {
        case .borrowed:
            if let f = w.originalFrame {
                AX.setPosition(ax, f.origin)
                AX.setSize(ax, f.size)
            }
            unregister(id)
            return "returned window \(id) to where it was"
        case .opened, .caught:
            if keepOpen {
                unregister(id)
                return "left window \(id) open"
            }
            if let close = AX.element(ax, "AXCloseButton") {
                AX.perform(close, "AXPress")
            } else {
                AX.perform(ax, "AXCancel")
            }
            let deadline = nowMs() + 1500
            while WindowList.info(id) != nil && nowMs() < deadline { sleepMs(50) }
            if WindowList.info(id) != nil {
                return "window \(id) didn't close. A dialog may be asking something (unsaved changes?): check get_window_state, answer it, then release again."
            }
            unregister(id)
            return "closed window \(id)"
        }
    }

    public func handoff(_ id: CGWindowID, reason: String) throws {
        guard let w = window(id), let ax = AX.window(pid: w.pid, id: id) else { throw ToolError("window \(id) isn't one of yours") }
        let main = CGDisplayBounds(CGMainDisplayID())
        let size = AX.size(ax) ?? CGSize(width: 1000, height: 700)
        let w2 = min(size.width, main.width - 80), h2 = min(size.height, main.height - 120)
        w.handedOff = true
        w.handoffReason = reason
        AX.setPosition(ax, CGPoint(x: main.midX - w2 / 2, y: main.midY - h2 / 2))
        AX.setSize(ax, CGSize(width: w2, height: h2))
    }

    public func takeBack(_ id: CGWindowID) throws {
        guard let w = window(id), let ax = AX.window(pid: w.pid, id: id) else { throw ToolError("window \(id) isn't one of yours") }
        w.handedOff = false
        w.handoffReason = nil
        moveToAgent(ax, size: AX.size(ax) ?? CGSize(width: 1200, height: 800))
    }

    /// Close opened windows and return borrowed ones.
    public func releaseAll() -> [String] {
        windows.map { (try? release($0.id, keepOpen: false)) ?? "window \($0.id): failed" }
    }

    // MARK: Watchdog

    func noteBefore(pid: pid_t) {
        let ids = Set(WindowList.of(pid: pid).map(\.id))
        lock.lock(); knownBefore[pid] = ids; lock.unlock()
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

        let tainted = Set(focusGuard.activeTaints)
        let onScreen = WindowList.all(onScreenOnly: true)

        // Reverse catch: apps place new windows next to their last window, so
        // after the agent used an app, a window the USER opens in it can land on
        // the agent display. A new, unregistered window there, from the app the
        // user is in, is theirs: move it to their screen.
        let front = BCUFrontProcessPID()
        for info in onScreen where info.layer == 0 && agent[info.id] == nil && display.holds(info.bounds) {
            // Judge each new window for 1.5 s: the guard learns the user's front
            // app a moment after it changes.
            lock.lock()
            let firstSeen = seenOnAgent[info.id] ?? nowMs()
            if seenOnAgent[info.id] == nil { seenOnAgent[info.id] = firstSeen }
            lock.unlock()
            // "The user is in this app": WindowServer's front app is it AND the
            // guard counts it as the user's (not a self-activation it's undoing).
            // Only standard windows: popups the agent's own window opens
            // (suggestion lists, menus) are separate windows too.
            guard nowMs() - firstSeen < 1500, info.pid == front, info.pid == focusGuard.userFront,
                  info.bounds.width > 100, info.bounds.height > 100,
                  let ax = AX.window(pid: info.pid, id: info.id),
                  AX.string(ax, "AXSubrole") == "AXStandardWindow" else { continue }
            let main = CGDisplayBounds(CGMainDisplayID())
            let w = min(info.bounds.width, main.width - 80), h = min(info.bounds.height, main.height - 120)
            AX.setPosition(ax, CGPoint(x: main.midX - w / 2, y: main.midY - h / 2))
            AX.setSize(ax, CGSize(width: w, height: h))
            lock.lock(); seenOnAgent[info.id] = -1e12; lock.unlock()
            focusGuard.record("moved a new \(info.owner) window you opened from the agent display to your screen")
        }

        for info in onScreen where info.layer == 0 {
            if let w = agent[info.id] {
                if !w.handedOff && display.touchesUser(info.bounds) && !display.holds(info.bounds),
                   let ax = AX.window(pid: w.pid, id: w.id) {
                    moveToAgent(ax, size: info.bounds.size)
                    focusGuard.record("moved your agent's \(w.appName) window back off your display")
                } else if !w.handedOff && !userArranging && !display.bounds.insetBy(dx: -8, dy: -8).contains(info.bounds) {
                    fitInside(w, frame: info.bounds)
                }
                continue
            }
            // Only while the agent acts on the app and the user isn't in it:
            // a window that appears in the app the user is using is theirs.
            lock.lock()
            let midOpen = opening.contains(info.pid)
            lock.unlock()
            guard tainted.contains(info.pid), !midOpen, info.pid != front, info.pid != focusGuard.userFront else { continue }
            lock.lock()
            let before = knownBefore[info.pid] ?? []
            lock.unlock()
            guard !before.contains(info.id), display.touchesUser(info.bounds), !display.holds(info.bounds),
                  info.bounds.width > 40, info.bounds.height > 40,
                  let ax = AX.window(pid: info.pid, id: info.id) else { continue }
            moveToAgent(ax, size: info.bounds.size)
            let app = NSRunningApplication(processIdentifier: info.pid)
            register(AgentWindow(id: info.id, pid: info.pid, appName: app?.localizedName ?? info.owner, bundleID: app?.bundleIdentifier, kind: .caught))
            focusGuard.record("caught a new \(app?.localizedName ?? info.owner) window on your display and moved it to the agent display")
        }

        lock.lock()
        let ids = Array(registry.keys)
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
    private var firstOnUserMs: Double?
    private var lastOnUserMs: Double?
    private var movedMs: Double?
    private var moved: Set<CGWindowID> = []

    init(pid: pid_t, before: Set<CGWindowID>, manager: WindowManager) {
        self.pid = pid
        self.before = before
        self.manager = manager
    }

    func start() {
        startMs = nowMs()
        DispatchQueue.main.sync {
            var obs: AXObserver?
            guard AXObserverCreate(pid, catcherCallback, &obs) == .success, let obs else { return }
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            AXObserverAddNotification(obs, AX.app(pid), kAXWindowCreatedNotification as CFString, refcon)
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
            observer = obs
        }
        polling = true
        let thread = Thread { [weak self] in self?.poll() }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        polling = false
        if let obs = observer {
            DispatchQueue.main.sync {
                AXObserverRemoveNotification(obs, AX.app(pid), kAXWindowCreatedNotification as CFString)
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
            }
            observer = nil
        }
    }

    /// AXObserver path: runs on the main thread right after the window is created.
    fileprivate func created(_ element: AXUIElement) {
        guard let id = AX.windowID(element), !before.contains(id) else { return }
        catchWindow(id: id, element: element)
    }

    private func catchWindow(id: CGWindowID, element: AXUIElement) {
        lock.lock()
        if moved.contains(id) { lock.unlock(); return }
        moved.insert(id)
        lock.unlock()
        let size = AX.size(element) ?? CGSize(width: 1200, height: 800)
        manager?.moveToAgent(element, size: size)
        lock.lock()
        if caughtID == nil { caughtID = id }
        if movedMs == nil { movedMs = nowMs() }
        lock.unlock()
    }

    /// Polls the window list every ~2 ms to measure exposure, and catches the
    /// window itself if the observer didn't fire.
    private func poll() {
        while polling {
            let now = nowMs()
            for info in WindowList.of(pid: pid, onScreenOnly: true) where info.layer == 0 && !before.contains(info.id) {
                lock.lock()
                if firstSeenMs == nil { firstSeenMs = now }
                lock.unlock()
                if manager?.display.touchesUser(info.bounds) == true && manager?.display.holds(info.bounds) == false {
                    lock.lock()
                    if firstOnUserMs == nil { firstOnUserMs = now }
                    lastOnUserMs = now
                    let alreadyMoved = moved.contains(info.id)
                    lock.unlock()
                    if !alreadyMoved && now - (firstOnUserMs ?? now) > 15, let ax = AX.window(pid: pid, id: info.id) {
                        catchWindow(id: info.id, element: ax)
                    }
                } else if manager?.display.holds(info.bounds) == true {
                    lock.lock()
                    if caughtID == nil { caughtID = info.id }
                    lock.unlock()
                }
            }
            usleep(2000)
        }
    }

    func waitForWindow(timeoutMs: Double) -> CGWindowID? {
        let deadline = nowMs() + timeoutMs
        while nowMs() < deadline {
            lock.lock()
            let id = caughtID
            lock.unlock()
            if let id, let info = WindowList.info(id), manager?.display.holds(info.bounds) == true {
                sleepMs(60)  // let the exposure measurement see the final state
                return id
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
