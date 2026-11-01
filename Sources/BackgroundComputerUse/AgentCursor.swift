import AppKit
import QuartzCore
import BCUCore

/// A stand-in pointer drawn over a preview, showing where the agent acts.
/// The agent never moves the real cursor, so this one glides to each
/// action's point along a slight arc, presses on clicks and holds down
/// through drags. Positions are global points on the agent display; `map`
/// turns them into the preview layer's coordinates.
final class AgentCursor {
    let layer: CALayer = {
        let l = CALayer()
        l.isHidden = true
        l.shadowColor = NSColor.black.cgColor
        l.shadowOpacity = 0.25
        l.shadowRadius = 1.5
        l.shadowOffset = CGSize(width: 0, height: -1)
        return l
    }()
    /// Click ripples go here, under the pointer.
    let effects = CALayer()

    /// Global point on the agent display to the preview layer's coordinates.
    var map: (CGPoint) -> CGPoint = { $0 }
    /// Points of the preview per point of the agent display.
    var scale: () -> CGFloat = { 1 }

    var hidden = false {
        didSet { if hidden != oldValue { updateVisibility() } }
    }

    private var position: CGPoint?
    private var path: [Segment] = []
    private var events: [(time: CFTimeInterval, event: Event)] = []
    private var timer: Timer?
    private let imageSize: CGSize
    private let hotSpot: CGPoint

    private struct Segment {
        let from: CGPoint, control: CGPoint, to: CGPoint
        let start: CFTimeInterval, duration: CFTimeInterval
        /// Minimum-jerk easing for a reach; even speed while dragging.
        let eased: Bool
    }

    private enum Event { case down, up, ripple(CGPoint) }

    init() {
        let arrow = NSCursor.arrow
        imageSize = arrow.image.size
        hotSpot = arrow.hotSpot
        layer.contents = arrow.image
        layer.bounds = CGRect(origin: .zero, size: imageSize)
        // The hot spot is measured from the top left; layers anchor from the bottom left.
        layer.anchorPoint = CGPoint(x: hotSpot.x / imageSize.width, y: 1 - hotSpot.y / imageSize.height)
    }

    /// Put the pointer somewhere without animating (a preview opening).
    func place(_ p: CGPoint?) {
        guard let p, position == nil else { return }
        position = p
        relayout()
        updateVisibility()
    }

    func handle(_ pointer: AgentPointer, animated: Bool) {
        let now = CACurrentMediaTime()
        let target = pointer.point
        guard animated, let start = position else {
            path = []
            events = []
            setPressed(false)
            if case .drag(let to) = pointer.kind { position = to } else { position = target }
            relayout()
            updateVisibility()
            return
        }
        // A new action replaces whatever was still playing, from where the pointer is now.
        path = []
        events = []
        setPressed(false)
        let reach = travel(from: start, to: target, at: now)
        if let reach { path.append(reach) }
        let arrive = now + (reach?.duration ?? 0)
        switch pointer.kind {
        case .move:
            break
        case .click:
            events.append((arrive, .down))
            events.append((arrive, .ripple(target)))
            events.append((arrive + 0.11, .up))
        case .drag(let to):
            events.append((arrive, .down))
            let hold = arrive + 0.06
            let d = 0.35
            path.append(Segment(from: target, control: CGPoint(x: (target.x + to.x) / 2, y: (target.y + to.y) / 2), to: to,
                                start: hold, duration: d, eased: false))
            events.append((hold + d + 0.02, .up))
        }
        updateVisibility()
        startTimer()
    }

    /// A reach from `a` to `b` that bows a little to one side, taking longer
    /// for longer distances the way a hand does (roughly Fitts's law).
    private func travel(from a: CGPoint, to b: CGPoint, at t: CFTimeInterval) -> Segment? {
        let dx = b.x - a.x, dy = b.y - a.y
        let d = hypot(dx, dy)
        guard d > 0.5 else { return nil }
        let duration = 0.1 + 0.045 * log2(1 + d / 10)
        // Bow to the same side for a given direction, by 6-14% of the distance.
        let side: CGFloat = dx >= 0 ? -1 : 1
        let bow = d * CGFloat.random(in: 0.06...0.14) * side
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let control = CGPoint(x: mid.x - dy / d * bow, y: mid.y + dx / d * bow)
        return Segment(from: a, control: control, to: b, start: t, duration: duration, eased: true)
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        while let first = events.first, first.time <= now {
            events.removeFirst()
            switch first.event {
            case .down: setPressed(true)
            case .up: setPressed(false)
            case .ripple(let p): ripple(at: p)
            }
        }
        while let s = path.first, now >= s.start + s.duration {
            position = s.to
            path.removeFirst()
        }
        if let s = path.first, now >= s.start {
            let u = (now - s.start) / s.duration
            let e = s.eased ? u * u * u * (10 - 15 * u + 6 * u * u) : u
            position = Self.bezier(s.from, s.control, s.to, CGFloat(e))
        }
        relayout()
        if path.isEmpty && events.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    private static func bezier(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        let m = 1 - t
        return CGPoint(x: m * m * a.x + 2 * m * t * c.x + t * t * b.x,
                       y: m * m * a.y + 2 * m * t * c.y + t * t * b.y)
    }

    /// Draw the pointer where it is now (also after the preview resizes).
    func relayout() {
        guard let position else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.position = map(position)
        // About real size in a big preview, a bit smaller in the popover.
        let k = min(1, max(0.62, scale() * 1.6))
        layer.bounds = CGRect(origin: .zero, size: CGSize(width: imageSize.width * k, height: imageSize.height * k))
        CATransaction.commit()
    }

    private func updateVisibility() {
        let show = position != nil && !hidden
        guard show == layer.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.isHidden = !show
        CATransaction.commit()
        if show {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.2
            layer.add(fade, forKey: "fade")
        }
    }

    private var pressed = false

    private func setPressed(_ on: Bool) {
        guard on != pressed else { return }
        pressed = on
        let s: CGFloat = on ? 0.84 : 1
        CATransaction.begin()
        CATransaction.setAnimationDuration(on ? 0.06 : 0.12)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        layer.transform = CATransform3DMakeScale(s, s, 1)
        CATransaction.commit()
    }

    private func ripple(at p: CGPoint) {
        guard !hidden else { return }
        let r: CGFloat = 13
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), transform: nil)
        ring.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        ring.strokeColor = NSColor.controlAccentColor.cgColor
        ring.lineWidth = 1.5
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.position = map(p)
        ring.opacity = 0
        effects.addSublayer(ring)
        CATransaction.commit()

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.25
        grow.toValue = 1
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.9, 0.7, 0]
        fade.keyTimes = [0, 0.4, 1]
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.42
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(group, forKey: "ripple")
        CATransaction.commit()
    }
}
