import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import BCUShared

/// Wall-clock milliseconds since 1970, for recording timestamps.
public func wallMs() -> Double { Date().timeIntervalSince1970 * 1000 }

/// One kept frame of a recording: when, and which app was in front on the
/// agent display.
public struct RecordedFrame {
    public let t: Double
    public let app: String
    public let bundleID: String?
}

/// Something the agent did, from the session's activity log, or where one of
/// its actions landed (display-relative points).
public struct RecordedEvent {
    public let t: Double
    public let text: String?
    public let isError: Bool
    public let point: CGPoint?
    public let click: Bool
}

/// A stretch of frames compacted into one video file.
struct RecordedChunk {
    let file: String
    let from: Double
    let to: Double
}

/// Everything one agent display showed, from when it was made until it was
/// removed. On disk under `recordings/<id>/`:
///   meta.json      session, label, start, end, display size
///   frames.jsonl   one line per kept frame
///   events.jsonl   the session's activity and pointer, one line each
///   chunks.jsonl   one line per video file
///   staging/       frames not yet in a video, as JPEGs named by their time
///   chunk-*.mp4    compacted frames, each at its own time (variable rate)
public final class RecordedRun {
    public let id: String
    public let dir: URL
    public let session: String
    public let label: String
    public let start: Double
    /// The agent display's size in points.
    public let size: CGSize

    private let lock = NSLock()
    private var _frames: [RecordedFrame] = []
    private var _events: [RecordedEvent] = []
    private var _chunks: [RecordedChunk] = []
    private var _end: Double?
    private var _live = false

    init(id: String, dir: URL, session: String, label: String, start: Double, size: CGSize) {
        self.id = id
        self.dir = dir
        self.session = session
        self.label = label
        self.start = start
        self.size = size
    }

    public var frames: [RecordedFrame] { lock.lock(); defer { lock.unlock() }; return _frames }
    public var events: [RecordedEvent] { lock.lock(); defer { lock.unlock() }; return _events }
    var chunks: [RecordedChunk] { lock.lock(); defer { lock.unlock() }; return _chunks }
    /// Still being recorded.
    public var isLive: Bool { lock.lock(); defer { lock.unlock() }; return _live }
    public var end: Double { lock.lock(); defer { lock.unlock() }; return _end ?? _frames.last?.t ?? start }

    func setLive(_ live: Bool) { lock.lock(); _live = live; if !live, _end == nil { _end = wallMs() }; lock.unlock() }
    func append(_ f: RecordedFrame) { lock.lock(); _frames.append(f); lock.unlock() }
    func append(_ e: RecordedEvent) { lock.lock(); _events.append(e); lock.unlock() }
    func append(_ c: RecordedChunk) { lock.lock(); _chunks.append(c); lock.unlock() }

    /// Forgets a chunk the size limit deleted, and its frames.
    func drop(_ c: RecordedChunk) {
        lock.lock()
        _chunks.removeAll { $0.file == c.file }
        _frames.removeAll { $0.t >= c.from && $0.t <= c.to }
        lock.unlock()
        decodeLock.lock(); generators[c.file] = nil; decodeLock.unlock()
    }

