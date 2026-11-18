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
/// a label where an agent display starts, and a playhead fixed in the
/// middle. Every frame has its own place in time across all agent displays,
/// so displays that recorded at the same time line up, each in its own lane
/// below the other; a gap stands for time when no agent was recording.
/// Swipe or scroll to move through time; click or drag to jump, a click in
/// a lane going to that lane's agent.
final class HistoryTrackView: NSView {
    weak var model: HistoryModel?
    /// Points per frame; the zoom buttons change it.
    private(set) var spacing: CGFloat = 8
    static let spacings: [CGFloat] = [2, 4, 8, 14, 24]
    private static let runGap: CGFloat = 36
    /// What a lane takes: its icons above, its capsules, its labels under.
    static let laneHeight: CGFloat = 60
    /// The top lane's capsules' center.
    private static let firstMidY: CGFloat = 40
    /// Content x of the playhead.
    private var scrollX: CGFloat = 0
    private var animation: Timer?
    private var dragStart: (x: CGFloat, scrollX: CGFloat)?
    private var dragged = false
    private var scrolling = false
    /// The model is following a scrub: the track is already where it should be.
    private var holding = false
    /// A scrub left the playhead past the frame shown (an agent whose screen
    /// didn't change for a while): it stays there while that frame is shown,
    /// through reloads too. Kept as frames (run, time), since a reload can
    /// renumber items and the size limit can close up the clock: `frame`
    /// is the one shown, `at` the newest frame of all at the playhead.
    /// `edge`: the playhead was at the newest frame of all (the live edge),
    /// which isn't looking back: History keeps following, and the playhead
    /// stays at the edge as it moves.
    private var held: (frame: FrameKey, at: FrameKey, edge: Bool)? {
        didSet {
            model?.holdingPast = held.map { !$0.edge } ?? false
            model?.holdingEdge = held?.edge ?? false
        }
    }
    private struct FrameKey: Equatable { let run: String; let t: Double }

    private func key(_ i: Int) -> FrameKey? {
        guard let m = model, m.items.indices.contains(i) else { return nil }
        return FrameKey(run: m.runs[m.items[i].run].id, t: m.items[i].frame.t)
    }

    private func item(_ k: FrameKey) -> Int? {
        model?.items.indices.first { self.key($0) == k }
    }

