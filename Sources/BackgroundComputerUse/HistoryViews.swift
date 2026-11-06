import AppKit
import SwiftUI
import VisionKit
import BCUCore

/// One recorded frame, fitted to the view. Pinch (or a two-finger double
/// tap) zooms into it and two fingers then pan; unzoomed, scrolling moves
/// the timeline instead. Text in the frame can be selected and copied.
final class HistoryFrameView: NSView {
    private let clip = NSView()
    private let imageView = NSImageView()
    private let overlay = ImageAnalysisOverlayView()
    private let pointerView = PointerView()
    private let analyzer = ImageAnalyzer()
    private var analysisTask: Task<Void, Never>?
    private var analyzeTimer: Timer?
    private var shownKey: String?

    /// The agent display's size in points, which frames are a picture of.
    var displaySize = CGSize(width: 1600, height: 1000) { didSet { needsLayout = true } }
    private(set) var zoom: CGFloat = 1
    /// Offset of the zoomed image's center from the view's, in view points.
    private var pan: CGPoint = .zero
    /// Unzoomed scrolling goes to the timeline.
    var onScroll: ((NSEvent) -> Void)?

    var highlightText = false {
        didSet { overlay.selectableItemsHighlighted = highlightText }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        addSubview(clip)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layer?.magnificationFilter = .linear
        imageView.layer?.minificationFilter = .trilinear
        clip.addSubview(imageView)
        overlay.trackingImageView = imageView
        overlay.preferredInteractionTypes = .textSelection
        // The header has the highlight toggle.
        overlay.isSupplementaryInterfaceHidden = true
        overlay.autoresizingMask = [.width, .height]
        imageView.addSubview(overlay)
        pointerView.autoresizingMask = [.width, .height]
        imageView.addSubview(pointerView)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ image: CGImage, key: String, pointer: (CGPoint, Bool)?) {
        if key != shownKey {
            shownKey = key
            imageView.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            analysisTask?.cancel()
            overlay.analysis = nil
            analyzeTimer?.invalidate()
            // Read the text once scrubbing stops.
            analyzeTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in self?.analyze(image, key: key) }
        }
        pointerView.size = displaySize
        pointerView.pointer = pointer
    }

    func clear() {
        shownKey = nil
        imageView.image = nil
        overlay.analysis = nil
        pointerView.pointer = nil
    }

    private func analyze(_ image: CGImage, key: String) {
        analysisTask = Task { [weak self] in
            guard let self else { return }
            let config = ImageAnalyzer.Configuration([.text])
            guard let analysis = try? await self.analyzer.analyze(image, orientation: .up, configuration: config),
                  !Task.isCancelled else { return }
            await MainActor.run {
                guard self.shownKey == key else { return }
                self.overlay.analysis = analysis
                self.overlay.selectableItemsHighlighted = self.highlightText
            }
        }
    }

    // MARK: Layout and zoom

    override func layout() {
        super.layout()
        clip.frame = bounds
        layoutImage()
    }

    private var fitted: CGRect {
        let b = bounds, s = displaySize
        guard s.width > 0, s.height > 0, b.width > 0, b.height > 0 else { return .zero }
        let k = min(b.width / s.width, b.height / s.height)
        let w = s.width * k, h = s.height * k
        return CGRect(x: (b.width - w) / 2, y: (b.height - h) / 2, width: w, height: h)
    }

    private func layoutImage() {
        let f = fitted
        let w = f.width * zoom, h = f.height * zoom
        // Keep the zoomed image covering the view: no panning past its edges.
        let maxX = max(0, (w - bounds.width) / 2), maxY = max(0, (h - bounds.height) / 2)
        pan = CGPoint(x: min(max(pan.x, -maxX), maxX), y: min(max(pan.y, -maxY), maxY))
        let rect = CGRect(x: bounds.midX - w / 2 + pan.x, y: bounds.midY - h / 2 + pan.y, width: w, height: h)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageView.frame = rect.integral
        CATransaction.commit()
    }

    /// Zoom to `z`, keeping the image point under `at` (view points) where it is.
    private func setZoom(_ z: CGFloat, at p: CGPoint) {
        let z = min(max(z, 1), 8)
        let c = CGPoint(x: bounds.midX + pan.x, y: bounds.midY + pan.y)
        let k = z / zoom
        pan = CGPoint(x: p.x - (p.x - c.x) * k - bounds.midX, y: p.y - (p.y - c.y) * k - bounds.midY)
        zoom = z
        if z <= 1.001 { zoom = 1; pan = .zero }
        layoutImage()
    }

    func resetZoom() {
        zoom = 1
        pan = .zero
        layoutImage()
    }

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), at: convert(event.locationInWindow, from: nil))
    }

    override func smartMagnify(with event: NSEvent) {
        setZoom(zoom > 1 ? 1 : 2.5, at: convert(event.locationInWindow, from: nil))
    }

    override func scrollWheel(with event: NSEvent) {
        guard zoom > 1 else { onScroll?(event); return }
        let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        pan.x += event.scrollingDeltaX * k
        pan.y -= event.scrollingDeltaY * k
        layoutImage()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { setZoom(zoom > 1 ? 1 : 2.5, at: convert(event.locationInWindow, from: nil)) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The agent's pointer drawn over a frame, with a ring when it just clicked.
private final class PointerView: NSView {
    var size = CGSize(width: 1600, height: 1000)
    var pointer: (CGPoint, Bool)? { didSet { needsDisplay = true } }
    private let arrow = NSCursor.arrow

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let (p, clicked) = pointer, size.width > 0 else { return }
        let k = bounds.width / size.width
        let at = CGPoint(x: p.x * k, y: bounds.height - p.y * k)
        if clicked {
            let r: CGFloat = 14
            let ring = NSBezierPath(ovalIn: NSRect(x: at.x - r, y: at.y - r, width: r * 2, height: r * 2))
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
            ring.fill()
            NSColor.controlAccentColor.setStroke()
            ring.lineWidth = 2
            ring.stroke()
        }
        let image = arrow.image, hot = arrow.hotSpot
        let s = max(0.8, min(1.4, k * 1.2))
        let w = image.size.width * s, h = image.size.height * s
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        image.draw(in: NSRect(x: at.x - hot.x * s, y: at.y - h + hot.y * s, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// The timeline under the frame, like Coast's: frames as ticks left to
/// right, oldest on the left, grouped into a capsule per app with its icon,
/// a gap and a label where a new agent display starts, and a playhead
/// fixed in the middle. Swipe or scroll to move through time; click or
/// drag to jump.
final class HistoryTrackView: NSView {
    weak var model: HistoryModel?
    /// Points per frame; the zoom buttons change it.
    private(set) var spacing: CGFloat = 8
    static let spacings: [CGFloat] = [2, 4, 8, 14, 24]
    private static let runGap: CGFloat = 36
    /// Content x of the playhead.
    private var scrollX: CGFloat = 0
    private var animation: Timer?
    private var dragStart: (x: CGFloat, scrollX: CGFloat)?
    private var dragged = false
    private var scrolling = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometry

    private func contentX(_ i: Int) -> CGFloat {
        guard let m = model, m.items.indices.contains(i) else { return 0 }
        return CGFloat(i) * spacing + CGFloat(m.items[i].run) * Self.runGap
    }

    /// The frame nearest content x.
    private func index(atContent x: CGFloat) -> Int {
        guard let m = model, !m.items.isEmpty else { return 0 }
        var lo = 0, hi = m.items.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if contentX(mid) < x { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, abs(contentX(lo - 1) - x) <= abs(contentX(lo) - x) { return lo - 1 }
        return lo
    }

    private func viewX(_ i: Int) -> CGFloat { bounds.midX + contentX(i) - scrollX }

    // MARK: Following the model

    /// The model moved (keys, chevrons, a reload): bring the playhead there.
    func follow(animated: Bool) {
        guard let m = model, !scrolling, dragStart == nil else { needsDisplay = true; return }
        let target = contentX(m.index)
        animation?.invalidate()
        if !animated || abs(target - scrollX) < 1 {
            scrollX = target
            needsDisplay = true
            return
        }
        let from = scrollX, start = CACurrentMediaTime(), duration = 0.22
        animation = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let k = min(1, (CACurrentMediaTime() - start) / duration)
            let e = 1 - pow(1 - k, 3)
            self.scrollX = from + (target - from) * CGFloat(e)
            self.needsDisplay = true
            if k >= 1 { t.invalidate() }
        }
    }

    func zoom(_ step: Int) {
        guard let i = Self.spacings.firstIndex(of: spacing) else { return }
        let next = min(max(0, i + step), Self.spacings.count - 1)
        spacing = Self.spacings[next]
        scrollX = contentX(model?.index ?? 0)
        needsDisplay = true
    }

    var canZoomIn: Bool { spacing < Self.spacings.last! }
    var canZoomOut: Bool { spacing > Self.spacings.first! }

    private func moved() {
        guard let m = model, !m.items.isEmpty else { return }
        scrollX = min(max(scrollX, contentX(0)), contentX(m.items.count - 1))
        m.scrubbed(to: index(atContent: scrollX))
        needsDisplay = true
    }

    // MARK: Input

    /// Two fingers to the right (or the wheel) go back in time, like Coast.
    override func scrollWheel(with event: NSEvent) {
        animation?.invalidate()
        let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        let d = abs(dx) >= abs(dy) ? dx : dy
        scrolling = event.phase != [] && event.phase != .ended && event.phase != .cancelled
            || event.momentumPhase != [] && event.momentumPhase != .ended && event.momentumPhase != .cancelled
        scrollX -= d * k
        moved()
        if !scrolling { settle() }
    }

    /// Done scrolling: line the playhead up with the frame it's on.
    private func settle() {
        scrolling = false
        follow(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        animation?.invalidate()
        dragStart = (convert(event.locationInWindow, from: nil).x, scrollX)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let s = dragStart else { return }
        let x = convert(event.locationInWindow, from: nil).x
        if abs(x - s.x) > 3 { dragged = true }
        guard dragged else { return }
        scrollX = s.scrollX - (x - s.x)
        moved()
    }

    override func mouseUp(with event: NSEvent) {
        let wasDrag = dragged
        dragStart = nil
        dragged = false
        guard let m = model else { return }
        if wasDrag { settle(); return }
        let x = convert(event.locationInWindow, from: nil).x
        let i = index(atContent: scrollX + x - bounds.midX)
        if i == m.index { follow(animated: true) } else { m.go(to: i) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let m = model, !m.items.isEmpty else { return }
        let ctx = NSGraphicsContext.current!.cgContext
        let midY: CGFloat = 40, barH: CGFloat = 18
        let lo = max(0, index(atContent: scrollX - bounds.width / 2 - 40) - 1)
        let hi = min(m.items.count - 1, index(atContent: scrollX + bounds.width / 2 + 40) + 1)
        let current = m.segmentOf.indices.contains(m.index) ? m.segmentOf[m.index] : -1

        // Where the recordings start.
        let firstX = viewX(0)
        if firstX - spacing / 2 > 0 {
            let text = "Recordings go back \(AppRecordings.store.retentionDays) days"
            let attrs = Self.attrs(11, .medium, .white.withAlphaComponent(0.32))
            let size = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: firstX - 22 - size.width, y: midY - size.height / 2), withAttributes: attrs)
        }

        // A capsule per segment, its frames as ticks inside.
        let firstSeg = m.segmentOf[lo], lastSeg = m.segmentOf[hi]
        for s in firstSeg...lastSeg {
            let seg = m.segments[s]
            let x0 = viewX(seg.first) - spacing / 2 + 1, x1 = viewX(seg.last) + spacing / 2 - 1
            let rect = CGRect(x: x0, y: midY - barH / 2, width: max(3, x1 - x0), height: barH)
            let on = s == current
            ctx.setFillColor(NSColor.white.withAlphaComponent(on ? 0.16 : 0.08).cgColor)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: min(6, rect.width / 2), cornerHeight: min(6, rect.width / 2), transform: nil))
            ctx.fillPath()
            if spacing >= 4 {
                ctx.setFillColor(NSColor.white.withAlphaComponent(on ? 0.42 : 0.24).cgColor)
                for i in max(seg.first, lo)...min(seg.last, hi) {
                    let x = viewX(i)
                    let h: CGFloat = m.acted[i] ? 10 : 6
                    ctx.fill(CGRect(x: x - 0.5, y: midY - h / 2, width: 1, height: h))
                }
            }
            // The app's icon above its capsule, kept in view while the capsule is.
            let visible0 = max(x0, 4), visible1 = min(x1, bounds.width - 4)
            if visible1 - visible0 >= 18, let icon = AppIcons.icon(seg.bundleID) {
                let cx = min(max((x0 + x1) / 2, visible0 + 9), visible1 - 9)
                icon.draw(in: CGRect(x: cx - 9, y: midY - barH / 2 - 23, width: 18, height: 18), from: .zero, operation: .sourceOver,
                          fraction: on ? 1 : 0.6, respectFlipped: true, hints: nil)
            }
        }

        // Each agent display's start: its agent and time, under the track.
        let labelAttrs = Self.attrs(10.5, .semibold, .white.withAlphaComponent(0.5))
        let timeAttrs = Self.attrs(10.5, .medium, .white.withAlphaComponent(0.32))
        var lastLabelEnd: CGFloat = -.infinity
        for r in m.items[lo].run...m.items[hi].run {
            guard let first = m.items.firstIndex(where: { $0.run == r }) else { continue }
            let x = max(viewX(first) - spacing / 2, 6)
            guard x > lastLabelEnd + 8, x < bounds.width else { continue }
            let label = m.runs[r].label
            label.draw(at: CGPoint(x: x, y: midY + barH / 2 + 6), withAttributes: labelAttrs)
            let lw = label.size(withAttributes: labelAttrs).width
            let time = HistoryModel.time(m.items[first].frame.t, seconds: false)
            time.draw(at: CGPoint(x: x + lw + 5, y: midY + barH / 2 + 6), withAttributes: timeAttrs)
            lastLabelEnd = x + lw + 5 + time.size(withAttributes: timeAttrs).width
        }

        // The playhead.
        ctx.setFillColor(NSColor.white.cgColor)
        let px = bounds.midX.rounded()
        ctx.addPath(CGPath(roundedRect: CGRect(x: px - 1, y: midY - barH / 2 - 5, width: 2, height: barH + 10), cornerWidth: 1, cornerHeight: 1, transform: nil))
        ctx.fillPath()
    }

    private static func attrs(_ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
    }
}

/// Hosts the frame view in SwiftUI.
struct HistoryFrameRep: NSViewRepresentable {
    let view: HistoryFrameView
    func makeNSView(context: Context) -> HistoryFrameView { view }
    func updateNSView(_ v: HistoryFrameView, context: Context) {}
}

struct HistoryTrackRep: NSViewRepresentable {
    let view: HistoryTrackView
    func makeNSView(context: Context) -> HistoryTrackView { view }
    func updateNSView(_ v: HistoryTrackView, context: Context) {}
}
