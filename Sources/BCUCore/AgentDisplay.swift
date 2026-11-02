import AppKit
import CoreGraphics
import CPrivate

/// An agent's private display. Each agent session gets its own. The first
/// touches the user's displays at a single corner (bottom-right of their
/// union) and each further one touches the one before it at its corner, so
/// the cursor can only reach them at one point, and the input tap fences
/// even that off.
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
        let used = Set(running.map(\.slot))
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
        let ours = Set(registry.compactMap { $0.display?.displayID })
        registryLock.unlock()
        let ids = onlineDisplayIDs().filter { !ours.contains($0) && isBCUDisplay($0) }
        registryLock.lock()
        strayCache = (now, ids)
        registryLock.unlock()
        return ids
    }

    /// Every display the cursor must stay off: ours and strays.
    public static var fencedBounds: [CGRect] {
        running.map(\.liveBounds) + strayIDs.map { CGDisplayBounds($0) }
    }

    /// The fenced display a global point is on.
    public static func fenced(at p: CGPoint) -> CGRect? {
        fencedBounds.first { $0.contains(p) }
    }

    private static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(32, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    private static var callbackInstalled = false

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
        // Registered right away so a display starting at the same time
        // (another session, while this one waits) takes another slot.
        Self.registryLock.lock()
        Self.registry.removeAll { $0.display == nil || $0.display === self }
        Self.registry.append(Ref(self))
        Self.strayCache.atMs = -1
        if !Self.callbackInstalled {
            Self.callbackInstalled = true
            CGDisplayRegisterReconfigurationCallback(reconfigurationCallback, nil)
        }
        Self.registryLock.unlock()
    }

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
        useRetinaMode()
        place()
        Log.info("agent display \(slot + 1) (\(displayID)) at \(bounds.short); user displays \(userBounds.short)")
    }

    /// Main thread.
    public func stop() {
        defer { unreserve() }
        guard display != nil else { return }
        display?.invalidate()
        display = nil
        let id = displayID
        displayID = 0
        bounds = .zero
        Self.registryLock.lock()
        Self.registry.removeAll { $0.display == nil || $0.display === self }
        Self.strayCache.atMs = -1
        Self.registryLock.unlock()
        Log.info("agent display \(slot + 1) (\(id)) removed")
        // The ones after it move up the staircase.
        for d in Self.running { d.reconfigured() }
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
        var strays = Self.strayIDs.filter { $0 != displayID }.map { CGDisplayBounds($0) }
        while let i = strays.firstIndex(where: { $0.origin == corner }) {
            corner = CGPoint(x: strays[i].maxX, y: strays[i].maxY)
            strays.remove(at: i)
        }
        return corner
    }

    private func computeUserBounds() -> CGRect {
        userDisplayIDs().reduce(CGRect.null) { $0.union(CGDisplayBounds($1)) }
    }

    /// Switch to the 2x mode at our point size. macOS remembers a mode per
    /// display serial, so a display first made at 1x would stay 1x.
    private func useRetinaMode() {
        if let current = CGDisplayCopyDisplayMode(displayID), current.width == width, current.pixelWidth == width * 2 { return }
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode],
              let retina = modes.first(where: { $0.width == width && $0.height == height && $0.pixelWidth == width * 2 }) else {
            Log.info("agent display has no 2x mode at \(width)x\(height)")
            return
        }
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        CGConfigureDisplayWithDisplayMode(config, displayID, retina, nil)
        let err = CGCompleteDisplayConfiguration(config, .forSession)
        Log.info("agent display switched to \(width)x\(height) at 2x (\(err.rawValue))")
    }

    fileprivate func place() {
        userBounds = computeUserBounds()
        guard let origin = anchor(), abs(origin.x) < 1e6, abs(origin.y) < 1e6 else {
            // Placed once a user display shows up (see `reconfigured`).
            bounds = CGDisplayBounds(displayID)
            Log.info("agent display not placed: no user display")
            return
        }
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        CGConfigureDisplayOrigin(config, displayID, Int32(origin.x), Int32(origin.y))
        let err = CGCompleteDisplayConfiguration(config, .forSession)
        if err != .success { Log.info("configure display origin failed: \(err.rawValue)") }
        bounds = CGDisplayBounds(displayID)
        userBounds = computeUserBounds()
        onChange?()
    }

    fileprivate func reconfigured() {
        // A display still coming online is placed when it arrives.
        guard isRunning, !bounds.isEmpty else { return }
        let user = computeUserBounds()
        let b = CGDisplayBounds(displayID)
        let wanted = anchor()
        if user != userBounds || wanted == nil || b.origin != wanted {
            place()
            Log.info("agent display re-placed at \(bounds.short)")
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
    if flags.contains(.beginConfigurationFlag) { return }
    DispatchQueue.main.async { for d in AgentDisplay.running { d.reconfigured() } }
}