    /// Every chunk it knows of is still on disk (the size limit deletes the oldest first).
    var isIntact: Bool {
        guard let c = chunks.first else { return true }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(c.file).path)
    }

    var stagingDir: URL { dir.appendingPathComponent("staging", isDirectory: true) }
    func stagedURL(_ t: Double) -> URL { stagingDir.appendingPathComponent("\(Int64(t)).jpg") }

    // MARK: Reading frames

    private let decodeLock = NSLock()
    private var generators: [String: AVAssetImageGenerator] = [:]

    /// The picture of a frame: from its video once compacted, else its JPEG.
    public func image(for frame: RecordedFrame) -> CGImage? {
        for _ in 0..<2 {
            if let c = chunks.first(where: { frame.t >= $0.from && frame.t <= $0.to }) {
                return decode(c, at: frame.t)
            }
            if let src = CGImageSourceCreateWithURL(stagedURL(frame.t) as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                return image
            }
            // Compacted between the two checks: look again.
        }
        return nil
    }

    private func decode(_ c: RecordedChunk, at t: Double) -> CGImage? {
        decodeLock.lock(); defer { decodeLock.unlock() }
        let gen: AVAssetImageGenerator
        if let g = generators[c.file] {
            gen = g
        } else {
            let asset = AVURLAsset(url: dir.appendingPathComponent(c.file))
            gen = AVAssetImageGenerator(asset: asset)
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            gen.appliesPreferredTrackTransform = false
            if generators.count > 6 { generators.removeAll() }
            generators[c.file] = gen
        }
        // Read 2 ms in. Older chunks rounded times to 1/600 s, which can put
        // a frame just after its own time, and reading at that exact time
        // gives the frame before it. Frames are always further apart than
        // 2 ms. Those chunks also end 1 ms after their last frame, which is
        // then read at its own time.
        let ms = CMTimeValue(max(0, t - c.from))
        return (try? gen.copyCGImage(at: CMTime(value: ms + 2, timescale: 1000), actualTime: nil))
            ?? (try? gen.copyCGImage(at: CMTime(value: ms, timescale: 1000), actualTime: nil))
    }

    // MARK: Disk

    func writeMeta() {
        lock.lock()
        var meta: [String: Any] = ["v": 1, "session": session, "label": label, "start": start,
                                   "w": size.width, "h": size.height]
        if let e = _end { meta["end"] = e }
        lock.unlock()
        if let data = try? JSONSerialization.data(withJSONObject: meta) {
            try? data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        }
    }

    /// Loads a finished run from disk.
    static func load(_ dir: URL) -> RecordedRun? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
              let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let start = meta["start"] as? Double else { return nil }
        let run = RecordedRun(id: dir.lastPathComponent, dir: dir, session: meta["session"] as? String ?? "",
                              label: meta["label"] as? String ?? "Agent", start: start,
                              size: CGSize(width: meta["w"] as? Double ?? 1600, height: meta["h"] as? Double ?? 1000))
        run._end = meta["end"] as? Double
        for line in lines(dir.appendingPathComponent("frames.jsonl")) {
            guard let t = line["t"] as? Double else { continue }
            run._frames.append(RecordedFrame(t: t, app: line["a"] as? String ?? "", bundleID: line["b"] as? String))
        }
        for line in lines(dir.appendingPathComponent("events.jsonl")) {
            guard let t = line["t"] as? Double else { continue }
            let p = (line["p"] as? [Double]).flatMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
            run._events.append(RecordedEvent(t: t, text: line["x"] as? String, isError: line["e"] as? Bool ?? false,
                                             point: p, click: line["c"] as? Bool ?? false))
        }
        for line in lines(dir.appendingPathComponent("chunks.jsonl")) {
            guard let f = line["f"] as? String, let from = line["from"] as? Double, let to = line["to"] as? Double,
                  FileManager.default.fileExists(atPath: dir.appendingPathComponent(f).path) else { continue }
            run._chunks.append(RecordedChunk(file: f, from: from, to: to))
        }
        // Frames whose picture is gone (a crash before their JPEG was written).
        let staged = Set(((try? FileManager.default.contentsOfDirectory(atPath: run.stagingDir.path)) ?? []))
        run._frames.removeAll { f in
            !run._chunks.contains { f.t >= $0.from && f.t <= $0.to } && !staged.contains("\(Int64(f.t)).jpg")
        }
        run._frames.sort { $0.t < $1.t }
        return run
    }

    private static func lines(_ url: URL) -> [[String: Any]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }
}

/// Appends JSON lines to a file.
private final class LineWriter {
    private let handle: FileHandle?
    init(_ url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }
    func write(_ obj: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)
        handle?.write(data)
    }
    deinit { try? handle?.close() }
}

/// One app's recordings: where they go, how long they're kept and how much
/// room they may take. Each app that shows sessions (the menu bar app, or a
/// host app such as Proactive Agent) decides whether its sessions are
/// recorded and keeps its own, so no app sees another's (`Hub.setRecordings`).
public final class Recordings {
    public static let defaultRetentionDays = 7
    /// The least `limitMB` takes.
    public static let minLimitMB = 50
    public static let defaultLimitMB = 300

    /// Main thread, with the store as object: a live run got a frame or an
    /// event, or the size limit deleted some.
    public static let changed = Notification.Name("bcu.recordingChanged")

    public let directory: URL

