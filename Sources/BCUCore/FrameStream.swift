import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Live frames of one agent display, for any preview: the menu bar app's
/// (in process) or a host app's (over the socket). Each frame is one capture
/// of the whole display (no ScreenCaptureKit stream, so no screen-sharing
/// indicator), or of one window.
public final class FrameStream {
    private let engine: Engine
    private let onFrame: (CGImage) -> Void
    private let queue = DispatchQueue(label: "bcu.frames", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var _excluded: CGWindowID = 0
    private var _window: CGWindowID = 0

    /// A window left out of the capture (one the user is dragging, drawn
    /// ahead of where the real one is).
    public var excluded: CGWindowID {
        get { lock.lock(); defer { lock.unlock() }; return _excluded }
        set { lock.lock(); _excluded = newValue; lock.unlock() }
    }

    /// Show only this window (one handed to the user) instead of the display.
    public var window: CGWindowID {
        get { lock.lock(); defer { lock.unlock() }; return _window }
        set { lock.lock(); _window = newValue; lock.unlock() }
    }

    /// `onFrame` runs on the stream's own queue.
    public init(engine: Engine, onFrame: @escaping (CGImage) -> Void) {
        self.engine = engine
        self.onFrame = onFrame
    }

    public var isRunning: Bool { timer != nil }

    public func start(fps: Int) {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        // A serial queue: a frame that takes longer than the interval just
        // delays the next one, so the rate tops out at what capture allows.
        t.schedule(deadline: .now(), repeating: 1.0 / Double(min(60, max(1, fps))), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in
            guard let self, self.engine.display.isRunning else { return }
            let skip = self.excluded, only = self.window
            let image: CGImage?
            if only != 0 {
                image = Capture.windowFrame(only)
            } else {
                image = skip != 0 ? Capture.display(self.engine.display, excluding: skip) : Capture.display(self.engine.display)
            }
            guard let image else { return }
            // The whole display, as the history records it: while someone
            // watches, history gets every change without capturing again.
            if only == 0, skip == 0 { self.engine.recordPreview(image) }
            self.onFrame(image)
        }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    deinit { timer?.cancel() }

    /// JPEG, downscaled so it's at most `maxWidth` pixels wide.
    public static func jpeg(_ image: CGImage, maxWidth: Int, quality: Double) -> Data? {
        var img = image
        if image.width > maxWidth, maxWidth > 0 {
            let w = maxWidth, h = max(1, Int(Double(image.height) * Double(maxWidth) / Double(image.width)))
            if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
                ctx.interpolationQuality = .medium
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                if let scaled = ctx.makeImage() { img = scaled }
            }
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: min(1, max(0.1, quality))] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
