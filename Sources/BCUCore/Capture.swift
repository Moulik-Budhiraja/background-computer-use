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
    public static func composite(display: AgentDisplay, width: Int? = nil) -> CGImage? {
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

        // CGWindowList is front to back; skip the menu bar and system chrome.
        let skipOwners: Set<String> = ["Window Server", "Dock", "Control Center", "SystemUIServer", "Notification Center"]
        let windows = WindowList.all(onScreenOnly: true).filter {
            b.intersects($0.bounds) && $0.alpha > 0 && $0.bounds.width > 2 && $0.bounds.height > 2
                && !skipOwners.contains($0.owner) && $0.layer != 24 && $0.layer != 25 && $0.pid != getpid()
        }
        for w in windows.reversed() {
            guard let image = BCUCaptureWindow(w.id) else { continue }
            let x = (w.bounds.minX - b.minX) * scale
            let yTop = (w.bounds.minY - b.minY) * scale
            let h = w.bounds.height * scale
            ctx.draw(image, in: CGRect(x: x, y: CGFloat(outH) - yTop - h, width: w.bounds.width * scale, height: h))
        }
        return ctx.makeImage()
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