    private let lock = NSLock()
    private var live: [String: RecordedRun] = [:]
    private var _limitMB: Int
    private var _retentionDays: Int
    private let limitQueue = DispatchQueue(label: "bcu.recordings.limit", qos: .utility)
    var limitBytesOverride: Int64?

    public init(directory: URL, limitMB: Int = defaultLimitMB, retentionDays: Int = defaultRetentionDays) {
        self.directory = directory
        _retentionDays = max(1, retentionDays)
        _limitMB = max(Self.minLimitMB, limitMB)
    }

    /// Runs that ended longer ago than this go at the next `maintain`.
    public var retentionDays: Int {
        get { lock.lock(); defer { lock.unlock() }; return _retentionDays }
        set { lock.lock(); _retentionDays = max(1, newValue); lock.unlock() }
    }

    func setLive(_ run: RecordedRun, _ on: Bool) {
        lock.lock(); live[run.id] = on ? run : nil; lock.unlock()
    }

    func post() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: self) }
    }

    /// Every run, oldest first. Live ones are the recorder's own objects, so
    /// they keep growing.
    /// `reusing`: runs loaded before, kept as they are (finished runs don't change).
    public func all(reusing: [RecordedRun] = []) -> [RecordedRun] {
        lock.lock(); let liveRuns = live; lock.unlock()
        let known = Dictionary(reusing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let dirs = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var runs: [RecordedRun] = []
        for d in dirs where d.hasDirectoryPath {
            let id = d.lastPathComponent
            if let r = liveRuns[id] ?? known[id].flatMap({ $0.isIntact ? $0 : nil }) ?? RecordedRun.load(d) { runs.append(r) }
        }
        return runs.filter { !$0.frames.isEmpty }.sorted { $0.start < $1.start }
    }

    /// Background: compact what a crash left in staging and delete runs that
    /// ended more than `retentionDays` ago.
    public func maintain() {
        DispatchQueue.global(qos: .utility).async {
            let cutoff = wallMs() - Double(self.retentionDays) * 86_400_000
            self.lock.lock(); let liveIDs = Set(self.live.keys); self.lock.unlock()
            let dirs = (try? FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for d in dirs where d.hasDirectoryPath && !liveIDs.contains(d.lastPathComponent) {
                guard let run = RecordedRun.load(d) else {
                    // No meta: half made. Gone once it's old.
                    let m = (try? d.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    if (m?.timeIntervalSince1970 ?? 0) * 1000 < cutoff { try? FileManager.default.removeItem(at: d) }
                    continue
                }
                if run.end < cutoff {
                    try? FileManager.default.removeItem(at: d)
                    Log.info("recordings: deleted \(run.id), older than \(self.retentionDays) days")
                    continue
                }
                let staged = run.frames.filter { f in !run.chunks.contains { f.t >= $0.from && f.t <= $0.to } }
                if !staged.isEmpty {
                    Compactor.compact(run, frames: staged, store: self)
                    run.writeMeta()
                }
            }
            self.enforceLimit()
        }
    }

    // MARK: Size limit

    /// The most recordings may take on disk, in MB. Past it the oldest go first.
    public var limitMB: Int {
        get { lock.lock(); defer { lock.unlock() }; return _limitMB }
        set { lock.lock(); _limitMB = max(Self.minLimitMB, newValue); lock.unlock(); enforceLimit() }
    }

    /// Waits for size-limit passes already queued.
    func waitForLimit() { limitQueue.sync {} }

    /// Bytes on disk for every recording.
    public func usedBytes() -> Int64 {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return dirs.reduce(0) { $0 + Self.size(of: $1) }
    }

    private static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey]
        func bytes(_ f: URL) -> Int64 {
            let v = try? f.resourceValues(forKeys: keys)
            return Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
        guard (try? url.resourceValues(forKeys: keys))?.isDirectory == true else { return bytes(url) }
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e { total += bytes(f) }
        return total
    }

    /// Background: while recordings take more than `limitMB`, deletes the
    /// oldest video chunks (and with them their frames), and whole runs once
    /// nothing of them is left. Frames still waiting in a live run's staging
    /// are the newest and stay.
    public func enforceLimit() {
        limitQueue.async {
            let limit = self.limitBytesOverride ?? Int64(self.limitMB) * 1_000_000
            var used = self.usedBytes()
            guard used > limit else { return }
            self.lock.lock(); let liveRuns = self.live; self.lock.unlock()
            let dirs = (try? FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil)) ?? []
            let runs = dirs.filter(\.hasDirectoryPath)
                .compactMap { liveRuns[$0.lastPathComponent] ?? RecordedRun.load($0) }
                .sorted { $0.start < $1.start }
            var freed = 0
            for run in runs where used > limit {
                let isLive = liveRuns[run.id] != nil
                for c in run.chunks where used > limit {
                    let url = run.dir.appendingPathComponent(c.file)
                    let bytes = Self.size(of: url)
                    try? FileManager.default.removeItem(at: url)
                    run.drop(c)
                    used -= bytes
                    freed += 1
                }
                if !isLive, used > limit || run.chunks.isEmpty {
                    used -= Self.size(of: run.dir)
                    try? FileManager.default.removeItem(at: run.dir)
                }
            }
            Log.info("recordings: over the \(limit / 1_000_000) MB limit in \(self.directory.path), deleted the oldest \(freed) chunks")
            self.post()
        }
    }

    /// Deletes every recording that isn't being made right now.
    public func deleteAll() {
        lock.lock(); let liveIDs = Set(live.keys); lock.unlock()
        let dirs = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for d in dirs where !liveIDs.contains(d.lastPathComponent) { try? FileManager.default.removeItem(at: d) }
    }
}

