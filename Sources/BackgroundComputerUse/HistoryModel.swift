import AppKit
import SwiftUI
import BCUCore

/// Every recorded frame across every agent display, oldest first, grouped
/// the way Coast groups its timeline: a run per agent display, and within
/// it a segment per stretch of frames in the same app.
final class HistoryModel: ObservableObject {
    struct Item {
        let run: Int
        let frame: RecordedFrame
    }

    struct Segment {
        let run: Int
        let first: Int
        let last: Int
        let app: String
        let bundleID: String?
    }

    private(set) var runs: [RecordedRun] = []
    private(set) var items: [Item] = []
    private(set) var segments: [Segment] = []
    /// Item index to its segment.
    private(set) var segmentOf: [Int] = []
    /// The agent did something between this frame and the one before.
    private(set) var acted: [Bool] = []

    @Published private(set) var loaded = false
    @Published private(set) var index = 0
    @Published var highlightText = false

    /// The track and the frame view follow the model through these.
    var onItemsChanged: (() -> Void)?
    var onIndexChanged: ((_ animated: Bool) -> Void)?

    private var observer: NSObjectProtocol?
    private var reloadPending = false

    init() {
        observer = NotificationCenter.default.addObserver(forName: Recordings.changed, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleReload()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Reads the recordings and opens at the latest frame (of `session`, if given).
    func load(session: String? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let runs = Recordings.all()
            DispatchQueue.main.async {
                self.apply(runs, keep: nil)
                if let session, let last = self.items.lastIndex(where: { self.runs[$0.run].session == session }) {
                    self.index = last
                } else {
                    self.index = max(0, self.items.count - 1)
                }
                self.loaded = true
                self.onItemsChanged?()
                self.onIndexChanged?(false)
            }
        }
    }

    /// A live run grew: rebuild, staying on the same frame, or on the
    /// newest one if that's where the user was.
    private func scheduleReload() {
        guard loaded, !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.reloadPending = false
            let atEnd = self.index >= self.items.count - 1
            let keep = self.current.map { (self.runs[$0.run].id, $0.frame.t) }
            let loaded = self.runs
            DispatchQueue.global(qos: .userInitiated).async {
                let runs = Recordings.all(reusing: loaded)
                DispatchQueue.main.async {
                    self.apply(runs, keep: atEnd ? nil : keep)
                    if atEnd { self.index = max(0, self.items.count - 1) }
                    self.onItemsChanged?()
                    self.onIndexChanged?(false)
                }
            }
        }
    }

    private func apply(_ runs: [RecordedRun], keep: (String, Double)?) {
        self.runs = runs
        var items: [Item] = [], segments: [Segment] = [], segmentOf: [Int] = [], acted: [Bool] = []
        for (r, run) in runs.enumerated() {
            let frames = run.frames
            let actions = run.events.filter { $0.text != nil }.map(\.t)
            var a = 0
            var prevT = run.start
            for f in frames {
                let i = items.count
                items.append(Item(run: r, frame: f))
                while a < actions.count && actions[a] <= prevT { a += 1 }
                acted.append(a < actions.count && actions[a] <= f.t)
                prevT = f.t
                if let s = segments.last, s.run == r, s.app == f.app {
                    segments[segments.count - 1] = Segment(run: r, first: s.first, last: i, app: s.app, bundleID: s.bundleID)
                } else {
                    segments.append(Segment(run: r, first: i, last: i, app: f.app, bundleID: f.bundleID))
                }
                segmentOf.append(segments.count - 1)
            }
        }
        self.items = items
        self.segments = segments
        self.segmentOf = segmentOf
        self.acted = acted
        if let keep, let i = items.firstIndex(where: { runs[$0.run].id == keep.0 && $0.frame.t == keep.1 }) {
            index = i
        } else {
            index = min(index, max(0, items.count - 1))
        }
    }

    // MARK: Moving

    var current: Item? { items.indices.contains(index) ? items[index] : nil }
    var currentRun: RecordedRun? { current.map { runs[$0.run] } }
    var isEmpty: Bool { items.isEmpty }
    var atEnd: Bool { index >= items.count - 1 }

    /// From the track, as it scrolls: the track is already there.
    func scrubbed(to i: Int) {
        guard i != index, items.indices.contains(i) else { return }
        index = i
        onIndexChanged?(false)
    }

    func go(to i: Int, animated: Bool = true) {
        guard !items.isEmpty else { return }
        let i = min(max(0, i), items.count - 1)
        guard i != index else { return }
        index = i
        onIndexChanged?(animated)
    }

