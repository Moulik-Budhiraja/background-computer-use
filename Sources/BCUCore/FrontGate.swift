import AppKit
import BCUShared
import CPrivate

/// Stops the apps agents are working in from bringing themselves to the
/// front, so the user's app never loses it in the first place.
///
/// An app can make itself frontmost whenever it likes (Chromium does each
/// time it shows a window or loads a URL it was handed, Finder and Electron
/// apps too), and no other process can stop the call. Putting the user's app
/// back afterwards is always too late: for those 10–60 ms the menu bar shows
/// the other app's menus, the user's window is drawn inactive with a lighter
/// shadow, hover effects under the pointer end, and the app's windows on the
/// user's screen can end up on top of theirs.
///
/// But macOS itself decides whether such a request is honored. LaunchServices
/// keeps a list of the apps allowed to make themselves frontmost
/// ("LSPermittedFrontASNs", what kiosk and exam modes use); WindowServer
/// refuses anyone else ("Denying <app> the right to be in front because it is
/// not in the list of permittedFrontASNs"), and nothing changes on screen. An
/// empty list permits everyone. So while agents have windows in apps the user
/// isn't in, the list holds every running app except those.
///
/// The list also stops the user getting to those apps: a click on one of
/// their windows, cmd+Tab or the Dock is refused the same way. So the gate
/// opens the moment the user does anything that could be a switch
/// (`lift`, called from the input tap before the event goes on): any mouse
/// button, cmd+Tab for as long as command is held, Return, a key with a
/// modifier or a function key. Plain typing, scrolling and moving the pointer
/// can't switch apps and leave it shut. While it's open the guard falls back
/// to putting the user's app back after the fact, as before.
///
/// This works on macOS 15. On 27.2 LaunchServices refuses the list
/// (status -10663; 26.7 answered the same), and the gate changes
/// WindowServer's own list instead, one app at a time
/// (SLPSAddToPermittedFrontPSNList). That list can't be read back, so the
/// gate keeps a record of every entry it adds, written before the entry
/// goes on. Opening it for the user adds the apps kept back, rather than
/// taking everyone else off.
///
/// The list outlives the process that set it, and a list left behind would
/// lock the user out of those apps. So a helper process (`runWatchdogIfAsked`)
/// clears it if this one dies or stops answering for 3 s, and a new engine
/// clears whatever a crashed one left.
public final class FrontGate {
    // MARK: LaunchServices

    private typealias CopyMeta = @convention(c) (Int32, CFString) -> Unmanaged<CFTypeRef>?
    private typealias SetMeta = @convention(c) (Int32, CFString, CFTypeRef) -> Int32
    private typealias CopyApps = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopyItem = @convention(c) (Int32, CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?

    private struct LS {
        let copyMeta: CopyMeta
        let setMeta: SetMeta
        let copyApps: CopyApps
        let copyItem: CopyItem
        let permittedKey: CFString
        let seedKey: CFString
    }

    /// The login session's apps (kLSDefaultSessionID).
    private static let session: Int32 = -2

    private static let ls: LS? = {
        let h = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY)
        func string(_ name: String) -> CFString? {
            dlsym(h, name).map { $0.assumingMemoryBound(to: CFString.self).pointee }
        }
        guard let copyMeta = dlsym(h, "_LSCopyMetaApplicationInformationItem"),
              let setMeta = dlsym(h, "_LSSetMetaApplicationInformationItem"),
              let copyApps = dlsym(h, "_LSCopyRunningApplicationArray"),
              let copyItem = dlsym(h, "_LSCopyApplicationInformationItem"),
              let permitted = string("_kLSPermittedFrontASNsArrayKey"),
              let seed = string("_kLSApplicationListSeedKey") else { return nil }
        return LS(copyMeta: unsafeBitCast(copyMeta, to: CopyMeta.self), setMeta: unsafeBitCast(setMeta, to: SetMeta.self),
                  copyApps: unsafeBitCast(copyApps, to: CopyApps.self), copyItem: unsafeBitCast(copyItem, to: CopyItem.self),
                  permittedKey: permitted, seedKey: seed)
    }()

    /// macOS has the calls this needs.
    public static var available: Bool { ls != nil }

    /// What the gate reads from and changes on this Mac, in one place so
    /// tests can stand in for all of it (and read nothing of the Mac's).
    struct System {
        var runningApps: () -> [App] = FrontGate.lsRunningApps
        var appListSeed: () -> Int64 = FrontGate.lsAppListSeed
        var currentList: () -> [CFTypeRef]? = FrontGate.lsCurrentList
        var setList: ([CFTypeRef]) -> Int32 = FrontGate.lsSetList
        var frontPid: () -> pid_t = { BCUFrontProcessPID() }
        /// WindowServer's own list (macOS 26 and later), changed one app at a time.
        var windowServerListAvailable: () -> Bool = { BCUPermittedFrontAvailable() }
        var processSerialNumber: (pid_t) -> UInt64 = { BCUProcessPSN($0) }
        var updateWindowServerList: (_ psn: UInt64, _ add: Bool) -> Int32 = { BCUPermittedFrontUpdate($0, $1) }
        /// Open this process's connection to WindowServer (calls to it open
        /// one when there's none).
        var connectWindowServer: () -> Void = { _ = BCUWindowServerConnect() }
        /// Not a background-only process (those never come to the front).
        var canComeForward: (pid_t) -> Bool = { NSRunningApplication(processIdentifier: $0)?.activationPolicy != .prohibited }
        /// Write a file in full; whether it was.
        var writeFile: (URL, String) -> Bool = { url, text in
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            return (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil
        }
    }