/// Turns staged JPEGs into a video chunk.
enum Compactor {
    /// Encodes `frames` (in time order, all staged) into one HEVC file, adds
    /// it to the run and deletes their JPEGs. Any thread; blocks.
    static func compact(_ run: RecordedRun, frames: [RecordedFrame], store: Recordings) {
        guard let first = frames.first, let last = frames.last else { return }
        guard let probe = CGImageSourceCreateWithURL(run.stagedURL(first.t) as CFURL, nil),
              let firstImage = CGImageSourceCreateImageAtIndex(probe, 0, nil) else { return }
        let w = firstImage.width, h = firstImage.height
        let name = "chunk-\(Int64(first.t)).mp4"
        let url = run.dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoQualityKey: 0.6,
                // Short GOPs so a seek decodes only a few frames.
                AVVideoMaxKeyFrameIntervalKey: 10,
                AVVideoAllowFrameReorderingKey: false,
            ] as [String: Any],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        // Exact ms, so a frame's time in the file is the time it was taken.
        input.mediaTimeScale = 1000
        writer.movieTimeScale = 1000
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
        ])
        guard writer.canAdd(input) else { return }
        writer.add(input)
        guard writer.startWriting() else { Log.info("recordings: can't write \(name): \(writer.error.map { "\($0)" } ?? "?")"); return }
        writer.startSession(atSourceTime: .zero)
        var lastPts: CMTimeValue = -1
        var written: [RecordedFrame] = []
        for f in frames {
            guard let src = CGImageSourceCreateWithURL(run.stagedURL(f.t) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
                  let pool = adaptor.pixelBufferPool else { continue }
            let pts = max(lastPts + 1, CMTimeValue(f.t - first.t))
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { usleep(2000) }
            if adaptor.append(buffer, withPresentationTime: CMTime(value: pts, timescale: 1000)) {
                lastPts = pts
                written.append(f)
            }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        // The last frame lasts a moment, so reading it 2 ms in still finds it.
        writer.endSession(atSourceTime: CMTime(value: lastPts + 100, timescale: 1000))
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed, !written.isEmpty else {
            Log.info("recordings: compacting \(run.id) failed: \(writer.error.map { "\($0)" } ?? "no frames")")
            try? FileManager.default.removeItem(at: url)
            return
        }
        // Frames whose pts had to be nudged are still found: lookups go by
        // chunk range, and the decoder returns the frame showing at that time.
        let chunk = RecordedChunk(file: name, from: first.t, to: last.t)
        LineWriter(run.dir.appendingPathComponent("chunks.jsonl")).write(["f": name, "from": first.t, "to": last.t, "n": written.count])
        run.append(chunk)
        for f in frames { try? FileManager.default.removeItem(at: run.stagedURL(f.t)) }
        store.enforceLimit()
    }
}

/// Writes one run: frames to staging (packed into a video every
/// `chunkFrames` frames or `chunkMs`), activity and pointer lines.
/// Not thread-safe: the recorder calls it from its queue.
final class RunWriter {
    let run: RecordedRun
    private let store: Recordings
    private let frameLog: LineWriter
    private let eventLog: LineWriter
    private let compactQueue: DispatchQueue
    private var staged: [RecordedFrame] = []
    private var lastT = 0.0