    func step(_ by: Int) { go(to: index + by, animated: false) }

    /// The start of the previous segment, or of this one when partway into it.
    func previousSegment() {
        guard !segmentOf.isEmpty else { return }
        let s = segmentOf[index]
        if index > segments[s].first { go(to: segments[s].first) } else if s > 0 { go(to: segments[s - 1].first) }
    }

    func nextSegment() {
        guard !segmentOf.isEmpty else { return }
        let s = segmentOf[index]
        if s + 1 < segments.count { go(to: segments[s + 1].first) } else { go(to: items.count - 1) }
    }

    var hasPreviousSegment: Bool { !segmentOf.isEmpty && (segmentOf[index] > 0 || index > 0) }
    var hasNextSegment: Bool { !segmentOf.isEmpty && index < items.count - 1 }

    // MARK: What the header shows

    var appName: String {
        guard let f = current?.frame else { return "" }
        return f.app.isEmpty ? "No windows" : f.app
    }

    var appIcon: NSImage? { AppIcons.icon(current?.frame.bundleID) }

    var agentLabel: String { currentRun?.label ?? "" }

    /// The newest frame of a display that's still recording.
    var isLive: Bool {
        guard let item = current, let run = currentRun, run.isLive else { return false }
        return index + 1 >= items.count || items[index + 1].run != item.run
    }

    var timeText: String {
        guard let t = current?.frame.t else { return "" }
        return Self.time(t, seconds: true)
    }

    /// The last thing the agent did before this frame.
    var actionText: String? {
        guard let item = current else { return nil }
        guard let e = runs[item.run].events.last(where: { $0.text != nil && $0.t <= item.frame.t }), let text = e.text else { return nil }
        return Self.tidy(text)
    }

    /// The agent's pointer at this frame, in display points, and whether it just clicked.
    var pointer: (CGPoint, Bool)? {
        guard let item = current else { return nil }
        guard let e = runs[item.run].events.last(where: { $0.point != nil && $0.t <= item.frame.t }), let p = e.point else { return nil }
        return (p, e.click && item.frame.t - e.t < 1200)
    }

    /// "click (120 ms): Clicked …" reads as "click: Clicked …".
    static func tidy(_ text: String) -> String {
        text.replacingOccurrences(of: #" \(\d+ ms\)"#, with: "", options: .regularExpression)
    }

    static func time(_ t: Double, seconds: Bool) -> String {
        let date = Date(timeIntervalSince1970: t / 1000)
        let clock = DateFormatter()
        clock.locale = .current
        clock.setLocalizedDateFormatFromTemplate(seconds ? "jmmss" : "jmm")
        let cal = Calendar.current
        if cal.isDateInToday(date) { return clock.string(from: date) }
        if cal.isDateInYesterday(date) { return "Yesterday " + clock.string(from: date) }
        let day = DateFormatter()
        day.locale = .current
        day.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return day.string(from: date) + " " + clock.string(from: date)
    }
}

/// App icons by bundle ID, looked up once each.
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(_ bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let hit = cache[bundleID] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
    }
}

/// Decodes frames off the main thread, newest request first, and keeps the
/// last few around for quick back and forth.
final class FrameLoader {
    private let queue = DispatchQueue(label: "bcu.history.decode", qos: .userInteractive)
    private let lock = NSLock()
    private var wanted: (run: RecordedRun, frame: RecordedFrame)?
    private var busy = false
    private var cache: [String: CGImage] = [:]
    private var order: [String] = []
    /// Main thread: a decoded frame (key, image).
    var onImage: ((String, CGImage) -> Void)?

    static func key(_ run: RecordedRun, _ f: RecordedFrame) -> String { "\(run.id)/\(Int64(f.t))" }

    func cached(_ run: RecordedRun, _ f: RecordedFrame) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        return cache[Self.key(run, f)]
    }

    func request(_ run: RecordedRun, _ f: RecordedFrame) {
        lock.lock()
        wanted = (run, f)
        let start = !busy
        busy = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let next = wanted else { busy = false; lock.unlock(); return }
            wanted = nil
            let key = Self.key(next.run, next.frame)
            let hit = cache[key]
            lock.unlock()
            guard let image = hit ?? next.run.image(for: next.frame) else { continue }
            lock.lock()
            if hit == nil {
                cache[key] = image
                order.append(key)
                if order.count > 40 { cache[order.removeFirst()] = nil }
            }
            lock.unlock()
            DispatchQueue.main.async { self.onImage?(key, image) }
        }
    }
}