    /// The items changed (a reload): put a held playhead back at its frame
    /// on the clock as it is now, or let it go if that frame is gone.
    func itemsChanged() {
        defer { needsDisplay = true }
        guard let h = held, let m = model else { return }
        // At the live edge on a quiet agent's frame (or the frame it moved on
        // to): still at the edge, anchored to whatever is newest now, even if
        // the old newest frame was pruned. Once its frame is the newest of
        // all, there's nothing to hold.
        if h.edge, let shown = key(m.index), shown.run == h.frame.run {
            if let newest = m.byTime.last, newest != m.index, let at = key(newest) {
                held = (shown, at, true)
                if !scrolling, dragStart == nil { scrollX = lastContentX }
            } else {
                held = nil
            }
            return
        }
        guard key(m.index) == h.frame, let at = item(h.at) else {
            held = nil
            return
        }
        // Mid-gesture the playhead is the user's: the next move updates the hold.
        guard !scrolling, dragStart == nil else { return }
        scrollX = h.edge ? lastContentX : max(contentX(at), contentX(m.index))
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometry

    private func contentX(_ i: Int) -> CGFloat {
        guard let m = model, m.slot.indices.contains(i) else { return 0 }
        return CGFloat(m.slot[i]) * spacing + CGFloat(m.stretch[i]) * Self.runGap
    }

    private var lastContentX: CGFloat { model?.byTime.last.map(contentX) ?? 0 }

    private func midY(lane: Int) -> CGFloat { Self.firstMidY + CGFloat(lane) * Self.laneHeight }

    /// The lane at view y.
    private func lane(atY y: CGFloat) -> Int {
        let lanes = model?.lanes ?? 1
        return min(max(0, Int(((y - Self.firstMidY) / Self.laneHeight).rounded())), lanes - 1)
    }

    /// Content x from run `r`'s first frame to when it stopped recording,
    /// with half a frame either side.
    private func span(ofRun r: Int) -> ClosedRange<CGFloat> {
        guard let m = model else { return 0...0 }
        let items = m.runItems[r]
        let end = m.runEnds.indices.contains(r) ? m.lastItem(atOrBefore: m.runEnds[r]) ?? items.upperBound : items.upperBound
        return (contentX(items.lowerBound) - spacing / 2)...(max(contentX(items.upperBound), contentX(end)) + spacing / 2)
    }

    /// Run `r`'s frame nearest content x (a run's frames are in time order).
    private func nearest(inRun r: Int, toContent x: CGFloat) -> Int {
        guard let m = model else { return 0 }
        var lo = m.runItems[r].lowerBound, hi = m.runItems[r].upperBound
        while lo < hi {
            let mid = (lo + hi) / 2
            if contentX(mid) < x { lo = mid + 1 } else { hi = mid }
        }
        if lo > m.runItems[r].lowerBound, abs(contentX(lo - 1) - x) <= abs(contentX(lo) - x) { return lo - 1 }
        return lo
    }

    /// Run `r`'s screen at content x: its newest frame at or before x (an
    /// unchanged screen records no new frame), or its first one.
    private func latest(inRun r: Int, atContent x: CGFloat) -> Int {
        guard let m = model else { return 0 }
        let range = m.runItems[r]
        var lo = range.lowerBound, hi = range.upperBound
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if contentX(mid) <= x + spacing / 2 { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// The frame to show at content x. A click in a lane: that lane's run's
    /// nearest frame, if it was recording there. Scrubbing: a run's screen
    /// as it was at x, the run already on screen while it was recording
    /// there (so it stays with one agent), else the top lane's run
    /// recording there. Else the nearest frame of any run.
    private func frame(atContent x: CGFloat, lane: Int? = nil) -> Int? {
        guard let m = model, !m.items.isEmpty else { return nil }
        let recording = m.runItems.indices.filter { span(ofRun: $0).contains(x) }
        if let lane, let r = recording.first(where: { m.laneOf[$0] == lane }) {
            return nearest(inRun: r, toContent: x)
        }
        if lane == nil, let current = m.current?.run, recording.contains(current) {
            return latest(inRun: current, atContent: x)
        }
        if let r = recording.min(by: { m.laneOf[$0] < m.laneOf[$1] }) {
            return lane == nil ? latest(inRun: r, atContent: x) : nearest(inRun: r, toContent: x)
        }
        return m.runItems.indices
            .map { r -> (Int, CGFloat) in
                let i = nearest(inRun: r, toContent: x)
                return (i, abs(contentX(i) - x))
            }
            .min(by: { $0.1 < $1.1 })?.0
    }

    private func viewX(_ i: Int) -> CGFloat { bounds.midX + contentX(i) - scrollX }

    /// For the self-test: scrub a little past item `i` and let it settle.
    /// True when the playhead is held there.
    func holdForTest(from i: Int) -> Bool {
        guard let m = model, m.items.indices.contains(i) else { return false }
        m.go(to: i, animated: false)
        scrollX += spacing * 0.6
        moved()
        settle(animated: false)
        return held != nil
    }

    /// For the self-test: from item `i`, scrub to the newest frame of all and
    /// let it settle. True when `i` is still shown there, held.
    func holdAtEdgeForTest(from i: Int) -> Bool {
        guard let m = model, m.items.indices.contains(i) else { return false }
        m.go(to: i, animated: false)
        scrollX = lastContentX
        moved()
        settle(animated: false)
        return held != nil && m.index == i
    }

    /// For the self-test: a drag, from item `i` (or on from where it is), by
    /// `dx` points, still under way. True when the frame shown hasn't changed
    /// from `i`.
    func dragForTest(from i: Int?, by dx: CGFloat) -> Bool {
        guard let m = model else { return false }
        if let i { m.go(to: i, animated: false) }
        let shown = m.index
        if dragStart == nil { dragStart = (0, scrollX) }
        dragged = true
        scrollX += dx
        moved()
        return m.index == shown
    }

    /// For the self-test: the drag ends.
    func endDragForTest() {
        dragStart = nil
        dragged = false
        settle(animated: false)
    }

    var playheadXForTest: CGFloat { scrollX }
    var spacingForTest: CGFloat { spacing }

    /// For the self-test: a step into the gap before a stretch of recording,
    /// nearer its first frame. True when it settles onto that frame, not held.
    func stepIntoGapForTest() -> Bool {
        guard let m = model, let k = m.byTime.indices.dropLast().first(where: { m.stretch[m.byTime[$0 + 1]] != m.stretch[m.byTime[$0]] }) else { return false }
        let j = m.byTime[k + 1]
        m.go(to: m.byTime[k], animated: false)
        scrollX = contentX(j) - spacing * 0.75
        moved()
        settle(animated: false)
        return held == nil && m.index == j && abs(scrollX - contentX(j)) < 0.5
    }

    /// For the self-test: the frame an edge hold is anchored to is pruned,
    /// and the items change. True when it's still at the live edge.
    func pruneEdgeAnchorForTest() -> Bool {
        guard let h = held, h.edge else { return false }
        held = (h.frame, FrameKey(run: "pruned", t: 0), true)
        itemsChanged()
        return held?.edge == true && abs(scrollX - lastContentX) < 0.5
    }

    /// For the self-test: whether the playhead is held, and its time.
    var heldForTest: (held: Bool, time: Double, edge: Bool) { (held != nil, playheadTime, held?.edge ?? false) }

    /// For the self-test: scrub a little past item `i` (it stays shown and
    /// the playhead is held), then jump to `i`. True when the playhead is
    /// back on its frame.
    func recenterForTest(from i: Int) -> Bool {
        guard let m = model, m.items.indices.contains(i) else { return false }
        m.go(to: i, animated: false)
        scrollX += spacing * 0.6
        moved()
        settle(animated: false)
        guard m.index == i, abs(scrollX - contentX(i)) > spacing / 2 else { return false }
        m.go(to: i, animated: false)
        return abs(scrollX - contentX(i)) < 0.5
    }

    /// For the self-test: from item `i`, scrub forward in steps smaller than
    /// a frame, as a mouse wheel does, settling after each. True when the
    /// playhead never went back, stayed with `i`'s run while it recorded,
    /// and got past that run's next frame.
    func scrubForwardForTest(from i: Int, steps: Int) -> Bool {
        guard let m = model, m.items.indices.contains(i), i + 1 < m.items.count, m.items[i + 1].run == m.items[i].run else { return false }
        m.go(to: i, animated: false)
        let run = m.items[i].run, next = contentX(i + 1)
        var last = scrollX, ok = true
        for _ in 0..<steps {
            scrollX += spacing * 0.6
            moved()
            settle(animated: false)
            if scrollX < last - 0.5 { ok = false }
            if span(ofRun: run).contains(scrollX), m.items[m.index].run != run { ok = false }
            last = scrollX
        }
        return ok && scrollX > next
    }

    // MARK: Following the model

    /// The model moved (keys, chevrons, a reload): bring the playhead there.
    func follow(animated: Bool) {
        guard let m = model, !scrolling, dragStart == nil, !holding, held == nil || held?.frame != key(m.index) else { needsDisplay = true; return }
        held = nil
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

    /// Forget a held playhead: the next move goes onto the frame shown.
    func releaseHold() { held = nil }

    /// Onto the frame shown, even when a scrub left the playhead past it.
    func recenter(animated: Bool) {
        held = nil
        follow(animated: animated)
    }

    func zoom(_ step: Int) {
        guard let i = Self.spacings.firstIndex(of: spacing) else { return }
        let next = min(max(0, i + step), Self.spacings.count - 1)
        spacing = Self.spacings[next]
        held = nil
        scrollX = contentX(model?.index ?? 0)
        needsDisplay = true
    }

    var canZoomIn: Bool { spacing < Self.spacings.last! }
    var canZoomOut: Bool { spacing > Self.spacings.first! }

    private func moved() {
        guard let m = model, !m.items.isEmpty else { return }
        scrollX = min(max(scrollX, 0), lastContentX)
        if let i = frame(atContent: scrollX) {
            holding = true
            m.scrubbed(to: i)
            holding = false
        }
        // Kept up to date as the scrub goes, so a reload mid-gesture neither
        // follows a live run from an earlier time nor puts back an old hold.
        updateHold()
        needsDisplay = true
    }

    /// Held when the frame shown is further back than the playhead (an agent
    /// whose screen didn't change for a while), else not. A frame ahead of
    /// it (the first of a run, after a gap) is settled onto instead.
    private func updateHold() {
        guard let m = model, m.items.indices.contains(m.index), scrollX - contentX(m.index) > spacing / 2,
              let shown = key(m.index), let at = m.lastItem(atOrBefore: playheadTime).flatMap(key) else {
            held = nil
            return
        }
        held = (shown, at, key(m.byTime.last ?? -1) == at)
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
    /// The time at the playhead: the newest frame's at or before it.
    private var playheadTime: Double {
        guard let m = model, !m.byTime.isEmpty else { return 0 }
        var lo = 0, hi = m.byTime.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if contentX(m.byTime[mid]) <= scrollX { lo = mid + 1 } else { hi = mid }
        }
        return m.items[m.byTime[max(0, lo - 1)]].frame.t
    }

    /// After a scrub: onto the frame shown when it's the one at the playhead.
    /// When it's further back (an agent whose screen didn't change for a
    /// while), the playhead stays where it was put, or every small step
    /// forward would land back on that old frame.
    private func settle(animated: Bool = true) {
        scrolling = false
        updateHold()
        if held != nil {
            needsDisplay = true
            return
        }
        follow(animated: animated)
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
        let p = convert(event.locationInWindow, from: nil)
        guard let i = frame(atContent: scrollX + p.x - bounds.midX, lane: lane(atY: p.y)) else { return }
        held = nil
        if i == m.index { follow(animated: true) } else { m.go(to: i) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let m = model, !m.items.isEmpty else { return }
        let ctx = NSGraphicsContext.current!.cgContext
        let barH: CGFloat = 18
        let left = scrollX - bounds.width / 2 - 40, right = scrollX + bounds.width / 2 + 40
        let current = m.segmentOf.indices.contains(m.index) ? m.segmentOf[m.index] : -1
        let currentLane = m.current.map { m.laneOf[$0.run] } ?? 0

        // Where the recordings start.
        let firstX = bounds.midX - scrollX
        if firstX - spacing / 2 > 0 {
            let text = "Recordings go back \(AppRecordings.store.retentionDays) days"
            let attrs = Self.attrs(11, .medium, .white.withAlphaComponent(0.32))
            let size = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: firstX - 22 - size.width, y: midY(lane: 0) - size.height / 2), withAttributes: attrs)
        }

        // A capsule per segment in its run's lane, its frames as ticks inside.
        for (s, seg) in m.segments.enumerated() {
            let c0 = contentX(seg.first), c1 = contentX(seg.last)
            guard c1 >= left, c0 <= right else { continue }
            let midY = midY(lane: m.laneOf[seg.run])
            let x0 = viewX(seg.first) - spacing / 2 + 1, x1 = viewX(seg.last) + spacing / 2 - 1
            let rect = CGRect(x: x0, y: midY - barH / 2, width: max(3, x1 - x0), height: barH)
            let on = s == current
            ctx.setFillColor(NSColor.white.withAlphaComponent(on ? 0.16 : 0.08).cgColor)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: min(6, rect.width / 2), cornerHeight: min(6, rect.width / 2), transform: nil))
            ctx.fillPath()
            if spacing >= 4 {
                ctx.setFillColor(NSColor.white.withAlphaComponent(on ? 0.42 : 0.24).cgColor)
                // The segment's frames are in time order: start at the first in view.
                var lo = seg.first, hi = seg.last
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if contentX(mid) < left { lo = mid + 1 } else { hi = mid }
                }
                for i in lo...seg.last {
                    if contentX(i) > right { break }
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

        // Each agent display's start: its agent and time, under its lane.
        let labelAttrs = Self.attrs(10.5, .semibold, .white.withAlphaComponent(0.5))
        let timeAttrs = Self.attrs(10.5, .medium, .white.withAlphaComponent(0.32))
        var lastLabelEnd = [CGFloat](repeating: -.infinity, count: m.lanes)
        // Left to right, which isn't always the order the runs started in.
        for r in m.runItems.indices.sorted(by: { contentX(m.runItems[$0].lowerBound) < contentX(m.runItems[$1].lowerBound) }) {
            let items = m.runItems[r]
            guard contentX(items.upperBound) >= left, contentX(items.lowerBound) <= right else { continue }
            let lane = m.laneOf[r]
            let x = max(viewX(items.lowerBound) - spacing / 2, 6)
            guard x > lastLabelEnd[lane] + 8, x < bounds.width else { continue }
            let y = midY(lane: lane) + barH / 2 + 6
            let label = m.runs[r].label
            label.draw(at: CGPoint(x: x, y: y), withAttributes: labelAttrs)
            let lw = label.size(withAttributes: labelAttrs).width
            let time = HistoryModel.time(m.items[items.lowerBound].frame.t, seconds: false)
            time.draw(at: CGPoint(x: x + lw + 5, y: y), withAttributes: timeAttrs)
            lastLabelEnd[lane] = x + lw + 5 + time.size(withAttributes: timeAttrs).width
        }

        // The playhead: across every lane when there are several, marked
        // on the lane of the frame shown.
        let px = bounds.midX.rounded()
        if m.lanes > 1 {
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.35).cgColor)
            let top = midY(lane: 0) - barH / 2 - 5, bottom = midY(lane: m.lanes - 1) + barH / 2 + 5
            ctx.fill(CGRect(x: px - 0.5, y: top, width: 1, height: bottom - top))
        }
        ctx.setFillColor(NSColor.white.cgColor)
        let y = midY(lane: currentLane)
        ctx.addPath(CGPath(roundedRect: CGRect(x: px - 1, y: y - barH / 2 - 5, width: 2, height: barH + 10), cornerWidth: 1, cornerHeight: 1, transform: nil))
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