    static let chunkFrames = 120
    static let chunkMs = 60_000.0

    init?(store: Recordings, id: String, session: String, label: String, start: Double, size: CGSize, compactQueue: DispatchQueue) {
        let dir = store.directory.appendingPathComponent(id, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("staging"), withIntermediateDirectories: true)
        } catch {
            Log.info("recordings: can't create \(dir.path): \(error)")
            return nil
        }
        run = RecordedRun(id: id, dir: dir, session: session, label: label, start: start, size: size)
        run.setLive(true)
        run.writeMeta()
        frameLog = LineWriter(dir.appendingPathComponent("frames.jsonl"))
        eventLog = LineWriter(dir.appendingPathComponent("events.jsonl"))
        self.compactQueue = compactQueue
        self.store = store
        store.setLive(run, true)
    }

    /// Stages a frame already at its recorded size.
    func add(_ image: CGImage, t: Double, app: String, bundleID: String?) {
        var t = t.rounded()
        if t <= lastT { t = lastT + 1 }
        guard let dest = CGImageDestinationCreateWithURL(run.stagedURL(t) as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return }
        lastT = t
        let frame = RecordedFrame(t: t, app: app, bundleID: bundleID)
        run.append(frame)
        var line: [String: Any] = ["t": t, "a": app]
        if let bundleID { line["b"] = bundleID }
        frameLog.write(line)
        staged.append(frame)
        if staged.count >= Self.chunkFrames || t - (staged.first?.t ?? t) >= Self.chunkMs {
            let batch = staged, run = self.run, store = self.store
            staged = []
            compactQueue.async { Compactor.compact(run, frames: batch, store: store) }
        }
        store.post()
    }

    func note(_ text: String, error: Bool, t: Double) {
        let e = RecordedEvent(t: t, text: String(text.prefix(300)), isError: error, point: nil, click: false)
        run.append(e)
        var line: [String: Any] = ["t": t, "x": e.text ?? ""]
        if error { line["e"] = true }
        eventLog.write(line)
        store.post()
    }

    /// `point` in display-relative points.
    func pointer(_ point: CGPoint, click: Bool, t: Double) {
        run.append(RecordedEvent(t: t, text: nil, isError: false, point: point, click: click))
        var line: [String: Any] = ["t": t, "p": [Double(point.x), Double(point.y)]]
        if click { line["c"] = true }
        eventLog.write(line)
    }

    /// Packs what's left and marks the run finished. `done` runs after, on the compact queue.
    func finish(_ done: (() -> Void)? = nil) {
        let rest = staged, run = self.run, store = self.store
        staged = []
        compactQueue.async {
            Compactor.compact(run, frames: rest, store: store)
            run.setLive(false)
            run.writeMeta()
            store.setLive(run, false)
            store.post()
            if run.frames.isEmpty { try? FileManager.default.removeItem(at: run.dir) }
            done?()
        }
    }

}

/// Records one session's agent display while it exists: a frame whenever the
/// picture changes (checked twice a second and right after each call), what
/// the agent did, and where its actions landed. Frames go to disk as JPEGs
/// first, so they can be watched right away and survive a crash, and every
/// minute or so they're packed into a video.
public final class SessionRecorder {
    private let sessionID: String
    private let label: String
    private let display: AgentDisplay
    private let queue = DispatchQueue(label: "bcu.recorder", qos: .utility)
    private let compactQueue = DispatchQueue(label: "bcu.recorder.compact", qos: .background)
    private var timer: DispatchSourceTimer?
    private var writer: RunWriter?
    /// Where this session's host keeps recordings; nil when it doesn't record.
    private var store: Recordings?
    private var displayUp = false
    private var lastThumb: [UInt8]?
    private var lastImage: CGImage?
    private var pendingForced = false
    private var lastPreviewMs = 0.0
    private var bundleByPid: [pid_t: String?] = [:]

    /// How often the recorder looks: whether it may capture, or a preview frame to keep.
    static let sampleInterval: TimeInterval = 0.5
    /// The least time between the app's last capture and one of the recorder's own.
    static let minGapMs = 4000.0
    /// Recorded width per point of the agent display: sharper than the
    /// display's points, smaller than its Retina pixels.
    static let pixelsPerPoint: CGFloat = 1.5