    /// How long WindowServer's list stays once no agent has an app to keep
    /// back: taking it down is one call per entry.
    nonisolated(unsafe) static var windowServerIdleClearMs = 30_000.0

    nonisolated(unsafe) static var system = System()

    /// The list as it is now, nil for none (everyone permitted).
    private static func currentList() -> [CFTypeRef]? { system.currentList() }
    private static func appListSeed() -> Int64 { system.appListSeed() }
    private static func runningApps() -> [App] { system.runningApps() }
    @discardableResult
    private static func setList(_ asns: [CFTypeRef]) -> Int32 { system.setList(asns) }

    /// About a microsecond.
    private static func lsCurrentList() -> [CFTypeRef]? {
        guard let ls, let list = ls.copyMeta(session, ls.permittedKey)?.takeRetainedValue() as? [CFTypeRef], !list.isEmpty else { return nil }
        return list
    }

    /// Changes whenever an app starts or quits. About a microsecond.
    private static func lsAppListSeed() -> Int64 {
        guard let ls else { return 0 }
        return (ls.copyMeta(session, ls.seedKey)?.takeRetainedValue() as? NSNumber)?.int64Value ?? 0
    }

    struct App {
        let asn: CFTypeRef
        let pid: pid_t
        let bundleID: String?
    }

    /// Every app LaunchServices knows, agents and menu bar items included.
    private static func lsRunningApps() -> [App] {
        guard let ls, let list = ls.copyApps(session)?.takeRetainedValue() as? [CFTypeRef] else { return [] }
        return list.map { asn in
            App(asn: asn,
                pid: (ls.copyItem(session, asn, "pid" as CFString)?.takeRetainedValue() as? NSNumber)?.int32Value ?? 0,
                bundleID: ls.copyItem(session, asn, kCFBundleIdentifierKey)?.takeRetainedValue() as? String)
        }
    }

    /// One round trip to launchservicesd, about a millisecond. LaunchServices'
    /// status: 0, or why not (on macOS 26.7 it's -10663, "attribute not
    /// settable", for a process without Apple's entitlement).
    private static func lsSetList(_ asns: [CFTypeRef]) -> Int32 {
        if let setListForTests { return setListForTests(asns) }
        guard let ls else { return -1 }
        return ls.setMeta(session, ls.permittedKey, asns as CFArray)
    }

    /// Tests stand in for a macOS that answers differently.
    nonisolated(unsafe) static var setListForTests: (([CFTypeRef]) -> Int32)?

    /// Whether the list in place (`now`) is the one this process set. Still
    /// so if LaunchServices dropped apps that quit since; not if it names an
    /// app this process didn't, or is a small part of it (someone else's).
    static func isOurs(_ now: [CFTypeRef], set: [CFTypeRef]) -> Bool {
        guard now.count * 2 >= set.count else { return false }
        return now.allSatisfy { a in set.contains { CFEqual($0, a) } }
    }

    // MARK: State

    /// What to keep from the front right now: asked on every pass (its own
    /// thread, every few ms while there's anything to keep back).
    public struct Targets: Equatable {
        public var pids: Set<pid_t> = []
        /// Apps being launched for an agent, before they have a pid.
        public var bundleIDs: Set<String> = []
        /// Of `pids`, the apps an agent's step is running in right now.
        public var stepping: Set<pid_t> = []
        public init(pids: Set<pid_t> = [], bundleIDs: Set<String> = [], stepping: Set<pid_t> = []) {
            self.pids = pids
            self.bundleIDs = bundleIDs
            self.stepping = stepping
        }
        var isEmpty: Bool { pids.isEmpty && bundleIDs.isEmpty }
    }

    public var targets: (() -> Targets)?
    /// Whether the input tap is delivering events. Without it nothing would
    /// open the gate for the user, so the gate stays open.
    public var tapWorking: (() -> Bool)?
    /// Something worth the guard's log (rare events only).
    public var onNote: ((String) -> Void)?

    private let lock = NSLock()
    /// The pids left off the list this process set, nil while it has set none.
    private var applied: Set<pid_t>?
    private var appliedList: [CFTypeRef] = []
    private var appliedSeed: Int64 = 0
    private var appliedTargets = Targets()
    /// LaunchServices refused the list (macOS 26 and later): WindowServer's
    /// own list is changed instead, one app at a time.
    private var useWindowServer = false
    /// Serial numbers this process put on WindowServer's list. They stay
    /// there after it dies, so each is in the marker file before it goes on.
    private var onWindowServerList: Set<UInt64> = []
    /// Anything of this process's on either list.
    private var hasListLocked: Bool { applied != nil || !onWindowServerList.isEmpty }
    /// Since when agents have needed nothing kept back (WindowServer's list).
    private var idleSinceMs: Double?
    private var liftedUntilMs = 0.0
    /// Open for a key: for everyone but the apps an agent is stepping in.
    private var keyLiftedUntilMs = 0.0
    /// The apps an agent was stepping in at the last pass.
    private var lastStepping: Set<pid_t> = []
    private var switcherOpen = false
    private var switcherSinceMs = 0.0
    private var pointerDown = false
    private var pointerSinceMs = 0.0
    /// Another process keeps a list of its own (a kiosk or exam app): hands off.
    private var foreign = false
    private var started = false
    private var stopping = false
    private var watchdog: Process?
    private var heartbeat: FileHandle?
    private var lastHeartbeatMs = 0.0
    private var watchdogFailures = 0
    /// Times in a row macOS turned the list down, or took it without keeping it.
    private var refusals = 0
    private static let maxRefusals = 3
    private var lastClearNoteMs = -Double.infinity
    private var stats = (applies: 0, lifts: 0, sinceMs: 0.0)
    /// Lock held: running for the input tap, which mustn't wait on the
    /// watchdog's record lock (see `fromTap`).
    private var inTap = false
    /// The tap's changes that had to wait, in the order the events came.
    private let tapQueue = DispatchQueue(label: "bcu.front-gate.tap", qos: .userInteractive)
    private let tapLock = NSLock()
    private var tapPending = 0
    /// How long the input tap waits for a pass to let go of the lock (one
    /// changing the list holds it for a call per app) before letting the
    /// event go on and opening the gate just after. Every event on the Mac
    /// waits with it, and macOS turns off a tap that's slow.
    private static let tapWaitS = 0.05

