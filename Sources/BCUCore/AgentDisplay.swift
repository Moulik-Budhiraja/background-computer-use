import AppKit
import CoreGraphics
import CPrivate

/// An agent's private display. Each agent session gets its own. The first
/// touches the user's displays at a single corner (bottom-right of their
/// union) and each further one touches the one before it at its corner, so
/// the cursor can only reach them at one point, and the input tap fences
/// even that off.
///
/// Adding or removing a display makes macOS rearrange them all: the whole
/// screen stalls for a few hundred ms, every window is told its screen
/// changed, and windows the user moved since the last time the displays
/// were like this can jump back to where they were then. So a display a
/// session is done with isn't removed: it's set aside (`spares`) for the
/// next session, and only removed once none has wanted it for
/// `spareLifeMs`. A run of agents, one after another or a few at a time,
/// costs one rearrangement going in and one coming out.
public final class AgentDisplay {
    public private(set) var displayID: CGDirectDisplayID = 0
    /// Agent display bounds in global (top-left origin) coordinates.
    public private(set) var bounds: CGRect = .zero
    /// Union of the user's real displays.
    public private(set) var userBounds: CGRect = .zero

    public let width: Int
    public let height: Int
    public var onChange: (() -> Void)?

    /// Position in the staircase of agent displays (0 is next to the user's).
    public private(set) var slot = 0

    private var display: BCUVirtualDisplay?

    // MARK: All agent displays

    private final class Ref { weak var display: AgentDisplay?; init(_ d: AgentDisplay) { display = d } }
    private static let registryLock = NSLock()
    private static var registry: [Ref] = []

    /// The running agent displays, in staircase order.
    public static var running: [AgentDisplay] {
        registryLock.lock(); defer { registryLock.unlock() }
        return registry.compactMap(\.display).filter(\.isRunning).sorted { $0.slot < $1.slot }
    }

    /// The lowest slot no running display uses.
    public static func freeSlot() -> Int {
        registryLock.lock()
        var used = Set(spares.map(\.slot))
        registryLock.unlock()
        used.formUnion(running.map(\.slot))
        return (0...).first { !used.contains($0) }!
    }

    /// Any agent display, by ID.
    public static func isAgentDisplay(_ id: CGDirectDisplayID) -> Bool {
        running.contains { $0.displayID == id }
    }

    /// The agent display a global point is on.
    public static func containing(_ p: CGPoint) -> AgentDisplay? {
        running.first { $0.liveBounds.contains(p) }
    }

    // MARK: Stray displays

    /// What every BCU virtual display reports to macOS (see VirtualDisplay.m).
    static let vendorID: UInt32 = 0xBC0F
    static let productID: UInt32 = 0xBC01

    static func isBCUDisplay(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == vendorID && CGDisplayModelNumber(id) == productID
    }

    private static var strayCache: (atMs: Double, ids: [CGDirectDisplayID]) = (-1, [])

    /// BCU displays this process didn't make: left behind by a copy of the
    /// app that crashed (macOS can keep them with no owner until logout).
    /// They're as invisible to the user as ours, so the cursor is fenced
    /// off them too. Cached briefly: the input tap asks on every mouse move.
    public static var strayIDs: [CGDirectDisplayID] {
        let now = nowMs()
        registryLock.lock()
        if now - strayCache.atMs < 250 { let ids = strayCache.ids; registryLock.unlock(); return ids }
        let ours = Set(registry.compactMap { $0.display?.displayID }).union(spares.map(\.id))
        registryLock.unlock()
        let ids = onlineDisplayIDs().filter { !ours.contains($0) && isBCUDisplay($0) }
        registryLock.lock()
        strayCache = (now, ids)
        registryLock.unlock()
        return ids
    }

    /// Every display the cursor must stay off: ours (spares too) and strays.
    public static var fencedBounds: [CGRect] {
        registryLock.lock()
        let spare = spares.map(\.id)
        registryLock.unlock()
        return running.map(\.liveBounds) + (spare + strayIDs).map { CGDisplayBounds($0) }
    }

    private static var fencedCache: (atMs: Double, rects: [CGRect]) = (-1, [])

    /// The fenced display a global point is on. The input tap asks on every
    /// mouse move, so the rects are worked out at most every 100 ms (and
    /// right away after a display comes or goes).
    public static func fenced(at p: CGPoint) -> CGRect? {
        let now = nowMs()
        registryLock.lock()
        if now - fencedCache.atMs < 100 { let r = fencedCache.rects; registryLock.unlock(); return r.first { $0.contains(p) } }
        registryLock.unlock()
        let rects = fencedBounds
        registryLock.lock()
        fencedCache = (now, rects)
        registryLock.unlock()
        return rects.first { $0.contains(p) }
    }