    init(sessionID: String, label: String, display: AgentDisplay) {
        self.sessionID = sessionID
        self.label = label
        self.display = display
    }

    static func runID(session: String, date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        let safe = session.replacingOccurrences(of: "/", with: "-").prefix(17)
        return "\(f.string(from: date))-\(safe)"
    }

    /// The display just came up. Any thread.
    func start() {
        queue.async {
            self.displayUp = true
            self.begin()
        }
    }

    /// The display is about to go away. Any thread.
    func stop() {
        queue.async {
            self.displayUp = false
            self.finish()
        }
    }

    /// Record into `store` from now on, or stop recording (nil). A run under
    /// way ends; with a new store and the display up, a new one starts there.
    func setStore(_ store: Recordings?) {
        queue.async {
            guard store !== self.store else { return }
            self.finish()
            self.store = store
            if self.displayUp { self.begin() }
        }
    }

    private func begin() {
        guard writer == nil, let store else { return }
        let size = display.bounds.size == .zero
            ? CGSize(width: display.width, height: display.height) : display.bounds.size
        guard let writer = RunWriter(store: store, id: Self.runID(session: sessionID, date: Date()), session: sessionID, label: label,
                                     start: wallMs(), size: size, compactQueue: compactQueue) else { return }
        self.writer = writer
        lastThumb = nil
        lastImage = nil
        pendingForced = true
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.2, repeating: Self.sampleInterval, leeway: .milliseconds(50))
        t.setEventHandler { self.tick() }
        t.resume()
        timer = t
    }

    private func finish() {
        guard let writer else { return }
        timer?.cancel()
        timer = nil
        pendingForced = true
        tick()
        self.writer = nil
        lastImage = nil
        writer.finish()
    }

    /// A line of the session's activity.
    func note(_ text: String, error: Bool) {
        let t = wallMs()
        queue.async { self.writer?.note(text, error: error, t: t) }
    }

    /// Where an action is about to land.
    func pointer(_ p: AgentPointer) {
        let t = wallMs()
        queue.async {
            guard let writer = self.writer else { return }
            let b = self.display.bounds
            var point = p.point
            if case .drag(let to) = p.kind { point = to }
            var click = false
            if case .click = p.kind { click = true }
            writer.pointer(CGPoint(x: point.x - b.minX, y: point.y - b.minY), click: click, t: t)
        }
    }

    /// A call just finished: take a frame soon, even for a small change.
    func captureSoon() {
        queue.asyncAfter(deadline: .now() + 0.15) {
            self.pendingForced = true
            self.tick()
        }
    }

    /// The agent took a screenshot of its window (`image`, as captured):
    /// drawn over the last frame where the window is, that's a new frame
    /// with no capture of our own.
    func windowShot(_ id: CGWindowID, _ image: CGImage) {
        queue.async {
            guard self.writer != nil, self.display.isRunning else { return }
            guard let base = self.lastImage, let bounds = WindowList.info(id)?.bounds else {
                self.pendingForced = true
                return
            }
            let b = self.display.bounds
            let s = CGFloat(base.width) / b.width
            guard let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
            let r = Capture.coveredRect(image, bounds: bounds, display: b)
            let h = r.height * s
            ctx.draw(image, in: CGRect(x: (r.minX - b.minX) * s, y: CGFloat(base.height) - (r.minY - b.minY) * s - h, width: r.width * s, height: h))
            guard let frame = ctx.makeImage() else { return }
            self.record(frame, force: true)
        }
    }

    /// A frame of the live preview: the whole display at its pixel size.
    func previewFrame(_ full: CGImage) {
        queue.async {
            guard self.writer != nil, nowMs() - self.lastPreviewMs >= Self.sampleInterval * 1000 else { return }
            self.lastPreviewMs = nowMs()
            let b = self.display.bounds
            guard let image = Self.scaled(full, width: Int((b.width * Self.pixelsPerPoint).rounded()),
                                          height: Int((b.height * Self.pixelsPerPoint).rounded())) else { return }
            self.record(image, force: self.pendingForced)
            self.pendingForced = false
        }
    }

    /// Captures only once nothing in the app has captured for `minGapMs`,
    /// so the recorder never brings on the screen-sharing indicator. A frame
    /// wanted after a call waits for that too.
    private func tick() {
        guard writer != nil, nowMs() - Capture.lastCaptureMs >= Self.minGapMs else { return }
        capture(force: pendingForced)
        pendingForced = false
    }

    private func capture(force: Bool) {
        guard writer != nil, display.isRunning else { return }
        let b = display.bounds
        let w = Int((b.width * Self.pixelsPerPoint).rounded())
        // Window by window through SkyLight, wallpaper and menu bar included.
        guard let image = Capture.composite(display: display, width: w, wholeDisplay: true) else { return }
        record(image, force: force)
    }

    /// Keeps `image` if it differs from the last frame kept.
    private func record(_ image: CGImage, force: Bool) {
        guard let writer else { return }
        let thumb = Self.thumbnail(image)
        if let last = lastThumb, let thumb, !Self.differs(last, thumb, force: force) { return }
        lastThumb = thumb
        lastImage = image
        let (app, bundle) = frontApp(in: display.bounds)
        writer.add(image, t: wallMs(), app: app, bundleID: bundle)
    }

    static func scaled(_ image: CGImage, width w: Int, height h: Int) -> CGImage? {
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// The frontmost app window on the agent display.
    private func frontApp(in b: CGRect) -> (String, String?) {
        let me = getpid()
        guard let w = WindowList.all(onScreenOnly: true).first(where: {
            $0.layer == 0 && $0.pid != me && $0.bounds.width > 40 && $0.bounds.height > 40
                && b.contains(CGPoint(x: $0.bounds.midX, y: $0.bounds.midY))
        }) else { return ("", nil) }
        if bundleByPid[w.pid] == nil {
            bundleByPid[w.pid] = .some(NSRunningApplication(processIdentifier: w.pid)?.bundleIdentifier)
        }
        return (w.owner, bundleByPid[w.pid] ?? nil)
    }

    static let thumbW = 256, thumbH = 160

    /// A small gray copy, for telling whether anything changed.
    static func thumbnail(_ image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: thumbW * thumbH)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: thumbW, height: thumbH, bitsPerComponent: 8, bytesPerRow: thumbW,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: thumbW, height: thumbH))
            return true
        }
        return ok ? pixels : nil
    }

    /// A blinking text caret moves one or two thumbnail pixels a little;
    /// anything the agent does moves more. Right after a call, any change counts.
    static func differs(_ a: [UInt8], _ b: [UInt8], force: Bool) -> Bool {
        guard a.count == b.count else { return true }
        var changed = 0
        for i in 0..<a.count where abs(Int(a[i]) - Int(b[i])) > (force ? 3 : 18) {
            changed += 1
            if changed >= (force ? 1 : 6) { return true }
        }
        return false
    }
}

