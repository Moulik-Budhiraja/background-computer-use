import AppKit
import ScreenCaptureKit

/// One-shot ScreenCaptureKit screenshots: how the app reads other apps'
/// pixels without macOS showing its purple screen-capture pill.
///
/// macOS keeps count of how often an app reads other apps' pixels and shows
/// the pill in the menu bar once that goes past about 10–15 reads close
/// together, then keeps it up for 10–20 s. SkyLight window captures,
/// CGDisplayCreateImage and the CGWindowList image calls all count, at any
/// size and rate, even for windows on the agent display. One-shot
/// ScreenCaptureKit screenshots don't (macOS 27.2: 160 in 10 s, no pill).
/// Reading Window Server's own windows (the menu bar) doesn't count either.
///
/// These screenshots match the screen inside windows pixel for pixel, but
/// not quite at their edges: WindowServer draws a light rim around each
/// window and the menu bar's material as it puts the screen together, and
/// ScreenCaptureKit leaves the rims out and draws the menu bar a little
/// lighter. A still copy shown over the user's window in place of it uses a
/// counted capture for that (see `Exact`).
enum Shot {
    private static let lock = NSLock()
    private static var cached: (ms: Double, content: SCShareableContent)?

    /// What ScreenCaptureKit can capture, at most `maxAgeMs` old.
    static func content(maxAgeMs: Double = 500) -> SCShareableContent? {
        lock.lock()
        if let c = cached, nowMs() - c.ms <= maxAgeMs { lock.unlock(); return c.content }
        lock.unlock()
        guard let content = try? Capture.blocking(timeoutMs: 2000, {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }) else { return nil }
        lock.lock(); cached = (nowMs(), content); lock.unlock()
        return content
    }

    private static func scWindow(_ id: CGWindowID) -> SCWindow? {
        if let w = content()?.windows.first(where: { $0.windowID == id }) { return w }
        // A window that just opened isn't in an older list.
        return content(maxAgeMs: 0)?.windows.first { $0.windowID == id }
    }

    private static func scDisplay(_ id: CGDirectDisplayID) -> SCDisplay? {
        if let d = content(maxAgeMs: 5000)?.displays.first(where: { $0.displayID == id }) { return d }
        return content(maxAgeMs: 0)?.displays.first { $0.displayID == id }
    }

    /// One window's own pixels at full resolution, without its shadow.
    static func window(_ id: CGWindowID) -> CGImage? {
        guard let w = scWindow(id) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = max(1, Int((w.frame.width * scale).rounded()))
        config.height = max(1, Int((w.frame.height * scale).rounded()))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.captureResolution = .best
        return try? Capture.blocking(timeoutMs: 2000) {
            try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
    }

    /// What a display shows, at its full pixel size: everything on it, or
    /// only `including` (window IDs; the rest is left out), minus `excluding`.
    /// `rect` (global points) limits it to part of the display.
    static func display(_ displayID: CGDirectDisplayID, rect: CGRect? = nil, including: [CGWindowID]? = nil,
                        excluding: Set<CGWindowID> = []) -> CGImage? {
        guard let (filter, config) = setup(displayID, rect: rect, including: including, excluding: excluding) else { return nil }
        return try? Capture.blocking(timeoutMs: 2000) {
            try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
    }

    private static func setup(_ displayID: CGDirectDisplayID, rect: CGRect?, including: [CGWindowID]?, excluding: Set<CGWindowID>,
                              content given: SCShareableContent? = nil) -> (SCContentFilter, SCStreamConfiguration)? {
        guard let content = given ?? content(), let display = content.displays.first(where: { $0.displayID == displayID }) ?? scDisplay(displayID) else { return nil }
        let filter: SCContentFilter
        if let including {
            let wanted = Set(including)
            filter = SCContentFilter(display: display, including: content.windows.filter { wanted.contains($0.windowID) && !excluding.contains($0.windowID) })
        } else {
            filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { excluding.contains($0.windowID) })
        }
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        var points = display.frame.size
        if let rect {
            let local = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                .intersection(CGRect(origin: .zero, size: display.frame.size))
            guard !local.isNull, local.width >= 1, local.height >= 1 else { return nil }
            config.sourceRect = local
            points = local.size
        }
        config.width = max(1, Int((points.width * scale).rounded()))
        config.height = max(1, Int((points.height * scale).rounded()))
        config.showsCursor = false
        config.captureResolution = .best
        return (filter, config)
    }

}

/// Captures macOS counts toward its screen-capture pill (see `Shot`),
/// rationed so the count never reaches it: a burst of a few, then one every
/// few seconds. Used only where a copy must match the screen exactly.
enum Exact {
    private static let lock = NSLock()
    private static let capacity = 6.0
    private static let refillPerSecond = 0.2
    private static var tokens = capacity
    private static var lastMs = nowMs()

    /// Spend `n` counted captures if they're left.
    static func take(_ n: Int = 1) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = nowMs()
        tokens = min(capacity, tokens + (now - lastMs) / 1000 * refillPerSecond)
        lastMs = now
        guard tokens >= Double(n) else { return false }
        tokens -= Double(n)
        return true
    }
}