    private static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(32, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    private static var callbackInstalled = false

    // MARK: The user's windows across a rearrangement

    /// Where the user's windows were before the displays changed.
    public struct UserWindows {
        fileprivate let frames: [(id: CGWindowID, pid: pid_t, bounds: CGRect)]
        fileprivate let displays: Set<CGDirectDisplayID>
    }

    /// macOS remembers, for each arrangement of displays, where every window
    /// was the last time the displays were arranged that way, and puts them
    /// back there when the arrangement returns. An agent display coming or
    /// going is such a change: a browser window the user has since made
    /// small goes back to filling their screen the moment an agent starts.
    /// Note where their windows are before the change (`noteUserWindows`),
    /// and after it put back any that macOS moved (`restoreUserWindows`).
    public static func noteUserWindows() -> UserWindows {
        registryLock.lock()
        let spare = spares.map(\.id)
        registryLock.unlock()
        let agents = running.map(\.liveBounds) + spare.map { CGDisplayBounds($0) }
        let frames = WindowList.all().filter { w in
            w.layer == 0 && w.pid != getpid() && w.bounds.width > 40 && w.bounds.height > 40
                && !agents.contains { $0.contains(CGPoint(x: w.bounds.midX, y: w.bounds.midY)) }
        }.map { (id: $0.id, pid: $0.pid, bounds: $0.bounds) }
        return UserWindows(frames: frames, displays: Set(userDisplayIDs()))
    }

    /// Any thread; returns at once and watches on a thread of its own for
    /// `quietMs` after the last window it had to put back (macOS moves them
    /// as the display comes online and again when it's placed), 5 s at most.
    /// Call it before the change takes effect: a window is put back within
    /// a frame or two of jumping.
    public static func restoreUserWindows(_ before: UserWindows, quietMs: Double = 1800) {
        guard !before.frames.isEmpty else { return }
        let thread = Thread {
            let deadline = nowMs() + 5000
            var lastMoved = nowMs()
            var moved: Set<CGWindowID> = []
            while nowMs() < deadline && nowMs() - lastMoved < quietMs {
                sleepMs(15)
                // The user's own displays changed too (a monitor unplugged):
                // then where things were no longer says where they belong.
                guard Set(userDisplayIDs()) == before.displays else { break }
                // A window the user is dragging isn't macOS's doing.
                if CGEventSource.buttonState(.hidSystemState, button: .left) { continue }
                for w in before.frames {
                    guard let now = WindowList.info(w.id)?.bounds, now != .zero,
                          abs(now.minX - w.bounds.minX) > 1 || abs(now.minY - w.bounds.minY) > 1
                            || abs(now.width - w.bounds.width) > 1 || abs(now.height - w.bounds.height) > 1,
                          let ax = AX.window(pid: w.pid, id: w.id) else { continue }
                    // A window that fills the screen takes its place only
                    // once it's smaller, and its size only once it has moved.
                    AX.setPosition(ax, w.bounds.origin)
                    AX.setSize(ax, w.bounds.size)
                    AX.setPosition(ax, w.bounds.origin)
                    moved.insert(w.id)
                    lastMoved = nowMs()
                }
            }
            if !moved.isEmpty {
                Log.info("macOS moved \(moved.count) of the user's windows when the displays changed; put them back where they were")
            }
        }
        thread.name = "bcu.display.windows"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    // MARK: Spares

    /// A display no session is using, kept for the next one.
    private struct Spare {
        let display: BCUVirtualDisplay
        let id: CGDirectDisplayID
        let slot: Int
        let width: Int
        let height: Int
        let sinceMs: Double
    }
    private static var spares: [Spare] = []
    /// How long a display nobody uses is kept before it's removed.
    /// BCU_SPARE_DISPLAY_S at launch changes it (0: never kept).
    public static let spareLifeMs = (Double(ProcessInfo.processInfo.environment["BCU_SPARE_DISPLAY_S"] ?? "") ?? 300) * 1000

    /// Main thread. Remove spare displays nobody has wanted for
    /// `spareLifeMs`, or all of them (`all`: the engine is stopping, the
    /// Mac is going to sleep, or the user's own displays are gone).
    public static func reapSpares(all: Bool = false) {
        // Changing the displays stalls macOS for a moment (measured for
        // adding one: keys typed just then reach their app 60–100 ms late,
        // and 0.3–0.6 s late when several are added together), so a spare
        // isn't taken away while the user is typing. There's no hurry unless
        // an agent is waiting for a place; `tend` asks again every second.
        if !all, !someoneWaiting, let activity = FocusGuard.shared?.activity, QuietWait.typing(activity.snapshot, now: nowMs()) { return }
        let furthestInUse = running.map(\.slot).max() ?? -1
        registryLock.lock()
        let now = nowMs()
        var gone = spares.filter { all || now - $0.sinceMs > spareLifeMs }
        if !all {
            // The displays stand in a staircase, each at the corner of the one
            // before, and macOS won't leave a gap: take one out and every
            // display after it moves, with its windows, which on the way
            // land on the user's screen (measured on 0.1.18: an agent's
            // window at 135,212 on the main display for half a second when
            // three idle displays before its own were removed). So only from
            // the far end: never one with a display in use after it, or a
            // spare that's staying.
            gone.removeAll { $0.slot < furthestInUse }
            while let blocked = gone.first(where: { g in spares.contains { s in s.slot > g.slot && !gone.contains { $0.id == s.id } } }) {
                gone.removeAll { $0.id == blocked.id }
            }
            // Not with a window on it (an app put one there since): it would
            // land on the user's screen. Close it first; next time, then.
            let busy = gone.filter { !WindowManager.windows(on: CGDisplayBounds($0.id)).isEmpty }
            gone.removeAll { g in busy.contains { $0.id == g.id } }
            for b in busy {
                let bounds = CGDisplayBounds(b.id)
                DispatchQueue.global(qos: .utility).async { WindowManager.closeLeftovers(on: bounds) }
            }
        }
        spares.removeAll { s in gone.contains { $0.id == s.id } }
        strayCache.atMs = -1; fencedCache.atMs = -1
        registryLock.unlock()
        guard !gone.isEmpty else { return }
        let before = noteUserWindows()
        for s in gone {
            s.display.invalidate()
            Log.info("agent display \(s.slot + 1) (\(s.id)) removed: no agent has needed it for a while")
        }
        for d in running { d.reconfigured() }
        restoreUserWindows(before)
    }

    /// Spare displays there are (for the status line and tests).
    public static var spareCount: Int {
        registryLock.lock(); defer { registryLock.unlock() }
        return spares.count
    }

    // MARK: How many at once

    /// At most this many agent displays exist at once. An agent that needs
    /// one when they're all taken waits its turn (see `reserve`).
    /// BCU_MAX_DISPLAYS at launch changes it (for tests).
    public static let maxDisplays = max(1, Int(ProcessInfo.processInfo.environment["BCU_MAX_DISPLAYS"] ?? "") ?? 4)
    private static let gate = NSCondition()
    private static var reservations = 0
    /// Agents waiting for a display, first come first served.
    private static var waiting: [Int] = []
    private static var nextTicket = 0
    private var reserved = false

    /// Take one of the `maxDisplays` places for this display, waiting up to
    /// `timeout` for another agent's display to go away. `onWait` runs once
    /// if it has to wait. Never call it on the main thread. Returns false
    /// on a timeout.
    public func reserve(timeout: TimeInterval, onWait: () -> Void) -> Bool {
        let g = Self.gate
        g.lock()
        if reserved { g.unlock(); return true }
        let ticket = Self.nextTicket
        Self.nextTicket += 1
        Self.waiting.append(ticket)
        let deadline = Date().addingTimeInterval(timeout)
        var told = false
        while !(Self.waiting.first == ticket && Self.reservations < Self.maxDisplays) {
            if !told {
                told = true
                g.unlock(); onWait(); g.lock()
                continue
            }
            if !g.wait(until: deadline) {
                Self.waiting.removeAll { $0 == ticket }
                g.broadcast()
                g.unlock()
                return false
            }
        }
        Self.waiting.removeFirst()
        Self.reservations += 1
        reserved = true
        g.broadcast()
        g.unlock()
        return true
    }

    /// An agent is waiting for a display.
    public static var someoneWaiting: Bool {
        gate.lock(); defer { gate.unlock() }
        return !waiting.isEmpty
    }

    /// Give the place back (`stop` does).
    private func unreserve() {
        let g = Self.gate
        g.lock()
        if reserved {
            reserved = false
            Self.reservations -= 1
            g.broadcast()
        }
        g.unlock()
    }

    public static let defaultWidth = 1600
    public static let defaultHeight = 1000

    public init(width: Int = AgentDisplay.defaultWidth, height: Int = AgentDisplay.defaultHeight) {
        self.width = width
        self.height = height
    }

    public var isRunning: Bool { display != nil && displayID != 0 }

    /// Where the display is right now. Unlike `bounds`, this is never stale
    /// while macOS is rearranging displays (wake, a monitor plugged in).
    public var liveBounds: CGRect {
        let id = displayID
        return id == 0 ? .zero : CGDisplayBounds(id)
    }

    /// Must be called on the main thread. `slot` picks the display's place in
    /// the staircase and its serial, which macOS keys remembered modes on.
    /// The display comes online asynchronously: follow with `waitUntilOnline`
    /// and then `finishStart` on the main thread.
    public func start(slot: Int = AgentDisplay.freeSlot()) throws {
        guard display == nil else { return }
        // One a session before this left behind: nothing is added, so
        // nothing on the user's screens moves.
        Self.registryLock.lock()
        let spare = Self.spares.filter { $0.width == width && $0.height == height }.min { $0.slot < $1.slot }
        if let spare { Self.spares.removeAll { $0.id == spare.id } }
        Self.registryLock.unlock()
        if let spare, !CGDisplayBounds(spare.id).isEmpty {
            display = spare.display
            displayID = spare.id
            self.slot = spare.slot
            reused = true
            register()
            return
        }
        spare?.display.invalidate()
        reused = false
        Self.noteChange()
        self.slot = slot
        let name = slot == 0 ? "Agent Display" : "Agent Display \(slot + 1)"
        // macOS refuses a second display with a serial that's still online,
        // which a stray display from a crashed copy can hold until logout.
        // Spare serials sit past every slot's own.
        let base: UInt32 = 0x4243_5532
        let serials = [base + UInt32(slot)] + (1...8).map { base + UInt32(slot) + UInt32($0) * 16 }
        var made: BCUVirtualDisplay?
        for serial in serials {
            made = BCUVirtualDisplay(name: name, width: UInt32(width), height: UInt32(height), ppi: 110, serial: serial)
            if made != nil {
                if serial != serials[0] { Log.info("agent display serial \(String(serials[0], radix: 16)) taken; used \(String(serial, radix: 16))") }
                break
            }
        }
        guard let vd = made else {
            throw ToolError("could not create the virtual display")
        }
        display = vd
        displayID = vd.displayID
        register()
    }

    /// Registered right away so a display starting at the same time
    /// (another session, while this one waits) takes another slot.
    private func register() {
        Self.registryLock.lock()
        Self.registry.removeAll { $0.display == nil || $0.display === self }
        Self.registry.append(Ref(self))
        Self.strayCache.atMs = -1; Self.fencedCache.atMs = -1
        if !Self.callbackInstalled {
            Self.callbackInstalled = true
            CGDisplayRegisterReconfigurationCallback(reconfigurationCallback, nil)
        }
        Self.registryLock.unlock()
    }

    /// The display `start` gave this session was a spare, not a new one.
    public private(set) var reused = false

    /// Wait for the display started by `start` to come online. Call it off the
    /// main queue: on macOS 15 the display only comes online once the main
    /// queue is free, so waiting inside a main-queue block always times out.
    public func waitUntilOnline(timeout: TimeInterval = 5) -> Bool {
        let id = displayID
        let deadline = Date().addingTimeInterval(timeout)
        while CGDisplayBounds(id).isEmpty && Date() < deadline {
            if Thread.isMainThread { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) } else { sleepMs(20) }
        }
        return id != 0 && !CGDisplayBounds(id).isEmpty
    }

    /// Main thread, once the display is online.
    public func finishStart() {
        place(mode: retinaModeNeeded())
        Log.info("agent display \(slot + 1) (\(displayID)) at \(bounds.short)\(reused ? " (kept from an earlier session)" : ""); user displays \(userBounds.short)")
    }

    /// Main thread. The session is done with its display. It's set aside
    /// for the next session (see `spares`) unless `remove`, or there's no
    /// user display for it to sit beside.
    public func stop(remove: Bool = false) {
        defer { unreserve() }
        guard let vd = display else { return }
        display = nil
        let id = displayID
        displayID = 0
        bounds = .zero
        // Kept for the next agent, and in any case while an agent is at work
        // on a display after this one (see `reapSpares`): it holds its place.
        let holdsPlace = Self.running.contains { $0 !== self && $0.slot > slot }
        let keep = !remove && (Self.spareLifeMs > 0 || holdsPlace) && !CGDisplayBounds(id).isEmpty && !Self.userDisplayIDs().isEmpty
        Self.registryLock.lock()
        Self.registry.removeAll { $0.display == nil || $0.display === self }
        if keep { Self.spares.append(Spare(display: vd, id: id, slot: slot, width: width, height: height, sinceMs: nowMs())) }
        Self.strayCache.atMs = -1; Self.fencedCache.atMs = -1
        Self.registryLock.unlock()
        if keep {
            Log.info("agent display \(slot + 1) (\(id)) set aside for the next agent")
            return
        }
        let before = Self.noteUserWindows()
        vd.invalidate()
        Log.info("agent display \(slot + 1) (\(id)) removed")
        // The ones after it move up the staircase.
        for d in Self.running { d.reconfigured() }
        Self.restoreUserWindows(before)
    }

    /// The user's real displays: every active display that isn't an agent's.
    public func userDisplayIDs() -> [CGDirectDisplayID] {
        Self.userDisplayIDs()
    }

    /// The user's real displays: every active display that isn't a BCU
    /// one. While all of them sleep none is active, so then the online ones,
    /// which keep their places.
    public static func userDisplayIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        CGGetActiveDisplayList(32, &ids, &count)
        let agents = Set(running.map(\.displayID))
        let active = Array(ids.prefix(Int(count))).filter { !agents.contains($0) && !isBCUDisplay($0) }
        if !active.isEmpty { return active }
        return onlineDisplayIDs().filter { !agents.contains($0) && !isBCUDisplay($0) }
    }