    /// The cmd+Tab switcher never keeps the gate open longer than this by itself.
    private static let switcherMaxMs = 30_000.0
    /// Nor a mouse button whose release the tap never saw.
    private static let pointerMaxMs = 60_000.0
    private static let markerName = "front-gate.on"
    static let watchdogFlag = "--bcu-front-gate-watchdog"

    private var markerURL: URL { Self.markerURL }
    /// There while this engine has (or is about to have) a list of its own
    /// in place. The watchdog clears a list only while it's there, so another
    /// app's list (a kiosk or exam app's) outlives this engine.
    private static var markerURL: URL { BCUPaths.supportDirectory.appendingPathComponent(markerName) }

    /// Whether the watchdog may clear the list it finds: only one this
    /// engine put there (its marker is in place).
    static func watchdogMayClear(markerExists: Bool, listExists: Bool) -> Bool { markerExists && listExists }

    public init() {}

    /// True while this process has a list in place.
    public var isOn: Bool {
        lock.lock(); defer { lock.unlock() }
        return applied != nil
    }

    /// Whether `pid` is being kept from the front right now.
    public func blocks(_ pid: pid_t) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return applied?.contains(pid) ?? false
    }

    // MARK: Lifecycle

    /// Any thread, once.
    public func start() {
        guard Self.available || Self.system.windowServerListAvailable() else {
            Log.info("gate: this macOS has no permitted-front list; apps that take the front are put back after the fact")
            return
        }
        // BCU_FRONT_GATE=0 at launch: no gate, as on a macOS that refuses it.
        if ProcessInfo.processInfo.environment["BCU_FRONT_GATE"] == "0" {
            Log.info("gate: off (BCU_FRONT_GATE=0); apps that take the front are put back after the fact")
            return
        }
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        lock.unlock()
        // Which engine runs now: an earlier engine's watchdog still trying
        // to take its entries off stops, and this one takes them over.
        _ = Self.system.writeFile(Self.engineURL, "\(getpid())\n")
        Self.clearLeftovers()
        adoptLeftovers()
        startWatchdog()
        let thread = Thread { [weak self] in
            while let self, self.pass() {}
        }
        thread.name = "bcu.gate"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// A list a crashed engine left (its watchdog should have cleared it).
    private static func clearLeftovers() {
        // (A note the last run's watchdog left its engine.)
        try? FileManager.default.removeItem(at: clearedURL)
        guard FileManager.default.fileExists(atPath: markerURL.path) else { return }
        let left = withRecordLock(wait: true) { () -> [UInt64] in
            let psns = readRecord()
            guard !psns.isEmpty else { return [] }
            let left = takeOffRecorded(psns)
            writeRecord(Set(left))
            Log.info("gate: took \(psns.count - left.count) entries an earlier run left off WindowServer's permitted-front list\(left.isEmpty ? "" : "; \(left.count) wouldn't come off and stay recorded")")
            return left
        } ?? []
        // Kept for the next try (the watchdog's, or the next launch's).
        guard left.isEmpty else { return }
        if currentList() != nil {
            setList([])
            Log.info("gate: cleared the permitted-front list an earlier run left behind")
        }
        try? FileManager.default.removeItem(at: markerURL)
    }

    static func clearLeftoversForTests() { clearLeftovers() }

    /// Entries the cleanup at launch couldn't take off are this engine's:
    /// LaunchServices reads them back as a list on 27.2, and taken for
    /// another app's they'd be left on (and their record dropped) for good.
    /// They come off with the rest of this engine's list.
    private func adoptLeftovers() {
        let left = Self.readRecord()
        guard !left.isEmpty, Self.system.windowServerListAvailable() else { return }
        lock.lock()
        useWindowServer = true
        onWindowServerList.formUnion(left)
        lock.unlock()
        Log.info("gate: \(left.count) entries an earlier run left on WindowServer's permitted-front list wouldn't come off; using that list, and they come off with the rest")
    }

    func adoptLeftoversForTests() { adoptLeftovers() }

    /// Take recorded entries off WindowServer's list. Those that wouldn't
    /// come off while their app still runs are returned, to stay recorded:
    /// one left alone on the list would keep every other app back.
    private static func takeOffRecorded(_ psns: [UInt64]) -> [UInt64] {
        var failed: [UInt64] = []
        for p in psns where system.updateWindowServerList(p, false) != 0 { failed.append(p) }
        guard !failed.isEmpty else { return [] }
        // Serial numbers aren't reused in a login session: an app that quit
        // took its entry with it.
        let running = Set(runningApps().map { system.processSerialNumber($0.pid) })
        return failed.filter(running.contains)
    }

    /// The serial numbers the marker file names (one per line, hex): what
    /// may be on WindowServer's list of this engine's.
    private static func readRecord() -> [UInt64] {
        guard let text = try? String(contentsOf: markerURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { UInt64($0, radix: 16) }
    }

    /// Written before an entry goes on, so a crash right after leaves a
    /// record for the watchdog or the next engine. Gone when nothing's left.
    @discardableResult
    private static func writeRecord(_ psns: Set<UInt64>) -> Bool {
        if psns.isEmpty {
            try? FileManager.default.removeItem(at: markerURL)
            return true
        }
        let text = psns.map { String($0, radix: 16) }.joined(separator: "\n") + "\n"
        return system.writeFile(markerURL, text)
    }

    /// Before the engine goes away: open the gate for good.
    public func stop() {
        lock.lock()
        stopping = true
        let cleared = !hasListLocked || clearLocked()
        let helper = watchdog
        watchdog = nil
        try? heartbeat?.close()
        heartbeat = nil
        lock.unlock()
        // The helper clears the list too as it goes (on the signal, or when
        // the pipe closes). If it's still there after all that, the marker
        // stays so that the next launch clears it.
        helper?.terminate()
        if cleared { try? FileManager.default.removeItem(at: markerURL) }
    }

    // MARK: Opening it for the user

    /// The user did something that may switch apps: open the gate for `ms`.
    /// Called from the input tap before the event goes on, so by the time
    /// WindowServer acts on it the list is gone. Costs a lock when the gate
    /// is open anyway, about a millisecond when it has to clear the list.
    public func lift(ms: Double) {
        lock.lock()
        liftedUntilMs = max(liftedUntilMs, nowMs() + ms)
        openForUserLocked()
        lock.unlock()
    }

    /// A key that may switch apps (Return, a shortcut, a function key): every
    /// app goes through but those an agent's step is running in right now.
    /// What comes forward from those then is almost always the agent's doing
    /// (Return on a link into that browser at that very moment opens it
    /// without bringing it forward). A click lets everyone through: it may be
    /// on that app's window.
    public func liftForKey(ms: Double) {
        let now = nowMs()
        fromTap {
            self.keyLiftedUntilMs = max(self.keyLiftedUntilMs, now + ms)
            self.openForUserLocked(keeping: self.lastStepping)
        }
    }

    /// For the input tap: run `body` with the lock held, right away if the
    /// lock comes within `tapWaitS`, else just after on `tapQueue`, so a
    /// pass changing the list never holds up every event on the Mac.
    /// After one has waited, the next go after it, in order.
    private func fromTap(_ body: @escaping () -> Void) {
        tapLock.lock(); let behind = tapPending > 0; tapLock.unlock()
        if !behind && lock.lock(before: Date(timeIntervalSinceNow: Self.tapWaitS)) {
            inTap = true
            body()
            inTap = false
            lock.unlock()
            return
        }
        laterOffTap(body)
    }

    /// Run `body` with the lock held on `tapQueue`, after the tap's earlier
    /// changes: what the tap can't do without waiting.
    private func laterOffTap(_ body: @escaping () -> Void) {
        tapLock.lock(); tapPending += 1; tapLock.unlock()
        tapQueue.async {
            self.lock.lock(); body(); self.lock.unlock()
            self.tapLock.lock(); self.tapPending -= 1; self.tapLock.unlock()
        }
    }

    /// Lock held. Let every app through but `keeping`: LaunchServices' list
    /// goes (or is set again without them); on WindowServer's, the apps kept
    /// back go on (one call each, where taking everyone else off would be one
    /// per running app).
    private func openForUserLocked(keeping: Set<pid_t> = []) {
        guard let held = applied else { return }
        let keep = held.intersection(keeping)
        guard keep != held else { return }
        stats.lifts += 1
        guard useWindowServer else {
            if keep.isEmpty { clearLocked() } else { applyLocked(Targets(pids: keep), seed: appliedSeed) }
            return
        }
        let recorded = Self.withRecordLock(wait: !inTap) { () -> Bool in
            // The watchdog took the list down (after a stall): adding the
            // apps kept back to what's left would let only them through.
            // Leave it down; the next pass after this moment puts it back up.
            if noteWatchdogClearLocked() { return false }
            let psns = held.subtracting(keep).map(Self.system.processSerialNumber).filter { $0 != 0 && !onWindowServerList.contains($0) }
            // An entry with no record could outlive this process with nothing
            // to take it off: the rest of the list would come off and leave
            // it alone on it, keeping every other app back.
            guard Self.writeRecord(onWindowServerList.union(psns)) else { return false }
            var allOn = true
            for p in psns {
                if Self.system.updateWindowServerList(p, true) == 0 { onWindowServerList.insert(p) } else { allOn = false }
            }
            return allOn
        }
        if recorded == nil && inTap {
            // The watchdog has the record lock: it's taking the list down.
            laterOffTap { self.openForUserLocked(keeping: keeping) }
            return
        }
        guard recorded == true else {
            // Can't let them through by adding (no record, or WindowServer
            // refused): take the whole list down.
            clearLocked()
            return
        }
        applied = keep.isEmpty ? nil : keep
        appliedTargets = Targets(pids: keep)
    }

    /// Run `body` holding the lock the watchdog takes before its cleanup, so
    /// neither sees the other's list and record half changed. `wait` false:
    /// nil if someone holds it. A lock file that can't be opened runs `body`
    /// without it.
    static func withRecordLock<T>(wait: Bool, _ body: () -> T) -> T? {
        try? FileManager.default.createDirectory(at: BCUPaths.supportDirectory, withIntermediateDirectories: true)
        let fd = open(BCUPaths.supportDirectory.appendingPathComponent("front-gate.lock").path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { return body() }
        defer { close(fd) }
        guard flock(fd, wait ? LOCK_EX : LOCK_EX | LOCK_NB) == 0 else { return nil }
        defer { flock(fd, LOCK_UN) }
        return body()
    }

    /// The watchdog left this after a cleanup: the engine's next pass
    /// starts again from what's still recorded.
    private static var clearedURL: URL { BCUPaths.supportDirectory.appendingPathComponent("front-gate.cleared") }

    /// Lock held. The watchdog took this engine's entries off (after a
    /// stall), all of them or some: it says so in a file of its own. A record
    /// that's merely gone was deleted from outside (a cleanup app emptying
    /// the folder), and the entries are still on.
    private var watchdogClearedLocked: Bool {
        FileManager.default.fileExists(atPath: Self.clearedURL.path)
    }

    /// Lock held. Entries on with no record: written again, or a crash would
    /// leave them on with nothing to take them off, and every app launched
    /// after that would be refused the front until the user logs out.
    private var recordMissingLocked: Bool {
        !onWindowServerList.isEmpty && !FileManager.default.fileExists(atPath: markerURL.path)
    }

    /// Lock and record lock held. Pick up what the watchdog took off: only
    /// what it couldn't is on any more.
    @discardableResult
    private func noteWatchdogClearLocked() -> Bool {
        guard watchdogClearedLocked else { return false }
        // What it couldn't take off is still on, and still recorded.
        onWindowServerList = Set(Self.readRecord())
        try? FileManager.default.removeItem(at: Self.clearedURL)
        applied = nil
        appliedTargets = Targets()
        appliedSeed = 0
        return true
    }

    /// cmd+Tab went down (open) or command came up (closed): the switch
    /// happens when command is released, however long the user holds it.
    public func switcher(open: Bool) {
        let now = nowMs()
        fromTap {
            if open {
                if !self.switcherOpen { self.switcherSinceMs = now }
                self.switcherOpen = true
                self.openForUserLocked()
            } else if self.switcherOpen {
                self.switcherOpen = false
                // The app comes forward a moment after the key comes up.
                self.liftedUntilMs = max(self.liftedUntilMs, now + 700)
            }
        }
    }

    /// A mouse button went down, or came up: open for as long as it's held
    /// and `ms` after. What a drag is let go on can come forward (a file on
    /// a Dock icon, an item of a Dock menu), however long the drag took.
    public func pointer(down: Bool, ms: Double) {
        let now = nowMs()
        fromTap {
            if down {
                if !self.pointerDown { self.pointerSinceMs = now }
                self.pointerDown = true
                self.openForUserLocked()
            } else {
                self.pointerDown = false
            }
            self.liftedUntilMs = max(self.liftedUntilMs, now + ms)
        }
    }

    public var isLifted: Bool {
        lock.lock(); defer { lock.unlock() }
        return liftedLocked(nowMs())
    }

    private func liftedLocked(_ now: Double) -> Bool {
        if switcherOpen && now - switcherSinceMs > Self.switcherMaxMs { switcherOpen = false }
        if pointerDown && now - pointerSinceMs > Self.pointerMaxMs { pointerDown = false }
        return now < liftedUntilMs || switcherOpen || pointerDown
    }

    // MARK: Keeping the list

    /// One pass; false to end the thread.
    private func pass() -> Bool {
        guard let pause = step() else { return false }
        usleep(pause)
        return true
    }

    /// Bring the list in line with `targets` right now, on the caller's
    /// thread: before asking an app for something that makes it come forward.
    /// The gate's own thread looks only every 100 ms while there's nothing
    /// to keep back, and a browser asked for a window shows it sooner than
    /// that (measured: in front for 25 ms on a session's first window). Not
    /// with a lock held that `targets` takes.
    public func sync() {
        lock.lock()
        let running = started && !stopping
        lock.unlock()
        if running { _ = step() }
    }

    /// One at a time: a pass that read `targets` before another applied
    /// newer ones would put the older list back.
    private let stepLock = NSLock()

    /// One pass as the gate's thread makes it, for tests.
    func passForTests() -> Bool { step() != nil }

    /// Apply the list once. How long the thread should wait before the next
    /// look (µs), or nil when the gate is shutting down.
    private func step() -> UInt32? {
        stepLock.lock(); defer { stepLock.unlock() }
        let want = targets?() ?? Targets()
        let tapOK = tapWorking?() ?? false
        let front = Self.system.frontPid()
        let now = nowMs()
        lock.lock()
        if stopping { lock.unlock(); return nil }
        beat(now)
        // On WindowServer's list LaunchServices reads back this process's own
        // entries as a list; and it counts adds, so another app's entries and
        // these don't undo each other. Nothing to tell apart there.
        let current = useWindowServer ? nil : Self.currentList()
        // A list that isn't this process's: someone else is deciding who may
        // be in front. Leave it alone, and take no part until it's gone.
        if let current, applied == nil || !Self.isOurs(current, set: appliedList) {
            if !foreign {
                foreign = true
                applied = nil
                appliedList = []
                // Not this engine's any more: the watchdog must leave it too.
                try? FileManager.default.removeItem(at: markerURL)
                DispatchQueue.global().async { self.onNote?("another app keeps a list of the apps allowed in front; not touching it, so an agent's app that takes the front is put back after the fact") }
            }
            lock.unlock()
            return 200_000
        }
        if foreign { foreign = false }
        let open = !tapOK || liftedLocked(now)
        let keyOpen = now < keyLiftedUntilMs
        lastStepping = want.stepping
        /// What to keep back of `t` now: nothing while open for the user;
        /// while open for a key, only the apps an agent is stepping in.
        func narrowed(_ t: Targets) -> Targets {
            if open { return Targets() }
            var t = t
            t.stepping = []
            if keyOpen { t.pids.formIntersection(want.stepping); t.bundleIDs = [] }
            return t
        }
        if useWindowServer {
            // The watchdog took this engine's entries off (after a stall).
            // Or the record went from outside: put it back.
            if watchdogClearedLocked || recordMissingLocked {
                _ = Self.withRecordLock(wait: true) { () -> Bool in
                    if noteWatchdogClearLocked() { return true }
                    if recordMissingLocked { Self.writeRecord(onWindowServerList) }
                    return false
                }
            }
            var held = want
            held.pids.remove(front)
            held.pids.remove(getpid())
            if want.isEmpty { if idleSinceMs == nil { idleSinceMs = now } } else { idleSinceMs = nil }
            if let since = idleSinceMs, now - since >= Self.windowServerIdleClearMs {
                // Taking the list down is one call per entry, and an app
                // already off is refused until the rest are: only once
                // agents have needed nothing kept back for a while.
                if hasListLocked { clearLocked() }
            } else if hasListLocked || !held.isEmpty {
                // Everyone on (the apps kept back too) while it's open for
                // the user, while there's nothing to keep back, and while the
                // app kept back is in front anyway (the guard puts the user's
                // app back, which is on the list).
                let target = held.isEmpty ? Targets() : narrowed(held)
                let seed = Self.appListSeed()
                if onWindowServerList.isEmpty || target != appliedTargets || seed != appliedSeed { applyWindowServerLocked(target, seed: seed) }
            }
        } else {
            // The list was cleared from outside (the watchdog, after a stall).
            if current == nil && applied != nil { applied = nil; appliedList = [] }
            var wanted = narrowed(want)
            // Never the app in front: whoever is there now, the user sees it.
            wanted.pids.remove(front)
            wanted.pids.remove(getpid())
            if wanted.isEmpty {
                if applied != nil { clearLocked() }
            } else {
                let seed = Self.appListSeed()
                if applied == nil || wanted != appliedTargets || seed != appliedSeed { applyLocked(wanted, seed: seed) }
            }
        }
        let active = hasListLocked || !want.isEmpty
        lock.unlock()
        // A new app must be on the list before it finishes launching, and an
        // agent's app off it before it next shows a window.
        return active ? 5_000 : 100_000
    }

    /// Lock held.
    private func applyLocked(_ wanted: Targets, seed: Int64) {
        let apps = Self.runningApps()
        let out = Set(apps.filter { wanted.pids.contains($0.pid) || ($0.bundleID.map(wanted.bundleIDs.contains) ?? false) }.map(\.pid))
        appliedTargets = wanted
        appliedSeed = seed
        guard !out.isEmpty, out.count < apps.count else {
            // None of them is running (yet): nothing to keep back.
            if applied != nil { clearLocked() }
            return
        }
        if applied == nil {
            // Before the list exists, so a crash right after is cleaned up.
            try? FileManager.default.createDirectory(at: BCUPaths.supportDirectory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: markerURL.path, contents: nil)
        }
        let permitted = apps.filter { !out.contains($0.pid) }.map(\.asn)
        let status = Self.setList(permitted)
        // Taken, and really there: a macOS that answers 0 and keeps no list
        // would have this run on every pass for nothing.
        if status == 0, let now = Self.currentList(), Self.isOurs(now, set: permitted) {
            applied = out
            appliedList = permitted
            stats.applies += 1
            refusals = 0
            return
        }
        if applied != nil || Self.currentList() != nil { clearLocked() }
        // macOS 26 and later keep the list in WindowServer, which takes it
        // from anyone one app at a time.
        if Self.system.windowServerListAvailable() {
            useWindowServer = true
            refusals = 0
            DispatchQueue.global().async { Log.info("gate: LaunchServices won't take the permitted-front list (status \(status)); using WindowServer's") }
            applyWindowServerLocked(wanted, seed: seed)
            return
        }
        refusals += 1
        guard refusals >= Self.maxRefusals else { return }
        giveUpLocked(status)
    }

    /// Lock held. WindowServer's list: every running app on it but the ones
    /// kept back (none while it's open for the user).
    private func applyWindowServerLocked(_ target: Targets, seed: Int64) {
        let apps = Self.runningApps()
        let out = Set(apps.filter { target.pids.contains($0.pid) || ($0.bundleID.map(target.bundleIDs.contains) ?? false) }.map(\.pid))
        appliedTargets = target
        appliedSeed = seed
        if out.isEmpty && !target.isEmpty {
            // None of them is running (yet): nothing to keep back.
            if hasListLocked { clearLocked() }
            return
        }
        var everyone = Set<UInt64>(), want = Set<UInt64>()
        for app in apps {
            let p = Self.system.processSerialNumber(app.pid)
            guard p != 0 else { continue }
            everyone.insert(p)
            // (Background-only processes never come forward: no call for them.)
            if !out.contains(app.pid) && Self.system.canComeForward(app.pid) { want.insert(p) }
        }
        guard !want.isEmpty else {
            if hasListLocked { clearLocked() }
            return
        }
        let status = Self.withRecordLock(wait: true) { () -> Int32 in
            noteWatchdogClearLocked()
            var status: Int32 = 0
            var adds = want.subtracting(onWindowServerList)
            // No entry goes on without a record (see `openForUserLocked`).
            if !adds.isEmpty && !Self.writeRecord(onWindowServerList.union(adds)) {
                adds = []
                status = -2
            }
            // The app in front first: once the list holds anyone, WindowServer
            // drops a front app that isn't on it ("no longer permitted
            // frontmost"), and no app is in front until the user switches.
            let front = Self.system.processSerialNumber(Self.system.frontPid())
            let ordered = adds.contains(front) ? [front] + adds.filter { $0 != front } : Array(adds)
            for p in ordered {
                let r = Self.system.updateWindowServerList(p, true)
                if r == 0 { onWindowServerList.insert(p) } else { status = r }
            }
            for p in onWindowServerList.subtracting(want) {
                let r = Self.system.updateWindowServerList(p, false)
                // An app that quit took its entry with it.
                if r == 0 || !everyone.contains(p) { onWindowServerList.remove(p) } else { status = r }
            }
            Self.writeRecord(onWindowServerList)
            return status
        } ?? -3
        applied = out.isEmpty || onWindowServerList.isEmpty ? nil : out
        if status == 0 {
            refusals = 0
            stats.applies += 1
            return
        }
        // Asked again on the next pass.
        appliedSeed = 0
        refusals += 1
        guard refusals >= Self.maxRefusals else { return }
        clearLocked()
        giveUpLocked(status)
    }

    /// Lock held. This macOS doesn't let the list be set: no gate here, for
    /// as long as this process runs. The guard puts apps back after the fact.
    private func giveUpLocked(_ status: Int32) {
        stopping = true
        let helper = watchdog
        watchdog = nil
        try? heartbeat?.close()
        heartbeat = nil
        // (Entries that wouldn't come off stay recorded for the next engine.)
        if onWindowServerList.isEmpty { try? FileManager.default.removeItem(at: markerURL) }
        DispatchQueue.global().async {
            helper?.terminate()
            Log.info("gate: macOS won't take the permitted-front list (status \(status)); the gate is off, and an agent's app that takes the front is put back after the fact")
        }
    }

    /// Lock held. False if the list is still there: then this process still
    /// counts it as its own, so every later pass, `lift` and `stop` ask again
    /// (forgetting it would make the next pass take it for another app's
    /// list and leave it alone for good).
    /// Lock held, and the record lock if it could be had. Every entry of
    /// this engine's off WindowServer's list, the one of the app in front
    /// last: until the list is gone, an app already off it is refused the front.
    private func takeOffAllLocked() {
        noteWatchdogClearLocked()
        var everyone: Set<UInt64>?
        let front = Self.system.processSerialNumber(Self.system.frontPid())
        let others: [UInt64] = onWindowServerList.filter { $0 != front }.sorted()
        let order: [UInt64] = onWindowServerList.contains(front) ? others + [front] : others
        for p in order {
            if Self.system.updateWindowServerList(p, false) == 0 { onWindowServerList.remove(p); continue }
            // An app that quit took its entry with it.
            if everyone == nil { everyone = Set(Self.runningApps().map { Self.system.processSerialNumber($0.pid) }) }
            if everyone?.contains(p) == false { onWindowServerList.remove(p) }
        }
        Self.writeRecord(onWindowServerList)
    }

    @discardableResult
    private func clearLocked() -> Bool {
        if useWindowServer {
            let locked: Bool? = Self.withRecordLock(wait: !inTap) { () -> Bool in
                takeOffAllLocked()
                return true
            }
            if locked == nil && inTap {
                // The watchdog has the record lock (see `openForUserLocked`).
                laterOffTap { self.clearLocked() }
                return false
            }
            if locked == nil { takeOffAllLocked() }
            applied = nil
            appliedTargets = Targets()
            if onWindowServerList.isEmpty { return true }
        } else {
            for _ in 0..<2 {
                if Self.setList([]) == 0 || Self.currentList() == nil {
                    applied = nil
                    appliedList = []
                    return true
                }
            }
        }
        let now = nowMs()
        if now - lastClearNoteMs > 5000 {
            lastClearNoteMs = now
            DispatchQueue.global().async { Log.info("gate: couldn't clear the permitted-front list; trying again") }
        }
        return false
    }

    // MARK: Watchdog

    /// A list left in place would keep the user out of those apps until they
    /// log out. The helper clears it when this process dies (its pipe closes)
    /// or hangs (no byte for 3 s).
    private func startWatchdog() {
        // The heartbeat is written to a pipe whose other end goes when the
        // helper dies: that must be an error to act on (`beat` clears the
        // list), not a signal that kills this process with the list in place.
        signal(SIGPIPE, SIG_IGN)
        guard let exe = Bundle.main.executableURL ?? URL(string: CommandLine.arguments[0]).map({ URL(fileURLWithPath: $0.path) }) else { return }
        let p = Process()
        p.executableURL = exe
        p.arguments = [Self.watchdogFlag]
        let pipe = Pipe()
        p.standardInput = pipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in self?.watchdogDied() }
        do {
            try p.run()
        } catch {
            Log.info("gate: couldn't start the watchdog (\(error)); the gate stays open")
            lock.lock(); stopping = true; lock.unlock()
            return
        }
        lock.lock()
        watchdog = p
        heartbeat = pipe.fileHandleForWriting
        lock.unlock()
    }

    private func watchdogDied() {
        lock.lock()
        let wasStopping = stopping
        watchdog = nil
        heartbeat = nil
        watchdogFailures += 1
        let giveUp = watchdogFailures > 3
        if hasListLocked { clearLocked() }
        if giveUp { stopping = true }
        lock.unlock()
        guard !wasStopping else { return }
        if giveUp {
            Log.info("gate: the watchdog keeps dying; the gate stays open")
            return
        }
        Log.info("gate: the watchdog went away; starting another")
        startWatchdog()
    }

    /// Lock held. Without a watchdog listening there is no list.
    private func beat(_ now: Double) {
        guard now - lastHeartbeatMs > 400 else { return }
        lastHeartbeatMs = now
        guard let heartbeat else {
            if hasListLocked { clearLocked() }
            return
        }
        var byte: UInt8 = 1
        if write(heartbeat.fileDescriptor, &byte, 1) != 1, hasListLocked { clearLocked() }
        if now - stats.sinceMs > 60_000 {
            if stats.applies > 0 || stats.lifts > 0 {
                Log.info("gate: in the last minute, set the list \(stats.applies) times and opened it for the user \(stats.lifts) times")
            }
            stats = (0, 0, now)
        }
    }

    /// The watchdog's cleanup: the list this engine left, if any. Whether
    /// it ran (false: try again shortly).
    @discardableResult
    static func watchdogClear() -> Bool {
        let marker = markerURL.path
        // WindowServer's list: the entries the engine recorded, and the
        // record (the engine sees it gone and starts again from nothing).
        // Never in the middle of the engine's update (it holds the lock
        // from reading the record to writing it again): try again shortly.
        // 0: no record; 1: all off; 2: some wouldn't come off (kept recorded).
        let took = withRecordLock(wait: false) { () -> Int in
            let psns = readRecord()
            guard !psns.isEmpty else { return 0 }
            let left = takeOffRecorded(psns)
            writeRecord(Set(left))
            // For the engine, if it's still there: it starts again from the record.
            FileManager.default.createFile(atPath: clearedURL.path, contents: nil)
            return left.isEmpty ? 1 : 2
        }
        guard let took, took != 2 else { return false }
        if took == 1 { return true }
        guard watchdogMayClear(markerExists: FileManager.default.fileExists(atPath: marker), listExists: currentList() != nil) else { return true }
        setList([])
        if currentList() == nil { try? FileManager.default.removeItem(atPath: marker) }
        return true
    }

    /// Whether the watchdog, its engine gone, keeps trying to take recorded
    /// entries off. `owner`: the engine that last started (nil: none since).
    /// `toldToGo`: a SIGTERM, SIGINT or SIGHUP came.
    static func watchdogKeepsTrying(cleared: Bool, owner: pid_t?, engine: pid_t, toldToGo: Bool = false) -> Bool {
        !cleared && !toldToGo && (owner == nil || owner == engine)
    }

    private static var engineURL: URL { BCUPaths.supportDirectory.appendingPathComponent("front-gate.engine") }

    /// The watchdog's first moments, while its engine runs. Its connection
    /// to WindowServer is opened now: one first opened while WindowServer
    /// handles the engine's death (a kill -9) is dropped after its first
    /// call, and every entry after the first would stay on the list.
    static func watchdogStarting() {
        if system.windowServerListAvailable() { system.connectWindowServer() }
    }

    /// Call first thing in `main`: when this process was started as the
    /// gate's watchdog, it runs that and never returns.
    public static func runWatchdogIfAsked() {
        guard CommandLine.arguments.contains(watchdogFlag) else { return }
        signal(SIGPIPE, SIG_IGN)
        // Told to go (the engine's `stop`, or `pkill` by name, which hits
        // both processes): clear on the way out, like on any other exit.
        // The handler only sets a flag; `poll` returns when a signal lands.
        for s in [SIGTERM, SIGINT, SIGHUP] { signal(s) { _ in watchdogToldToGo = 1 } }
        let engine = getppid()
        watchdogStarting()
        /// On the way out: until every recorded entry is off (the engine may
        /// be finishing an update, or an entry won't come off yet), or a new
        /// engine has started and taken them over.
        func clear() {
            var pause: UInt32 = 20_000
            while true {
                let cleared = watchdogClear()
                let owner = (try? String(contentsOf: engineURL, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                guard watchdogKeepsTrying(cleared: cleared, owner: owner, engine: engine, toldToGo: watchdogToldToGo != 0) else { return }
                usleep(pause)
                pause = min(pause * 2, 2_000_000)
            }
        }
        var fd = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
        var buffer = [UInt8](repeating: 0, count: 64)
        while true {
            if watchdogToldToGo != 0 { clear(); exit(0) }
            fd.revents = 0
            let r = poll(&fd, 1, 3000)
            if watchdogToldToGo != 0 { clear(); exit(0) }
            if r == 0 {
                // The engine hasn't answered for 3 s: let the user through.
                // One try (the next comes in 3 s): the engine may be back.
                watchdogClear()
                continue
            }
            if r < 0 {
                if errno == EINTR { continue }
                clear()
                exit(0)
            }
            if read(0, &buffer, buffer.count) <= 0 {
                // The engine is gone.
                clear()
                exit(0)
            }
        }
    }
}

/// Set by the watchdog's signal handlers (see `runWatchdogIfAsked`).
nonisolated(unsafe) private var watchdogToldToGo: sig_atomic_t = 0