/// Test support: records made-up frames through the real pipeline, with no
/// display involved. `frames` gives each frame's picture, time, app and bundle.
public enum RecordingTest {
    public static func record(into store: Recordings, session: String, label: String, size: CGSize,
                              frames: [(image: CGImage, t: Double, app: String, bundleID: String?)],
                              events: [(t: Double, text: String?, point: CGPoint?, click: Bool)]) {
        let q = DispatchQueue(label: "bcu.recorder.test")
        guard let first = frames.first,
              let w = RunWriter(store: store, id: SessionRecorder.runID(session: session, date: Date(timeIntervalSince1970: first.t / 1000)),
                                session: session, label: label, start: first.t - 500, size: size, compactQueue: q) else { return }
        var e = 0
        for f in frames {
            while e < events.count && events[e].t <= f.t {
                let ev = events[e]
                if let text = ev.text { w.note(text, error: false, t: ev.t) }
                if let p = ev.point { w.pointer(p, click: ev.click, t: ev.t) }
                e += 1
            }
            w.add(f.image, t: f.t, app: f.app, bundleID: f.bundleID)
        }
        let done = DispatchSemaphore(value: 0)
        w.finish { done.signal() }
        done.wait()
    }

    /// A size limit in bytes for a test, applied now; blocks until done. nil goes back to `limitMB`.
    public static func applyLimit(_ store: Recordings, bytes: Int64?) {
        store.limitBytesOverride = bytes
        store.waitForLimit()
        store.enforceLimit()
        store.waitForLimit()
    }
}