    /// Where this display goes: at the bottom-right corner of the agent
    /// display before it, or of the user's displays for the first.
    /// Stray displays sitting on the staircase are stepped over. nil when
    /// there's nowhere to put it (no user display at all).
    private func anchor() -> CGPoint? {
        var corner: CGPoint
        if let before = Self.running.filter({ $0.slot < slot && $0 !== self }).last {
            let b = CGDisplayBounds(before.displayID)
            corner = CGPoint(x: b.maxX, y: b.maxY)
        } else {
            let user = computeUserBounds()
            guard !user.isNull, user.maxX.isFinite, user.maxY.isFinite else { return nil }
            corner = CGPoint(x: user.maxX, y: user.maxY)
        }
        Self.registryLock.lock()
        let spare = Self.spares.map(\.id)
        Self.registryLock.unlock()
        var strays = (spare + Self.strayIDs).filter { $0 != displayID }.map { CGDisplayBounds($0) }
        while let i = strays.firstIndex(where: { $0.origin == corner }) {
            corner = CGPoint(x: strays[i].maxX, y: strays[i].maxY)
            strays.remove(at: i)
        }
        return corner
    }

    private func computeUserBounds() -> CGRect {
        userDisplayIDs().reduce(CGRect.null) { $0.union(CGDisplayBounds($1)) }
    }

