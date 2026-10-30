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

    private static var callbackInstalled = false

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
    public func start(slot: Int = AgentDisplay.freeSlot()) throws {
        guard display == nil else { return }
        self.slot = slot
        let name = slot == 0 ? "Agent Display" : "Agent Display \(slot + 1)"
        guard let vd = BCUVirtualDisplay(name: name, width: UInt32(width), height: UInt32(height), ppi: 110, serial: 0x4243_5532 + UInt32(slot)) else {
            throw ToolError("could not create the virtual display")
        }
        display = vd
        displayID = vd.displayID
        // Registered right away so a display starting at the same time
        // (another session, while this one waits below) takes another slot.
        Self.registryLock.lock()
        Self.registry.removeAll { $0.display == nil || $0.display === self }
        Self.registry.append(Ref(self))
        if !Self.callbackInstalled {
            Self.callbackInstalled = true
            CGDisplayRegisterReconfigurationCallback(reconfigurationCallback, nil)
        }
        Self.registryLock.unlock()
        // The display comes online asynchronously.
        let deadline = Date().addingTimeInterval(5)
        while CGDisplayBounds(displayID).isEmpty && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard !CGDisplayBounds(displayID).isEmpty else {
            stop()
            throw ToolError("virtual display never came online")
        }
        useRetinaMode()
        place()
        Log.info("agent display \(slot + 1) (\(displayID)) at \(bounds.short); user displays \(userBounds.short)")
    }

    /// Main thread.
    public func stop() {
        guard display != nil else { return }
        display?.invalidate()
        display = nil
        let id = displayID
        displayID = 0
        bounds = .zero
        Self.registryLock.lock()
        Self.registry.removeAll { $0.display == nil || $0.display === self }
        Self.registryLock.unlock()
        Log.info("agent display \(slot + 1) (\(id)) removed")
        // The ones after it move up the staircase.
        for d in Self.running { d.reconfigured() }
    }

    /// The user's real displays: every active display that isn't an agent's.
    public func userDisplayIDs() -> [CGDirectDisplayID] {
        Self.userDisplayIDs()
    }

    public static func userDisplayIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        let agents = Set(running.map(\.displayID))
        return Array(ids.prefix(Int(count))).filter { !agents.contains($0) }
    }

    /// Where this display goes: at the bottom-right corner of the agent
    /// display before it, or of the user's displays for the first.
    private func anchor() -> CGPoint {
        if let before = Self.running.filter({ $0.slot < slot && $0 !== self }).last {
            let b = CGDisplayBounds(before.displayID)
            return CGPoint(x: b.maxX, y: b.maxY)
        }
        let user = computeUserBounds()
        return CGPoint(x: user.maxX, y: user.maxY)
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
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        let origin = anchor()
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
        if user != userBounds || b.origin != wanted {
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
