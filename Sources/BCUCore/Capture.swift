import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers
import CPrivate

/// Screenshots of the agent's windows and display.
///
/// Everything goes through SkyLight's direct window capture first. It needs
/// Screen Recording permission but starts no ScreenCaptureKit session, so
/// macOS never shows its purple screen-sharing indicator. ScreenCaptureKit is
/// only a fallback for a window SkyLight can't read.
public enum Capture {
    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    static func blocking<T>(_ op: @escaping () async throws -> T) throws -> T {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<T, Error>!
        Task.detached {
            do { result = .success(try await op()) } catch { result = .failure(error) }
            sem.signal()
        }
        if sem.wait(timeout: .now() + 10) == .timedOut { throw ToolError("screen capture timed out") }
        return try result.get()
    }

    public static func window(_ id: CGWindowID) throws -> CGImage {
        if let image = BCUCaptureWindow(id) { return image }
        return try blocking {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let w = content.windows.first(where: { $0.windowID == id }) else {
                throw ToolError("window \(id) is not capturable (closed, or Screen Recording permission missing)")
            }
            let filter = SCContentFilter(desktopIndependentWindow: w)
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = max(1, Int(w.frame.width * scale))
            config.height = max(1, Int(w.frame.height * scale))
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
    }

    /// The agent display drawn from its windows, back to front, on a dark
    /// background. `width` sets the output size (height follows the display).
    /// `wholeDisplay` adds the wallpaper and menu bar (the user's preview).
    /// Without it only app windows are drawn, so the agent doesn't see which
    /// app the user is in from the menu bar.
    public static func composite(display: AgentDisplay, width: Int? = nil, wholeDisplay: Bool = false) -> CGImage? {
        guard display.isRunning else { return nil }
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
        for w in windows.reversed() {
            guard let image = w.layer < 0 ? desktopImage(w.id) : BCUCaptureWindow(w.id) else { continue }
            let r = coveredRect(image, bounds: w.bounds, display: b)
            let x = (r.minX - b.minX) * scale
            let yTop = (r.minY - b.minY) * scale
            let h = r.height * scale
            ctx.draw(image, in: CGRect(x: x, y: CGFloat(outH) - yTop - h, width: r.width * scale, height: h))
        }
        return ctx.makeImage()
    }

    private typealias DisplayImageFn = @convention(c) (UInt32) -> Unmanaged<CGImage>?
    /// CGDisplayCreateImage, looked up at run time because the SDK no longer
    /// declares it. It still works, takes about 18 ms for the whole Retina
    /// agent display (stitching windows takes over 500 ms) and, being a
    /// one-shot capture, starts no screen-sharing indicator.
    private static let displayImage: DisplayImageFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGDisplayCreateImage") else { return nil }
        return unsafeBitCast(sym, to: DisplayImageFn.self)
    }()

    /// The whole agent display exactly as it looks, at its full pixel size.
    public static func display(_ display: AgentDisplay) -> CGImage? {
        guard display.isRunning else { return nil }
        if let f = displayImage, let image = f(display.displayID)?.takeRetainedValue() { return image }
        return composite(display: display, width: Int(display.bounds.width) * 2, wholeDisplay: true)
    }

    private typealias FromArrayFn = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
    private static let imageFromArray: FromArrayFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray") else { return nil }
        return unsafeBitCast(sym, to: FromArrayFn.self)
    }()

    /// The whole agent display without one window: while the user drags a
    /// window in the preview, the preview draws it where it's going instead.
    public static func display(_ display: AgentDisplay, excluding id: CGWindowID) -> CGImage? {
        guard id != 0, display.isRunning, let f = imageFromArray else { return self.display(display) }
        let b = display.bounds
        var ids: [UnsafeRawPointer?] = WindowList.all(onScreenOnly: true, includeDesktop: true)
            .filter { b.intersects($0.bounds) && $0.id != id && $0.pid != getpid() }
            .map { UnsafeRawPointer(bitPattern: UInt($0.id)) }
        guard let array = CFArrayCreate(nil, &ids, ids.count, nil),
              let image = f(b, array, 1 << 3 /* best resolution */)?.takeRetainedValue() else { return self.display(display) }
        return image
    }

    /// Wallpaper and desktop windows barely change, so they're captured at most every few seconds.
    private static var desktopCache: [CGWindowID: (ms: Double, image: CGImage)] = [:]
    private static let desktopLock = NSLock()

    private static func desktopImage(_ id: CGWindowID) -> CGImage? {
        desktopLock.lock()
        if let hit = desktopCache[id], nowMs() - hit.ms < 3000 { desktopLock.unlock(); return hit.image }
        desktopLock.unlock()
        guard let image = BCUCaptureWindow(id) else { return nil }
        desktopLock.lock()
        desktopCache[id] = (nowMs(), image)
        if desktopCache.count > 8 { desktopCache = desktopCache.filter { nowMs() - $0.value.ms < 3000 } }
        desktopLock.unlock()
        return image
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
        let image = try window(id)
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
