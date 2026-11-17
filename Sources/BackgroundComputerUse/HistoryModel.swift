import AppKit
import SwiftUI
import BCUCore

/// Every recorded frame across every agent display, grouped the way Coast
/// groups its timeline: a run per agent display, and within it a segment
/// per stretch of frames in the same app. Agents can work at the same time,
/// so runs share one clock: each frame has a slot in the order of all
/// frames by time, and runs that overlap go in lanes one above the other
/// instead of one after the other.
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
    /// Item index to its place among all frames by time (0 is the oldest),
    /// and back.
    private(set) var slot: [Int] = []
    private(set) var byTime: [Int] = []
    /// Item index to the stretch of time it's in: runs that overlap share
    /// one, and the track puts a gap between stretches.
    private(set) var stretch: [Int] = []
    /// Run index to its lane (0 is the top one), and to its items.
    private(set) var laneOf: [Int] = []
    private(set) var runItems: [ClosedRange<Int>] = []
    /// The most runs that were ever recording at once.
    @Published private(set) var lanes = 1

    @Published private(set) var loaded = false
    @Published private(set) var index = 0
    @Published var highlightText = false

    /// The track and the frame view follow the model through these.
    var onItemsChanged: (() -> Void)?
    var onIndexChanged: ((_ animated: Bool) -> Void)?

    private var observer: NSObjectProtocol?
    private var reloadPending = false
    private let store = AppRecordings.store

    init() {
        observer = NotificationCenter.default.addObserver(forName: Recordings.changed, object: store, queue: .main) { [weak self] _ in
            self?.scheduleReload()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Reads the recordings and opens at the latest frame (of `session`, if given).
    func load(session: String? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let runs = self.store.all()
            DispatchQueue.main.async {
                self.apply(runs, keep: nil)
                if let session, let last = self.items.lastIndex(where: { self.runs[$0.run].session == session }) {
                    self.index = last
                } else {
                    self.index = self.byTime.last ?? 0
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
            // On a run's newest frame: stay on it as the run grows, even
            // while another agent records newer frames at the same time.
            let following = self.atRunEnd ? self.currentRun?.id : nil
            let keep = self.current.map { (self.runs[$0.run].id, $0.frame.t) }
            let loaded = self.runs
            DispatchQueue.global(qos: .userInitiated).async {
                let runs = self.store.all(reusing: loaded)
                DispatchQueue.main.async {
                    self.apply(runs, keep: following == nil ? keep : nil)
                    if let following {
                        if let r = self.runs.firstIndex(where: { $0.id == following }) {
                            self.index = self.runItems[r].upperBound
                        } else {
                            self.index = self.byTime.last ?? 0
                        }
                    }
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
        placeOnClock()
        if let keep, let i = items.firstIndex(where: { runs[$0.run].id == keep.0 && $0.frame.t == keep.1 }) {
            index = i
        } else {
            index = min(index, max(0, items.count - 1))
        }
    }

    /// Slots, stretches and lanes. Items are grouped by run, the runs oldest
    /// first, and in time order within a run.
    private func placeOnClock() {
        var runItems: [ClosedRange<Int>] = []
        var first = 0
        for run in runs {
            let n = run.frames.count
            runItems.append(first...(first + max(n, 1) - 1))
            first += n
        }
        // Each run takes the top lane that's free when it starts.
        var laneEnds: [Double] = [], laneOf: [Int] = []
        var stretchOfRun: [Int] = [], stretchEnd = -Double.infinity, stretches = -1
        for range in runItems where items.indices.contains(range.upperBound) {
            let from = items[range.lowerBound].frame.t, to = items[range.upperBound].frame.t
            if let free = laneEnds.firstIndex(where: { $0 < from }) {
                laneEnds[free] = to
                laneOf.append(free)
            } else {
                laneEnds.append(to)
                laneOf.append(laneEnds.count - 1)
            }
            if from > stretchEnd { stretches += 1 }
            stretchEnd = max(stretchEnd, to)
            stretchOfRun.append(stretches)
        }
        let byTime = items.indices.sorted { a, b in
            let ta = items[a].frame.t, tb = items[b].frame.t
            return ta != tb ? ta < tb : a < b
        }
        var slot = [Int](repeating: 0, count: items.count)
        for (k, i) in byTime.enumerated() { slot[i] = k }
        self.byTime = byTime
        self.slot = slot
        self.stretch = items.map { stretchOfRun[$0.run] }
        self.laneOf = laneOf
        self.runItems = runItems
        let lanes = max(1, laneEnds.count)
        if lanes != self.lanes { self.lanes = lanes }
    }

    /// The frame `by` away from item `i` in its own run; past the run's
    /// ends, the frame `by` away in time across every run.
    private func neighbour(_ i: Int, _ by: Int) -> Int? {
        let j = i + by
        if items.indices.contains(j), items[j].run == items[i].run { return j }
        let s = slot[i] + by
        return byTime.indices.contains(s) ? byTime[s] : nil
    }

    // MARK: Moving

    var current: Item? { items.indices.contains(index) ? items[index] : nil }
    var currentRun: RecordedRun? { current.map { runs[$0.run] } }
    var isEmpty: Bool { items.isEmpty }
    /// On the newest frame of all.
    var atEnd: Bool { index == byTime.last ?? 0 }
    /// On the newest frame of its run.
    private var atRunEnd: Bool { index + 1 >= items.count || items[index + 1].run != items[index].run }

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

    func goToOldest() { if let i = byTime.first { go(to: i) } }
    func goToNewest() { if let i = byTime.last { go(to: i) } }

    /// A frame along the current run; past its ends, on in time.
    func step(_ by: Int) {
        guard items.indices.contains(index), let i = neighbour(index, by) else { return }
        go(to: i, animated: false)
    }

    /// The start of the previous segment, or of this one when partway into
    /// it. Before the run's first segment, the segment that came before in time.
    func previousSegment() {
        guard segmentOf.indices.contains(index) else { return }
        let s = segmentOf[index]
        if index > segments[s].first {
            go(to: segments[s].first)
        } else if s > 0, segments[s - 1].run == segments[s].run {
            go(to: segments[s - 1].first)
        } else if let i = neighbour(index, -1) {
            go(to: segments[segmentOf[i]].first)
        }
    }

    /// The start of the next segment in the run; after its last one, the
    /// frame that came next in time.
    func nextSegment() {
        guard segmentOf.indices.contains(index) else { return }
        let s = segmentOf[index]
        if s + 1 < segments.count, segments[s + 1].run == segments[s].run {
            go(to: segments[s + 1].first)
        } else if let i = neighbour(segments[s].last, 1) {
            go(to: i)
        } else {
            goToNewest()
        }
    }

    var hasPreviousSegment: Bool { slot.indices.contains(index) && slot[index] > 0 }
    var hasNextSegment: Bool { slot.indices.contains(index) && slot[index] < byTime.count - 1 }

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
