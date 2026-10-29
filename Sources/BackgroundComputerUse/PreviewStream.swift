import AppKit
import BCUCore

/// Live view of the agent display, built by compositing its windows a few
/// times a second. No ScreenCaptureKit stream, so no screen-sharing indicator.
final class PreviewStream {
    private let engine: Engine
    private let onFrame: (CGImage) -> Void
    private let queue = DispatchQueue(label: "bcu.preview", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var inFlight = false

    init(engine: Engine, onFrame: @escaping (CGImage) -> Void) {
        self.engine = engine
        self.onFrame = onFrame
    }

    func start(width: Int, fps: Int) {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / Double(max(1, fps)))
        t.setEventHandler { [weak self] in
            guard let self, !self.inFlight else { return }
            self.inFlight = true
            let image = Capture.composite(display: self.engine.display, width: width)
            self.inFlight = false
            if let image { DispatchQueue.main.async { self.onFrame(image) } }
        }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