    /// The 2x mode at our point size, if the display isn't in it. macOS
    /// remembers a mode per display serial, so a display first made at 1x
    /// would stay 1x.
    private func retinaModeNeeded() -> CGDisplayMode? {
        if let current = CGDisplayCopyDisplayMode(displayID), current.width == width, current.pixelWidth == width * 2 { return nil }
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode],
              let retina = modes.first(where: { $0.width == width && $0.height == height && $0.pixelWidth == width * 2 }) else {
            Log.info("agent display has no 2x mode at \(width)x\(height)")
            return nil
        }
        return retina
    }

    /// Put the display at its place, and into `mode` if given, in one
    /// configuration: each one macOS completes rearranges every display.
    fileprivate func place(mode: CGDisplayMode? = nil) {
        userBounds = computeUserBounds()
        let origin = anchor().flatMap { abs($0.x) < 1e6 && abs($0.y) < 1e6 ? $0 : nil }
        let current = CGDisplayBounds(displayID)
        if origin == nil { Log.info("agent display not placed: no user display") }
        // Placed once a user display shows up (see `reconfigured`).
        guard mode != nil || (origin != nil && origin != current.origin) else {
            bounds = current
            onChange?()
            return
        }
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        if let mode { CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil) }
        if let origin { CGConfigureDisplayOrigin(config, displayID, Int32(origin.x), Int32(origin.y)) }
        let err = CGCompleteDisplayConfiguration(config, .forSession)
        Self.noteChange()
        // (The same failure every second, while the screens sleep, is logged once.)
        if err != .success && err != lastPlaceError { Log.info("configuring the agent display failed: \(err.rawValue)") }
        lastPlaceError = err
        if mode != nil && err == .success { Log.info("agent display switched to \(width)x\(height) at 2x") }
        bounds = CGDisplayBounds(displayID)
        userBounds = computeUserBounds()
        onChange?()
    }

    private static let changeLock = NSLock()
    private static var lastChangeMs = 0.0

    /// A display is being added, removed, moved or switched to another mode.
    static func noteChange() {
        changeLock.lock(); lastChangeMs = nowMs(); changeLock.unlock()
    }

    /// Wait until the displays have been as they are for `quietMs` (`capMs`
    /// at most), and return how long that took. An app hears of a new
    /// display a moment after it's added, and until then a window it's asked
    /// to build there goes to the main display instead (measured: a browser
    /// window asked for on a display 1.7 s old, with two more being added,
    /// sat in the corner of the user's screen for 1.5 s, and moving it failed
    /// until the displays were done). Not on the main thread: macOS reports
    /// display changes there.
    @discardableResult
    public static func awaitSettled(quietMs: Double = 700, capMs: Double = 8000) -> Double {
        let start = nowMs()
        while true {
            changeLock.lock(); let last = lastChangeMs; changeLock.unlock()
            let now = nowMs()
            if now - last >= quietMs || now - start >= capMs { return now - start }
            sleepMs(max(5, min(50, quietMs - (now - last))))
        }
    }

    /// Main thread: macOS finished rearranging the displays.
    fileprivate static func displaysChanged() {
        registryLock.lock(); fencedCache.atMs = -1; strayCache.atMs = -1; registryLock.unlock()
        for d in running { d.reconfigured() }
    }

    /// Main thread, every second. A display macOS wouldn't place (the
    /// screens were asleep, or gone) stays where macOS put it, which can be
    /// on top of where the user's display comes back: put it right as soon
    /// as that works. And with no user display left at all, spares go.
    public static func tend() {
        if userDisplayIDs().isEmpty {
            reapSpares(all: true)
            return
        }
        reapSpares()
        for d in running { d.reconfigured() }
    }

    /// No user display to sit beside the last time this looked.
    private var unplaced = false
    private var lastPlaceError: CGError = .success

    fileprivate func reconfigured() {
        // A display still coming online is placed when it arrives.
        guard isRunning, !bounds.isEmpty else { return }
        let user = computeUserBounds()
        let b = CGDisplayBounds(displayID)
        guard let wanted = anchor() else {
            if !unplaced {
                unplaced = true
                Log.info("agent display \(slot + 1) has no user display to sit beside; it stays at \(b.short) until one is back")
            }
            bounds = b
            return
        }
        if unplaced || user != userBounds || b.origin != wanted {
            let was = unplaced
            unplaced = false
            place()
            if bounds.origin == wanted { Log.info("agent display \(slot + 1) re-placed at \(bounds.short)") } else if !was { unplaced = true }
        }
    }

    /// True when most of `rect` is on the agent display.
    public func holds(_ rect: CGRect) -> Bool {
        guard isRunning, !rect.isEmpty else { return false }
        let inter = rect.intersection(bounds)
        return !inter.isNull && inter.width * inter.height >= 0.5 * rect.width * rect.height
    }

    /// True when any part of `rect` is visible on one of the user's displays.
    public func touchesUser(_ rect: CGRect) -> Bool {
        userDisplayIDs().contains { CGDisplayBounds($0).intersects(rect) }
    }

    /// Where a window of `size` should go on the agent display, cascading by `slot`.
    public func slotFrame(size: CGSize, slot: Int) -> CGRect {
        let inset: CGFloat = 24
        let maxW = bounds.width - inset * 2
        let maxH = bounds.height - inset * 2 - 30
        let w = min(max(size.width, 400), maxW)
        let h = min(max(size.height, 300), maxH)
        let step = CGFloat(slot % 6) * 28
        let x = bounds.minX + inset + min(step, bounds.width - w - inset * 2)
        let y = bounds.minY + inset + 30 + min(step, bounds.height - h - inset * 2 - 30)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

private func reconfigurationCallback(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ info: UnsafeMutableRawPointer?) {
    AgentDisplay.noteChange()
    if flags.contains(.beginConfigurationFlag) { return }
    DispatchQueue.main.async { AgentDisplay.displaysChanged() }
}
