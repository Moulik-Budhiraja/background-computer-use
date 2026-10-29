import AppKit
import CoreGraphics
import CPrivate

/// The agent's private display. It touches the user's displays at a single
/// corner (bottom-right of their union), so the cursor can only reach it at
/// one point, and the input tap fences even that off.
public final class AgentDisplay {
    public private(set) var displayID: CGDirectDisplayID = 0
    /// Agent display bounds in global (top-left origin) coordinates.
    public private(set) var bounds: CGRect = .zero
    /// Union of the user's real displays.
    public private(set) var userBounds: CGRect = .zero

    public let width: Int
    public let height: Int
    public var onChange: (() -> Void)?

    private var display: BCUVirtualDisplay?
    fileprivate static weak var current: AgentDisplay?

    public init(width: Int = 1600, height: Int = 1000) {
        self.width = width
        self.height = height
    }

    public var isRunning: Bool { display != nil && displayID != 0 }

    /// Must be called on the main thread.
    public func start() throws {
        guard display == nil else { return }
        guard let vd = BCUVirtualDisplay(name: "Agent Display", width: UInt32(width), height: UInt32(height), ppi: 110, serial: 0x4243_5531) else {
            throw ToolError("could not create the virtual display")
        }
        display = vd
        displayID = vd.displayID
        // The display comes online asynchronously.
        let deadline = Date().addingTimeInterval(5)
        while CGDisplayBounds(displayID).isEmpty && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard !CGDisplayBounds(displayID).isEmpty else {
            stop()
            throw ToolError("virtual display never came online")
        }
        place()
        AgentDisplay.current = self
        CGDisplayRegisterReconfigurationCallback(reconfigurationCallback, nil)
        Log.info("agent display \(displayID) at \(bounds.short); user displays \(userBounds.short)")
    }

    public func stop() {
        CGDisplayRemoveReconfigurationCallback(reconfigurationCallback, nil)
        display?.invalidate()
        display = nil
        displayID = 0
        bounds = .zero
    }

    public func userDisplayIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        return Array(ids.prefix(Int(count))).filter { $0 != displayID }
    }

    private func computeUserBounds() -> CGRect {
        userDisplayIDs().reduce(CGRect.null) { $0.union(CGDisplayBounds($1)) }
    }

    fileprivate func place() {
        userBounds = computeUserBounds()
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        CGConfigureDisplayOrigin(config, displayID, Int32(userBounds.maxX), Int32(userBounds.maxY))
        let err = CGCompleteDisplayConfiguration(config, .forSession)
        if err != .success { Log.info("configure display origin failed: \(err.rawValue)") }
        bounds = CGDisplayBounds(displayID)
        userBounds = computeUserBounds()
        onChange?()
    }

    fileprivate func reconfigured() {
        guard isRunning else { return }
        let user = computeUserBounds()
        let b = CGDisplayBounds(displayID)
        let wanted = CGPoint(x: user.maxX, y: user.maxY)
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
    DispatchQueue.main.async { AgentDisplay.current?.reconfigured() }
}
