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

    /// The list as it is now, nil for none (everyone permitted). About a microsecond.
    private static func currentList() -> [CFTypeRef]? {
        guard let ls, let list = ls.copyMeta(session, ls.permittedKey)?.takeRetainedValue() as? [CFTypeRef], !list.isEmpty else { return nil }
        return list
    }

    /// Changes whenever an app starts or quits. About a microsecond.
    private static func appListSeed() -> Int64 {
        guard let ls else { return 0 }
        return (ls.copyMeta(session, ls.seedKey)?.takeRetainedValue() as? NSNumber)?.int64Value ?? 0
    }

    private struct App {
        let asn: CFTypeRef
        let pid: pid_t
        let bundleID: String?
    }

    /// Every app LaunchServices knows, agents and menu bar items included.
    private static func runningApps() -> [App] {
        guard let ls, let list = ls.copyApps(session)?.takeRetainedValue() as? [CFTypeRef] else { return [] }
        return list.map { asn in
            App(asn: asn,
                pid: (ls.copyItem(session, asn, "pid" as CFString)?.takeRetainedValue() as? NSNumber)?.int32Value ?? 0,
                bundleID: ls.copyItem(session, asn, kCFBundleIdentifierKey)?.takeRetainedValue() as? String)
        }
    }

    /// One round trip to launchservicesd, about a millisecond.
    @discardableResult
    private static func setList(_ asns: [CFTypeRef]) -> Bool {
        guard let ls else { return false }
        return ls.setMeta(session, ls.permittedKey, asns as CFArray) == 0
    }

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
        public init(pids: Set<pid_t> = [], bundleIDs: Set<String> = []) {
            self.pids = pids
            self.bundleIDs = bundleIDs
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
    private var liftedUntilMs = 0.0
    private var switcherOpen = false
    private var switcherSinceMs = 0.0
    /// Another process keeps a list of its own (a kiosk or exam app): hands off.
    private var foreign = false
    private var started = false
    private var stopping = false
    private var watchdog: Process?
    private var heartbeat: FileHandle?
    private var lastHeartbeatMs = 0.0
    private var watchdogFailures = 0
    private var stats = (applies: 0, lifts: 0, sinceMs: 0.0)

    /// The cmd+Tab switcher never keeps the gate open longer than this by itself.
    private static let switcherMaxMs = 30_000.0
    private static let markerName = "front-gate.on"
    static let watchdogFlag = "--bcu-front-gate-watchdog"

    private var markerURL: URL { BCUPaths.supportDirectory.appendingPathComponent(Self.markerName) }

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
        guard Self.available else {
            Log.info("gate: this macOS has no permitted-front list; apps that take the front are put back after the fact")
            return
        }
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        lock.unlock()
        // A list a crashed engine left (its watchdog should have cleared it).
        if FileManager.default.fileExists(atPath: markerURL.path) {
            if Self.currentList() != nil {
                Self.setList([])
                Log.info("gate: cleared the permitted-front list an earlier run left behind")
            }
            try? FileManager.default.removeItem(at: markerURL)
        }
        startWatchdog()
        let thread = Thread { [weak self] in
            while let self, self.pass() {}
        }
        thread.name = "bcu.gate"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Before the engine goes away: open the gate for good.
    public func stop() {
        lock.lock()
        stopping = true
        if applied != nil { clearLocked() }
        let helper = watchdog
        watchdog = nil
        try? heartbeat?.close()
        heartbeat = nil
        lock.unlock()
        helper?.terminate()
        try? FileManager.default.removeItem(at: markerURL)
    }

    // MARK: Opening it for the user

    /// The user did something that may switch apps: open the gate for `ms`.
    /// Called from the input tap before the event goes on, so by the time
    /// WindowServer acts on it the list is gone. Costs a lock when the gate
    /// is open anyway, about a millisecond when it has to clear the list.
    public func lift(ms: Double) {
        lock.lock()
        liftedUntilMs = max(liftedUntilMs, nowMs() + ms)
        if applied != nil {
            clearLocked()
            stats.lifts += 1
        }
        lock.unlock()
    }

    /// cmd+Tab went down (open) or command came up (closed): the switch
    /// happens when command is released, however long the user holds it.
    public func switcher(open: Bool) {
        lock.lock()
        if open {
            if !switcherOpen { switcherSinceMs = nowMs() }
            switcherOpen = true
            if applied != nil { clearLocked(); stats.lifts += 1 }
        } else if switcherOpen {
            switcherOpen = false
            // The app comes forward a moment after the key comes up.
            liftedUntilMs = max(liftedUntilMs, nowMs() + 700)
        }
        lock.unlock()
    }

    public var isLifted: Bool {
        lock.lock(); defer { lock.unlock() }
        return liftedLocked(nowMs())
    }

    private func liftedLocked(_ now: Double) -> Bool {
        if switcherOpen && now - switcherSinceMs > Self.switcherMaxMs { switcherOpen = false }
        return now < liftedUntilMs || switcherOpen
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

    /// Apply the list once. How long the thread should wait before the next
    /// look (µs), or nil when the gate is shutting down.
    private func step() -> UInt32? {
        stepLock.lock(); defer { stepLock.unlock() }
        let want = targets?() ?? Targets()
        let tapOK = tapWorking?() ?? false
        let front = BCUFrontProcessPID()
        let now = nowMs()
        lock.lock()
        if stopping { lock.unlock(); return nil }
        beat(now)
        let current = Self.currentList()
        // A list that isn't this process's: someone else is deciding who may
        // be in front. Leave it alone, and take no part until it's gone.
        if let current, applied == nil || !Self.isOurs(current, set: appliedList) {
            if !foreign {
                foreign = true
                applied = nil
                appliedList = []
                DispatchQueue.global().async { self.onNote?("another app keeps a list of the apps allowed in front; not touching it, so an agent's app that takes the front is put back after the fact") }
            }
            lock.unlock()
            return 200_000
        }
        if foreign { foreign = false }
        // The list was cleared from outside (the watchdog, after a stall).
        if current == nil && applied != nil { applied = nil; appliedList = [] }

        let open = !tapOK || liftedLocked(now)
        var wanted = open ? Targets() : want
        // Never the app in front: whoever is there now, the user sees it.
        wanted.pids.remove(front)
        wanted.pids.remove(getpid())
        if wanted.isEmpty {
            if applied != nil { clearLocked() }
        } else {
            let seed = Self.appListSeed()
            if applied == nil || wanted != appliedTargets || seed != appliedSeed { applyLocked(wanted, seed: seed) }
        }
        let active = applied != nil || !want.isEmpty
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
        if Self.setList(permitted) {
            applied = out
            appliedList = permitted
            stats.applies += 1
        } else if applied != nil {
            clearLocked()
        }
    }

    /// Lock held.
    private func clearLocked() {
        Self.setList([])
        applied = nil
        appliedList = []
    }

    // MARK: Watchdog

    /// A list left in place would keep the user out of those apps until they
    /// log out. The helper clears it when this process dies (its pipe closes)
    /// or hangs (no byte for 3 s).
    private func startWatchdog() {
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
        if applied != nil { clearLocked() }
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
            if applied != nil { clearLocked() }
            return
        }
        var byte: UInt8 = 1
        if write(heartbeat.fileDescriptor, &byte, 1) != 1, applied != nil { clearLocked() }
        if now - stats.sinceMs > 60_000 {
            if stats.applies > 0 || stats.lifts > 0 {
                Log.info("gate: in the last minute, set the list \(stats.applies) times and opened it for the user \(stats.lifts) times")
            }
            stats = (0, 0, now)
        }
    }

    /// Call first thing in `main`: when this process was started as the
    /// gate's watchdog, it runs that and never returns.
    public static func runWatchdogIfAsked() {
        guard CommandLine.arguments.contains(watchdogFlag) else { return }
        signal(SIGPIPE, SIG_IGN)
        func clear() {
            if currentList() != nil { setList([]) }
        }
        var fd = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
        var buffer = [UInt8](repeating: 0, count: 64)
        while true {
            fd.revents = 0
            let r = poll(&fd, 1, 3000)
            if r == 0 {
                // The engine hasn't answered for 3 s: let the user through.
                clear()
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
