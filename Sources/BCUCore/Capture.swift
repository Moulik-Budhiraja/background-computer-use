import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers
import CPrivate

/// Screenshots of the agent's windows and display.
///
/// Everything goes through one-shot ScreenCaptureKit screenshots (`Shot`):
/// they're the only way of reading other apps' pixels that macOS doesn't
/// count toward its purple screen-capture pill. SkyLight's window capture
/// is only a fallback for a window ScreenCaptureKit can't read.
public enum Capture {
    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    private static let clockLock = NSLock()
    private static var _lastMs = 0.0
    /// When the app last captured anything. macOS turns on its purple
    /// screen-sharing indicator once counted captures come often enough
    /// (see `Shot`), so background captures (the history recorder) wait
    /// until a few seconds have passed since the last one.
    public static var lastCaptureMs: Double { clockLock.lock(); defer { clockLock.unlock() }; return _lastMs }
    private static func mark() { clockLock.lock(); _lastMs = nowMs(); clockLock.unlock() }

    static func blocking<T>(timeoutMs: Double = 10_000, _ op: @escaping () async throws -> T) throws -> T {
        let sem = DispatchSemaphore(value: 0)
        let result = Locked<Result<T, Error>?>(nil)
        Task.detached {
            do { result.value = .success(try await op()) } catch { result.value = .failure(error) }
            sem.signal()
        }
        if sem.wait(timeout: .now() + .milliseconds(Int(timeoutMs))) == .timedOut { throw ToolError("screen capture timed out") }
        return try result.value!.get()
    }

    /// One window, for a live preview: nothing macOS would count.
    public static func windowFrame(_ id: CGWindowID) -> CGImage? {
        mark()
        return Shot.window(id)
    }

    public static func window(_ id: CGWindowID) throws -> CGImage {
        mark()
        if let image = Shot.window(id) ?? BCUCaptureWindow(id) { return image }
        throw ToolError("window \(id) is not capturable (closed, or Screen Recording permission missing)")
    }

    /// The agent display drawn from its windows, back to front, on a dark
    /// background. `width` sets the output size (height follows the display).
    /// `wholeDisplay` adds the wallpaper and menu bar (the user's preview).
    /// Without it only app windows are drawn, so the agent doesn't see which
    /// app the user is in from the menu bar.
    public static func composite(display: AgentDisplay, width: Int? = nil, wholeDisplay: Bool = false) -> CGImage? {
        guard display.isRunning else { return nil }
        mark()
        let b = display.bounds
        let outW = width ?? Int(b.width)
        let scale = CGFloat(outW) / b.width
        let outH = Int(b.height * scale)
        guard let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: outW, height: outH))
        ctx.interpolationQuality = .medium

        // CGWindowList is front to back.
        let systemOwners: Set<String> = ["Window Server", "Dock", "Control Center", "SystemUIServer", "Notification Center"]
        let windows = WindowList.all(onScreenOnly: true, includeDesktop: wholeDisplay).filter {
            guard b.intersects($0.bounds), $0.alpha > 0, $0.bounds.width > 2, $0.bounds.height > 2, $0.pid != getpid() else { return false }
            if wholeDisplay {
                return !($0.owner == "Window Server" && ($0.title == "underbelly" || $0.title.hasSuffix("Backstop")))
            }
            return !systemOwners.contains($0.owner) && $0.layer != 24 && $0.layer != 25
        }
        // One screenshot of just those windows, over the dark background.
        guard let image = Shot.display(display.displayID, including: windows.map(\.id)) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        return ctx.makeImage()
    }

    /// The whole agent display as it looks, at its full pixel size.
    public static func display(_ display: AgentDisplay) -> CGImage? {
        guard display.isRunning else { return nil }
        mark()
        return Shot.display(display.displayID)
    }

    /// The whole agent display without one window: while the user drags a
    /// window in the preview, the preview draws it where it's going instead.
    public static func display(_ display: AgentDisplay, excluding id: CGWindowID) -> CGImage? {
        guard id != 0, display.isRunning else { return self.display(display) }
        mark()
        return Shot.display(display.displayID, excluding: [id])
    }

    /// The part of a window, in global points, that a capture of it shows.
    /// When a window hangs off the edge of a display, the capture holds only
    /// the part on that display; tell the two cases apart by aspect ratio.
    static func coveredRect(_ image: CGImage, bounds: CGRect, display: CGRect) -> CGRect {
        let visible = bounds.intersection(display)
        guard !visible.isNull, visible.width > 0, visible.height > 0, visible.size != bounds.size else { return bounds }
        let imageAspect = CGFloat(image.width) / CGFloat(image.height)
        let fullAspect = bounds.width / bounds.height
        let visibleAspect = visible.width / visible.height
        return abs(imageAspect - visibleAspect) < abs(imageAspect - fullAspect) ? visible : bounds
    }

    /// A window screenshot at 1 pixel per point, so pixels match the
    /// window-relative points the agent clicks at. The agent display is
    /// Retina, so raw captures are twice that size.
    public static func windowInPoints(_ id: CGWindowID, display: CGRect) throws -> CGImage {
        inPoints(try window(id), id: id, display: display)
    }

    /// `image`, a capture of window `id`, at 1 pixel per point.
    public static func inPoints(_ image: CGImage, id: CGWindowID, display: CGRect) -> CGImage {
        guard let bounds = WindowList.info(id)?.bounds, bounds.width > 0, bounds.height > 0 else { return image }
        let size = coveredRect(image, bounds: bounds, display: display).size
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard w > 0, h > 0, w != image.width || h != image.height,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    /// PNG, downscaled so the long side is at most `maxSide` pixels.
    public static func png(_ image: CGImage, maxSide: Int = 1600) -> Data? {
        var img = image
        let longSide = max(image.width, image.height)
        if longSide > maxSide {
            let s = CGFloat(maxSide) / CGFloat(longSide)
            let w = Int(CGFloat(image.width) * s), h = Int(CGFloat(image.height) * s)
            if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                if let scaled = ctx.makeImage() { img = scaled }
            }
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
