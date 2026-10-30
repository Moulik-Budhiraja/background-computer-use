import AppKit
import QuartzCore
import SwiftUI
import BCUCore

/// Live view of the agent display. Each frame is one capture of the whole
/// display (no ScreenCaptureKit stream, so no screen-sharing indicator),
/// shown by setting a layer's contents so SwiftUI doesn't redraw per frame.
final class PreviewStream {
    private let engine: Engine
    private let onFrame: (CGImage) -> Void
    private let queue = DispatchQueue(label: "bcu.preview", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var _excluded: CGWindowID = 0
    /// A window left out of the capture (one the user is dragging).
    var excluded: CGWindowID {
        get { lock.lock(); defer { lock.unlock() }; return _excluded }
        set { lock.lock(); _excluded = newValue; lock.unlock() }
    }

    init(engine: Engine, onFrame: @escaping (CGImage) -> Void) {
        self.engine = engine
        self.onFrame = onFrame
    }

    func start(fps: Int) {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        // A serial queue: a frame that takes longer than the interval just
        // delays the next one, so the rate tops out at what capture allows.
        t.schedule(deadline: .now(), repeating: 1.0 / Double(max(1, fps)), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let skip = self.excluded
            guard let image = skip != 0 ? Capture.display(self.engine.display, excluding: skip) : Capture.display(self.engine.display) else { return }
            DispatchQueue.main.async { self.onFrame(image) }
        }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

/// A layer that shows the latest frame, scaled to fit, plus the window the
/// user is dragging in the preview (drawn ahead of the real window, which
/// takes about 100 ms to follow).
final class FrameLayer {
    let layer: CALayer = {
        let l = CALayer()
        l.contentsGravity = .resizeAspect
        l.minificationFilter = .trilinear
        l.magnificationFilter = .linear
        return l
    }()
    private let ghost: CALayer = {
        let g = CALayer()
        g.isHidden = true
        g.contentsGravity = .resize
        g.minificationFilter = .trilinear
        return g
    }()
    /// The agent display, in global points, that frames show.
    var displayBounds: CGRect = .zero

    /// Clips the ghost to the display, so a window dragged off an edge is cut off there.
    private let ghostClip: CALayer = {
        let c = CALayer()
        c.masksToBounds = true
        return c
    }()

    init() {
        ghostClip.addSublayer(ghost)
        layer.addSublayer(ghostClip)
    }

    /// Draw a window (or, with no image, a resize outline) at `rect`, in global points.
    func showGhost(_ rect: CGRect, image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ghost.isHidden = false
        let clip = map(displayBounds)
        ghostClip.frame = clip
        let r = map(rect)
        ghost.frame = r.offsetBy(dx: -clip.minX, dy: -clip.minY)
        if let image {
            ghost.contents = image
            ghost.borderWidth = 0
            ghost.backgroundColor = nil
        } else {
            ghost.contents = nil
            ghost.borderWidth = 2
            ghost.borderColor = NSColor.controlAccentColor.cgColor
            ghost.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
            ghost.cornerRadius = 6
        }
        CATransaction.commit()
    }

    func hideGhost() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ghost.isHidden = true
        ghost.contents = nil
        CATransaction.commit()
    }

    /// Global points on the agent display to this layer's coordinates (origin
    /// bottom left), matching how the frame is fitted.
    private func map(_ r: CGRect) -> CGRect {
        let L = layer.bounds, b = displayBounds
        guard b.width > 0, b.height > 0 else { return .zero }
        let s = min(L.width / b.width, L.height / b.height)
        let ox = (L.width - b.width * s) / 2, oy = (L.height - b.height * s) / 2
        let top = oy + (r.minY - b.minY) * s
        return CGRect(x: ox + (r.minX - b.minX) * s, y: L.height - top - r.height * s, width: r.width * s, height: r.height * s)
    }

    func show(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = image
        CATransaction.commit()
    }
}

/// Hosts a FrameLayer in SwiftUI.
struct FrameView: NSViewRepresentable {
    let frame: FrameLayer

    func makeNSView(context: Context) -> FrameHostView {
        let v = FrameHostView()
        v.wantsLayer = true
        v.frameLayer = frame
        v.layer?.addSublayer(frame.layer)
        return v
    }

    func updateNSView(_ v: FrameHostView, context: Context) {
        if frame.layer.superlayer !== v.layer {
            v.frameLayer = frame
            v.layer?.addSublayer(frame.layer)
        }
    }
}

final class FrameHostView: NSView {
    var frameLayer: FrameLayer?
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer?.layer.frame = bounds
        CATransaction.commit()
    }
}
