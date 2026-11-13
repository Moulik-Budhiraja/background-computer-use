// BCU Lab: watches, from outside Background Computer Use, what a user would
// see and feel while agents work, and plays a simulated user.
//
//   lab snapshot
//   lab watch --out REPORT.json --stop STOPFILE [--film name:x,y,w,h]... [--ax PID]... [--shots DIR]
//   lab type --pid PID --text TEXT [--interval MS] [--hold MS] [--jitter MS] [--burst KEYS --pause MS [--spread S] [--seed N]] [--out POSTS.jsonl] [--stop STOPFILE]
//   lab mouse --to x,y [--from x,y] [--ms N]
//   lab cmdtab
//   lab prim ...            (single private-API calls, for experiments; see `prim` below)
//   lab permit show | clear | exclude --pid P   (which apps may bring themselves to the front)
//
// `watch` samples, until STOPFILE exists:
// - the front app (WindowServer's own view) about every 0.5 ms
// - the cursor every 2 ms
// - the window stack on the user's displays every 8 ms: which window is on
//   top, the order of the first few, and windows that appear
// - each --ax PID's key window and AppKit "active" flag every 20 ms
// - each --film rect of the screen (global points) every ~8 ms, compared with
//   its first frame: a run of frames that differ is something the user saw
//
// Times are milliseconds of system uptime, the same clock as event timestamps.
import AppKit
import ApplicationServices

func uptimeMs() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000 }
func sleepMs(_ ms: Double) { if ms > 0 { usleep(useconds_t(ms * 1000)) } }

// MARK: Private symbols

let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
_ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
func sym<T>(_ name: String, _ type: T.Type) -> T? { dlsym(rtldDefault, name).map { unsafeBitCast($0, to: T.self) } }

typealias GetFrontFn = @convention(c) (UnsafeMutablePointer<UInt8>) -> Int32
typealias PSNToPidFn = @convention(c) (UnsafePointer<UInt8>, UnsafeMutablePointer<pid_t>) -> Int32
typealias PidToPSNFn = @convention(c) (pid_t, UnsafeMutablePointer<UInt8>) -> Int32
typealias SetFrontFn = @convention(c) (UnsafePointer<UInt8>, UInt32, UInt32) -> Int32
typealias PostRecordFn = @convention(c) (UnsafePointer<UInt8>, UnsafePointer<UInt8>) -> Int32
typealias CaptureRectFn = @convention(c) (CGDirectDisplayID, CGRect) -> Unmanaged<CGImage>?
typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError
typealias PostToPidFn = @convention(c) (pid_t, CGEvent) -> Void
typealias SetIntFieldFn = @convention(c) (CGEvent, UInt32, Int64) -> Void

let getFront = sym("_SLPSGetFrontProcess", GetFrontFn.self)
let psnToPid = sym("GetProcessPID", PSNToPidFn.self)
let pidToPSN = sym("GetProcessForPID", PidToPSNFn.self)
let setFront = sym("SLPSSetFrontProcessWithOptions", SetFrontFn.self)
let postRecord = sym("SLPSPostEventRecordTo", PostRecordFn.self)
let captureRect = sym("CGDisplayCreateImageForRect", CaptureRectFn.self)
let axGetWindow = sym("_AXUIElementGetWindow", AXGetWindowFn.self)
let postToPid = sym("SLEventPostToPid", PostToPidFn.self)
let setIntField = sym("SLEventSetIntegerValueField", SetIntFieldFn.self)

func frontPID() -> pid_t {
    guard let getFront, let psnToPid else { return 0 }
    var psn = [UInt8](repeating: 0, count: 8)
    guard getFront(&psn) == 0 else { return 0 }
    var pid: pid_t = 0
    return psnToPid(psn, &pid) == 0 ? pid : 0
}

func appName(_ pid: pid_t) -> String {
    pid == 0 ? "none" : (NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)")
}

// MARK: Screen state

struct Display { let id: CGDirectDisplayID; let bounds: CGRect; let agent: Bool }

func displays() -> [Display] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var n: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &n)
    // Background Computer Use's virtual displays report vendor 0xBC0F.
    return ids.prefix(Int(n)).map { Display(id: $0, bounds: CGDisplayBounds($0), agent: CGDisplayVendorNumber($0) == 0xBC0F) }
}

struct Win { let id: Int; let pid: pid_t; let owner: String; let layer: Int; let bounds: CGRect; let alpha: Double; let title: String }

func windows(onScreen: Bool = true) -> [Win] {
    let opts: CGWindowListOption = onScreen ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
    return list.compactMap { d in
        guard let id = d[kCGWindowNumber as String] as? Int, let pid = d[kCGWindowOwnerPID as String] as? Int,
              let b = d[kCGWindowBounds as String] as? [String: Any], let r = CGRect(dictionaryRepresentation: b as CFDictionary) else { return nil }
        return Win(id: id, pid: pid_t(pid), owner: d[kCGWindowOwnerName as String] as? String ?? "?",
                   layer: d[kCGWindowLayer as String] as? Int ?? 0, bounds: r, alpha: d[kCGWindowAlpha as String] as? Double ?? 1,
                   title: d[kCGWindowName as String] as? String ?? "")
    }
}

/// Ordinary windows the user can see: on one of their displays, front first.
func userStack(_ ws: [Win], _ ds: [Display]) -> [Win] {
    let user = ds.filter { !$0.agent }.map(\.bounds)
    return ws.filter { w in w.layer == 0 && w.alpha > 0 && w.bounds.width > 40 && w.bounds.height > 40 && user.contains { $0.intersects(w.bounds) } }
}

func rectDict(_ r: CGRect) -> [String: Int] { ["x": Int(r.minX), "y": Int(r.minY), "w": Int(r.width), "h": Int(r.height)] }

func jsonString(_ o: Any, pretty: Bool = false) -> String {
    let d = (try? JSONSerialization.data(withJSONObject: o, options: pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys])) ?? Data()
    return String(data: d, encoding: .utf8) ?? "{}"
}

func axWindowID(_ el: AXUIElement) -> Int {
    var id: UInt32 = 0
    guard let axGetWindow, axGetWindow(el, &id) == .success else { return 0 }
    return Int(id)
}

func axAttr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}

/// The app's key window as accessibility reports it (0: none or no answer)
/// and AppKit's own "active" flag (-1: no answer).
func axState(_ pid: pid_t) -> (key: Int, main: Int, active: Int) {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.25)
    var key = 0, main = 0
    if let w = axAttr(app, "AXFocusedWindow"), CFGetTypeID(w) == AXUIElementGetTypeID() { key = axWindowID(unsafeBitCast(w, to: AXUIElement.self)) }
    if let w = axAttr(app, "AXMainWindow"), CFGetTypeID(w) == AXUIElementGetTypeID() { main = axWindowID(unsafeBitCast(w, to: AXUIElement.self)) }
    let active = (axAttr(app, "AXFrontmost") as? NSNumber).map { $0.boolValue ? 1 : 0 } ?? -1
    return (key, main, active)
}

// MARK: Arguments

struct Options {
    var single: [String: String] = [:]
    var multi: [String: [String]] = [:]
    var flags: Set<String> = []
    init(_ args: [String]) {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                    single[key] = args[i + 1]
                    multi[key, default: []].append(args[i + 1])
                    i += 2
                    continue
                }
                flags.insert(key)
            }
            i += 1
        }
    }
    func double(_ k: String, _ d: Double) -> Double { single[k].flatMap(Double.init) ?? d }
    func int(_ k: String, _ d: Int) -> Int { single[k].flatMap { Int($0) } ?? d }
    func point(_ k: String) -> CGPoint? {
        guard let p = single[k]?.split(separator: ",").compactMap({ Double($0) }), p.count == 2 else { return nil }
        return CGPoint(x: p[0], y: p[1])
    }
}

// MARK: snapshot

func snapshot() -> [String: Any] {
    let ds = displays()
    let ws = windows()
    let f = frontPID()
    let p = CGEvent(source: nil)?.location ?? .zero
    return [
        "t": uptimeMs(),
        "front": ["pid": Int(f), "name": appName(f)],
        "cursor": ["x": Int(p.x), "y": Int(p.y)],
        "displays": ds.map { ["id": Int($0.id), "agent": $0.agent, "bounds": rectDict($0.bounds)] as [String: Any] },
        "user_stack": userStack(ws, ds).prefix(12).map { ["id": $0.id, "pid": Int($0.pid), "owner": $0.owner, "title": $0.title, "bounds": rectDict($0.bounds)] as [String: Any] },
        "agent_windows": ws.filter { w in w.layer == 0 && ds.contains { $0.agent && $0.bounds.contains(CGPoint(x: w.bounds.midX, y: w.bounds.midY)) } }
            .map { ["id": $0.id, "pid": Int($0.pid), "owner": $0.owner, "title": $0.title, "bounds": rectDict($0.bounds)] as [String: Any] },
    ]
}

// MARK: watch

final class Film {
    let name: String
    let rect: CGRect
    let display: CGDirectDisplayID
    let local: CGRect
    var base: [UInt8] = []
    var width = 0, height = 0
    var frames = 0
    /// Runs of frames that differ from the first frame.
    var runs: [[String: Any]] = []
    var open: (t: Double, maxPx: Int, last: Double, frames: Int)?
    var worst: (px: Int, image: CGImage)?
    var baseImage: CGImage?
    var maxGap = 0.0
    var lastT = 0.0
    /// With --trace: every frame's time and how many pixels differ from the first.
    static var tracing = false
    var trace: [[Double]] = []

    init?(spec: String) {
        let parts = spec.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let n = parts[1].split(separator: ",").compactMap { Double($0) }
        guard n.count == 4 else { return nil }
        name = String(parts[0])
        rect = CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(CGPoint(x: rect.midX, y: rect.midY), 1, &id, &count)
        guard count == 1 else { return nil }
        display = id
        let origin = CGDisplayBounds(id).origin
        local = rect.offsetBy(dx: -origin.x, dy: -origin.y)
    }

    func pixels(_ img: CGImage) -> [UInt8] {
        width = img.width; height = img.height
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.interpolationQuality = .none
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return buf
    }

    /// Pixels more than a little different (a dimmed menu bar, a lighter shadow).
    static func diff(_ a: [UInt8], _ b: [UInt8]) -> Int {
        guard a.count == b.count else { return a.count / 4 }
        var n = 0, i = 0
        while i < a.count {
            if abs(Int(a[i]) - Int(b[i])) > 5 || abs(Int(a[i + 1]) - Int(b[i + 1])) > 5 || abs(Int(a[i + 2]) - Int(b[i + 2])) > 5 { n += 1 }
            i += 4
        }
        return n
    }

    func sample(t0: Double) {
        guard let captureRect, let img = captureRect(display, local)?.takeRetainedValue() else { return }
        let t = uptimeMs() - t0
        let px = pixels(img)
        frames += 1
        if lastT > 0 { maxGap = max(maxGap, t - lastT) }
        lastT = t
        if base.isEmpty { base = px; baseImage = img; return }
        let d = Film.diff(base, px)
        if Film.tracing { trace.append([t, Double(d)]) }
        if d > 0 {
            if var o = open { o.maxPx = max(o.maxPx, d); o.last = t; o.frames += 1; open = o } else { open = (t, d, t, 1) }
            if d > (worst?.px ?? 0) { worst = (d, img) }
        } else if let o = open {
            runs.append(["t": o.t, "ms": t - o.t, "max_px": o.maxPx, "frames": o.frames])
            open = nil
        }
    }

    func finish(t: Double) {
        if let o = open { runs.append(["t": o.t, "ms": t - o.t, "max_px": o.maxPx, "frames": o.frames, "still": true]); open = nil }
    }
}

func savePNG(_ image: CGImage, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

func watch(_ o: Options) {
    guard let out = o.single["out"], let stopFile = o.single["stop"] else { fail("watch needs --out and --stop") }
    let films = (o.multi["film"] ?? []).compactMap(Film.init(spec:))
    Film.tracing = o.flags.contains("trace")
    let axPids = (o.multi["ax"] ?? []).compactMap { Int32($0) }
    let t0 = uptimeMs()
    let epoch = Date().timeIntervalSince1970 * 1000
    let lock = NSLock()
    var stop = false
    func stopped() -> Bool { lock.lock(); defer { lock.unlock() }; return stop }
    let group = DispatchGroup()
    func thread(_ name: String, _ body: @escaping () -> Void) {
        group.enter()
        let t = Thread { body(); group.leave() }
        t.name = name
        t.qualityOfService = .userInteractive
        t.start()
    }

    // Front app.
    let startFront = frontPID()
    var frontLog: [[String: Any]] = [["t": 0.0, "pid": Int(startFront), "name": appName(startFront)]]
    var frontSamples = 0, frontMaxGap = 0.0
    thread("front") {
        var last = startFront
        var lastT = uptimeMs()
        while !stopped() {
            let f = frontPID()
            let now = uptimeMs()
            frontMaxGap = max(frontMaxGap, now - lastT)
            lastT = now
            frontSamples += 1
            if f != last {
                lock.lock(); frontLog.append(["t": now - t0, "pid": Int(f), "name": appName(f)]); lock.unlock()
                last = f
            }
            usleep(400)
        }
    }

    // Cursor: every position change (the simulated user's own moves are known from its log).
    var cursorLog: [[String: Any]] = []
    var cursorOnAgentMs = 0.0
    thread("cursor") {
        var last = CGEvent(source: nil)?.location ?? .zero
        var ds = displays(), dsT = uptimeMs()
        var lastT = uptimeMs()
        while !stopped() {
            let now = uptimeMs()
            if now - dsT > 250 { ds = displays(); dsT = now }
            if let p = CGEvent(source: nil)?.location {
                if ds.contains(where: { $0.agent && $0.bounds.contains(p) }) { cursorOnAgentMs += now - lastT }
                if p != last {
                    lock.lock()
                    if cursorLog.count < 5000 { cursorLog.append(["t": now - t0, "x": Double(p.x), "y": Double(p.y), "jump": Double(hypot(p.x - last.x, p.y - last.y))]) }
                    lock.unlock()
                    last = p
                }
            }
            lastT = now
            usleep(2000)
        }
    }

    // Window stack on the user's displays.
    var stackLog: [[String: Any]] = []
    var appeared: [Int: [String: Any]] = [:]
    var displayLog: [[String: Any]] = []
    thread("windows") {
        var ds = displays()
        displayLog.append(["t": 0.0, "displays": ds.map { ["id": Int($0.id), "agent": $0.agent, "bounds": rectDict($0.bounds)] as [String: Any] }])
        var known = Set(userStack(windows(), ds).map(\.id))
        var lastOrder: [Int] = []
        var lastDs = ds.map { "\($0.id):\($0.bounds)" }
        while !stopped() {
            let now = uptimeMs()
            ds = displays()
            let dsKey = ds.map { "\($0.id):\($0.bounds)" }
            if dsKey != lastDs {
                lastDs = dsKey
                lock.lock(); displayLog.append(["t": now - t0, "displays": ds.map { ["id": Int($0.id), "agent": $0.agent, "bounds": rectDict($0.bounds)] as [String: Any] }]); lock.unlock()
            }
            let stack = userStack(windows(), ds)
            let order = stack.prefix(6).map(\.id)
            if order != lastOrder {
                lastOrder = order
                lock.lock()
                stackLog.append(["t": now - t0, "order": stack.prefix(6).map { ["id": $0.id, "owner": $0.owner, "title": String($0.title.prefix(40))] as [String: Any] }])
                lock.unlock()
            }
            for w in stack where !known.contains(w.id) {
                lock.lock()
                if var a = appeared[w.id] {
                    a["last"] = now - t0
                    appeared[w.id] = a
                } else {
                    appeared[w.id] = ["id": w.id, "owner": w.owner, "title": String(w.title.prefix(60)), "first": now - t0, "last": now - t0, "bounds": rectDict(w.bounds)]
                }
                lock.unlock()
            }
            usleep(8000)
        }
    }

    // Key window and "active" flag of chosen apps.
    var axLog: [[String: Any]] = []
    if !axPids.isEmpty {
        thread("ax") {
            var last: [pid_t: String] = [:]
            while !stopped() {
                for pid in axPids {
                    let s = axState(pid)
                    let key = "\(s.key)/\(s.main)/\(s.active)"
                    if last[pid] != key {
                        last[pid] = key
                        lock.lock(); axLog.append(["t": uptimeMs() - t0, "pid": Int(pid), "key": s.key, "main": s.main, "active": s.active]); lock.unlock()
                    }
                }
                usleep(20000)
            }
        }
    }

    for film in films {
        thread("film-\(film.name)") {
            while !stopped() {
                film.sample(t0: t0)
                usleep(6000)
            }
            film.finish(t: uptimeMs() - t0)
        }
    }

    while !FileManager.default.fileExists(atPath: stopFile) { usleep(20000) }
    lock.lock(); stop = true; lock.unlock()
    group.wait()
    let end = uptimeMs()
    if let dir = o.single["shots"] {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for f in films {
            if let b = f.baseImage { savePNG(b, "\(dir)/\(f.name)-base.png") }
            if let w = f.worst { savePNG(w.image, "\(dir)/\(f.name)-worst.png") }
        }
    }
    let report: [String: Any] = [
        "t0_uptime_ms": t0, "t0_epoch_ms": epoch, "duration_ms": end - t0,
        "front": frontLog, "front_samples": frontSamples, "front_max_gap_ms": frontMaxGap,
        "cursor": cursorLog, "cursor_on_agent_ms": cursorOnAgentMs,
        "stack": stackLog, "appeared": Array(appeared.values), "displays": displayLog,
        "ax": axLog,
        "film": films.map { ["name": $0.name, "rect": rectDict($0.rect), "frames": $0.frames, "max_gap_ms": $0.maxGap, "pixels": $0.width * $0.height, "runs": $0.runs, "trace": $0.trace] as [String: Any] },
    ]
    try? jsonString(report).write(toFile: out, atomically: true, encoding: .utf8)
}

// MARK: Simulated user

let hidSource = CGEventSource(stateID: .hidSystemState)

let keyCodes: [Character: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
    "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
    "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
    "n": 45, "m": 46, ".": 47, "`": 50, " ": 49, "\n": 36,
]

func postKey(_ code: CGKeyCode, down: Bool, char: Character? = nil, flags: CGEventFlags = []) {
    guard let e = CGEvent(keyboardEventSource: hidSource, virtualKey: code, keyDown: down) else { return }
    if let char {
        let u = Array(String(char).utf16)
        e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
    }
    e.flags = flags
    e.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    e.post(tap: .cghidEventTap)
}

/// SplitMix64, so that a typist given `--seed` types with the same rhythm
/// every run and two builds can be measured against the same typing.
struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Type like a person: one physical key per character, held a moment. Only
/// ever while `pid` is the front app, so nothing lands anywhere else. With
/// `--burst`, in runs of about that many keys with a pause after each, as
/// someone writing does; without, nonstop. The pauses are 0.6 to 1.6 times
/// `--pause` ms, or with `--spread` log-normal around it (`--pause` the
/// median, `--spread` the sigma of the logarithm: 0.9 gives mostly short
/// hesitations and the odd long stop to think, 0.3 s at least, 15 s at most).
func typeText(_ o: Options) {
    guard let pid = o.single["pid"].flatMap({ Int32($0) }), let text = o.single["text"] else { fail("type needs --pid and --text") }
    let interval = o.double("interval", 110), hold = o.double("hold", 45), jitter = o.double("jitter", 0)
    let burst = o.int("burst", 0), pause = o.double("pause", 1800), spread = o.double("spread", 0)
    var rng = Seeded(state: UInt64(o.int("seed", 0)) == 0 ? UInt64.random(in: 1...UInt64.max) : UInt64(o.int("seed", 0)))
    func nextPause() -> Double {
        guard spread > 0 else { return pause * Double.random(in: 0.6...1.6, using: &rng) }
        // Box-Muller.
        let z = (-2 * log(Double.random(in: Double.leastNonzeroMagnitude...1, using: &rng))).squareRoot()
            * cos(2 * Double.pi * Double.random(in: 0...1, using: &rng))
        return min(15_000, max(300, pause * exp(spread * z)))
    }
    func nextBurst() -> Int { Int.random(in: max(1, burst / 2)...max(1, burst * 3 / 2), using: &rng) }
    var leftInBurst = burst > 0 ? nextBurst() : Int.max
    let stopFile = o.single["stop"]
    let repeats = o.int("repeat", 1)
    var lines: [String] = []
    var i = 0
    var note = "done"
    outer: for _ in 0..<repeats {
        for ch in text {
            if let stopFile, FileManager.default.fileExists(atPath: stopFile) { note = "stopped"; break outer }
            // Another app in front: wait up to 3 s for ours to come back, then give up.
            var waited = 0.0
            while frontPID() != pid && waited < 3000 { sleepMs(5); waited += 5 }
            if frontPID() != pid { note = "stopped: \(appName(frontPID())) stayed in front"; break outer }
            let lower = Character(String(ch).lowercased())
            guard let code = keyCodes[lower] else { continue }
            let flags: CGEventFlags = ch.isUppercase ? .maskShift : []
            let t = uptimeMs()
            postKey(code, down: true, char: ch, flags: flags)
            sleepMs(hold)
            postKey(code, down: false, char: ch, flags: flags)
            lines.append(jsonString(["i": i, "ch": String(ch), "t": t, "front_wait": waited]))
            i += 1
            sleepMs(max(0, interval - hold) + (jitter > 0 ? Double.random(in: 0...jitter) : 0))
            leftInBurst -= 1
            if leftInBurst <= 0 {
                leftInBurst = nextBurst()
                let until = uptimeMs() + nextPause()
                lines.append(jsonString(["pause_from": uptimeMs(), "pause_to": until]))
                while uptimeMs() < until {
                    if let stopFile, FileManager.default.fileExists(atPath: stopFile) { note = "stopped"; break outer }
                    sleepMs(10)
                }
            }
        }
    }
    lines.append(jsonString(["end": note, "typed": i, "t": uptimeMs()]))
    if let out = o.single["out"] { try? (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8) }
    print(note, i)
}

func mouse(_ o: Options) {
    guard let to = o.point("to") else { fail("mouse needs --to x,y") }
    let from = o.point("from") ?? (CGEvent(source: nil)?.location ?? to)
    let ms = o.double("ms", 200)
    let steps = max(1, Int(ms / 8))
    for i in 1...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        if let e = CGEvent(mouseEventSource: hidSource, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left) {
            e.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            e.post(tap: .cghidEventTap)
        }
        sleepMs(8)
    }
    if o.flags.contains("click") {
        for (type, wait) in [(CGEventType.leftMouseDown, 60.0), (.leftMouseUp, 0)] {
            if let e = CGEvent(mouseEventSource: hidSource, mouseType: type, mouseCursorPosition: to, mouseButton: .left) {
                e.setIntegerValueField(.mouseEventClickState, value: 1)
                e.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                e.post(tap: .cghidEventTap)
            }
            sleepMs(wait)
        }
    }
    let p = CGEvent(source: nil)?.location ?? .zero
    print("cursor at \(Int(p.x)),\(Int(p.y))")
}

func cmdTab() {
    func post(_ code: CGKeyCode, _ down: Bool, _ flags: CGEventFlags, _ type: CGEventType? = nil) {
        guard let e = CGEvent(keyboardEventSource: hidSource, virtualKey: code, keyDown: down) else { return }
        if let type { e.type = type }
        e.flags = flags
        e.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        e.post(tap: .cghidEventTap)
    }
    let before = frontPID()
    post(55, true, .maskCommand, .flagsChanged); sleepMs(40)
    post(48, true, .maskCommand); sleepMs(50)
    post(48, false, .maskCommand); sleepMs(60)
    post(55, false, [], .flagsChanged)
    sleepMs(500)
    print("front before: \(appName(before)) (\(before)); after: \(appName(frontPID())) (\(frontPID()))")
}

// MARK: Private-API primitives, one at a time

func psn(_ pid: pid_t) -> [UInt8]? {
    guard let pidToPSN else { return nil }
    var p = [UInt8](repeating: 0, count: 8)
    return pidToPSN(pid, &p) == 0 ? p : nil
}

func prim(_ args: [String]) {
    let o = Options(Array(args.dropFirst()))
    let pid = pid_t(o.int("pid", 0))
    let wid = UInt32(o.int("wid", 0))
    switch args.first ?? "" {
    case "set-front":
        // SLPSSetFrontProcessWithOptions: 0x100 all windows, 0x200 user generated, 0x400 no windows.
        guard let setFront, let p = psn(pid) else { fail("no psn") }
        print("status", setFront(p, wid, UInt32(o.int("options", 0x200))))
    case "focus-record":
        // The 0xF8-byte "window gained (1) / lost (2) key focus" record.
        guard let postRecord, let p = psn(pid) else { fail("no psn") }
        var r = [UInt8](repeating: 0, count: 0xF8)
        r[0x04] = 0xF8; r[0x08] = 0x0D
        withUnsafeBytes(of: wid) { for (i, b) in $0.enumerated() { r[0x3C + i] = b } }
        r[0x8A] = o.flags.contains("lose") ? 0x02 : 0x01
        print("status", postRecord(p, r))
    case "make-key":
        // The synthetic press and release on the window's title bar that makes it key.
        guard let postRecord, let p = psn(pid) else { fail("no psn") }
        for kind: UInt8 in [0x01, 0x02] {
            var r = [UInt8](repeating: 0, count: 0xF8)
            r[0x04] = 0xF8; r[0x08] = kind; r[0x3A] = 0x10
            withUnsafeBytes(of: wid) { for (i, b) in $0.enumerated() { r[0x3C + i] = b } }
            for i in 0x20..<0x30 { r[i] = 0xFF }
            print("status", postRecord(p, r))
        }
    case "ax-state":
        let s = axState(pid)
        print(jsonString(["key": s.key, "main": s.main, "active": s.active, "front": Int(frontPID())]))
    case "ax-menu":
        // Press a menu item by its path, e.g. --path "File>New Window".
        guard let path = o.single["path"]?.split(separator: ">").map(String.init), !path.isEmpty else { fail("ax-menu needs --path A>B") }
        let app = AXUIElementCreateApplication(pid)
        guard let barV = axAttr(app, "AXMenuBar") else { fail("no menu bar") }
        var current = unsafeBitCast(barV, to: AXUIElement.self)
        for (i, title) in path.enumerated() {
            var kids = (axAttr(current, "AXChildren") as? [AnyObject] ?? []).map { unsafeBitCast($0, to: AXUIElement.self) }
            if i > 0, let menu = kids.first(where: { (axAttr($0, "AXRole") as? String) == "AXMenu" }) {
                kids = (axAttr(menu, "AXChildren") as? [AnyObject] ?? []).map { unsafeBitCast($0, to: AXUIElement.self) }
            }
            guard let next = kids.first(where: { (axAttr($0, "AXTitle") as? String) == title }) else { fail("no item \(title)") }
            current = next
        }
        print("press", AXUIElementPerformAction(current, "AXPress" as CFString).rawValue)
    case "ax-raise":
        let app = AXUIElementCreateApplication(pid)
        let wins = (axAttr(app, "AXWindows") as? [AnyObject] ?? []).map { unsafeBitCast($0, to: AXUIElement.self) }
        guard let w = wins.first(where: { axWindowID($0) == Int(wid) }) else { fail("no window") }
        print("raise", AXUIElementPerformAction(w, "AXRaise" as CFString).rawValue)
    case "freeze":
        // Stop the screen updating for --ms (WindowServer turns it back on by itself after about a second).
        typealias UpdateFn = @convention(c) (UInt32) -> Int32
        typealias MainCidFn = @convention(c) () -> UInt32
        guard let cidFn = sym("SLSMainConnectionID", MainCidFn.self) ?? sym("CGSMainConnectionID", MainCidFn.self),
              let off = sym("SLSDisableUpdate", UpdateFn.self), let on = sym("SLSReenableUpdate", UpdateFn.self) else { fail("no SLSDisableUpdate") }
        _ = NSApplication.shared
        let cid = cidFn()
        let t = uptimeMs()
        let a = off(cid)
        sleepMs(o.double("ms", 300))
        let b = on(cid)
        print("disable \(a) reenable \(b) held \(Int(uptimeMs() - t)) ms from uptime \(Int(t))")
    case "ax-main":
        // Make a window its app's main window through accessibility.
        let app = AXUIElementCreateApplication(pid)
        let wins = (axAttr(app, "AXWindows") as? [AnyObject] ?? []).map { unsafeBitCast($0, to: AXUIElement.self) }
        guard let w = wins.first(where: { axWindowID($0) == Int(wid) }) else { fail("no window") }
        print("main", AXUIElementSetAttributeValue(w, "AXMain" as CFString, kCFBooleanTrue).rawValue)
    case "ax-focused-window":
        let app = AXUIElementCreateApplication(pid)
        let wins = (axAttr(app, "AXWindows") as? [AnyObject] ?? []).map { unsafeBitCast($0, to: AXUIElement.self) }
        guard let w = wins.first(where: { axWindowID($0) == Int(wid) }) else { fail("no window") }
        print("focused window", AXUIElementSetAttributeValue(app, "AXFocusedWindow" as CFString, w).rawValue)
    case "at":
        // Every on-screen window that contains a point, front first, at any level.
        guard let at = o.point("at") else { fail("at needs --at x,y") }
        for w in windows() where w.bounds.contains(at) {
            print("\(w.id) \(w.owner) layer \(w.layer) alpha \(w.alpha) \(Int(w.bounds.minX)),\(Int(w.bounds.minY)) \(Int(w.bounds.width))x\(Int(w.bounds.height)) \"\(w.title.prefix(30))\"")
        }
    case "ax-frame":
        // Move and size a window: --frame x,y,w,h (global points, top-left origin).
        guard let f = o.single["frame"]?.split(separator: ",").compactMap({ Double($0) }), f.count == 4 else { fail("ax-frame needs --frame x,y,w,h") }
        let app = AXUIElementCreateApplication(pid)
        let wins = (axAttr(app, "AXWindows") as? [AnyObject] ?? []).map { unsafeBitCast($0, to: AXUIElement.self) }
        guard let w = wins.first(where: { axWindowID($0) == Int(wid) }) else { fail("no window") }
        var size = CGSize(width: f[2], height: f[3]), origin = CGPoint(x: f[0], y: f[1])
        // A window as big as the screen takes the size only once it has
        // moved, and the place only once it's smaller: a few rounds.
        var got = CGRect.zero
        for round in 1...5 {
            AXUIElementSetAttributeValue(w, "AXSize" as CFString, AXValueCreate(.cgSize, &size)!)
            AXUIElementSetAttributeValue(w, "AXPosition" as CFString, AXValueCreate(.cgPoint, &origin)!)
            sleepMs(250)
            got = windows(onScreen: false).first { $0.id == Int(wid) }?.bounds ?? .zero
            if abs(got.minX - origin.x) < 2 && abs(got.minY - origin.y) < 2 && abs(got.width - size.width) < 2 && abs(got.height - size.height) < 2 {
                print("frame set in \(round) round(s)")
                return
            }
        }
        print("frame is \(Int(got.minX)),\(Int(got.minY)) \(Int(got.width))x\(Int(got.height)) after 5 rounds")
    case "ax-close":
        let app = AXUIElementCreateApplication(pid)
        let wins = (axAttr(app, "AXWindows") as? [AnyObject] ?? []).map { unsafeBitCast($0, to: AXUIElement.self) }
        guard let w = wins.first(where: { axWindowID($0) == Int(wid) }), let b = axAttr(w, "AXCloseButton") else { fail("no window or close button") }
        print("close", AXUIElementPerformAction(unsafeBitCast(b, to: AXUIElement.self), "AXPress" as CFString).rawValue)
    case "ax-windows":
        let app = AXUIElementCreateApplication(pid)
        let wins = (axAttr(app, "AXWindows") as? [AnyObject] ?? []).map { unsafeBitCast($0, to: AXUIElement.self) }
        for w in wins { print(axWindowID(w), (axAttr(w, "AXTitle") as? String) ?? "", (axAttr(w, "AXSubrole") as? String) ?? "") }
    case "click":
        // A per-process click at a global point, stamped with the window, as BCU posts them.
        guard let postToPid, let setIntField, let at = o.point("at") else { fail("click needs --at") }
        func post(_ type: CGEventType, _ p: CGPoint, phase: Int64, state: Int64) {
            guard let e = CGEvent(mouseEventSource: hidSource, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { return }
            for (f, v) in [(0, phase), (1, state), (3, 0), (7, 3), (40, Int64(pid)), (51, Int64(wid)), (91, Int64(wid)), (92, Int64(wid)), (58, 1)] as [(UInt32, Int64)] { setIntField(e, f, v) }
            e.flags = []
            postToPid(pid, e)
        }
        post(.mouseMoved, at, phase: 2, state: 0); sleepMs(15)
        if !o.flags.contains("no-primer") {
            post(.leftMouseDown, CGPoint(x: -1, y: -1), phase: 1, state: 1); sleepMs(1)
            post(.leftMouseUp, CGPoint(x: -1, y: -1), phase: 2, state: 1); sleepMs(100)
        }
        post(.leftMouseDown, at, phase: 3, state: 1); sleepMs(1)
        post(.leftMouseUp, at, phase: 3, state: 1)
        print("posted")
    case "key":
        guard let postToPid, let setIntField else { fail("no SLEventPostToPid") }
        let code = CGKeyCode(o.int("code", 0))
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: hidSource, virtualKey: code, keyDown: down) else { continue }
            e.flags = []
            if wid != 0 { for f: UInt32 in [51, 91, 92] { setIntField(e, f, Int64(wid)) } }
            postToPid(pid, e)
            sleepMs(8)
        }
        print("posted")
    default:
        fail("prim: set-front | focus-record [--lose] | make-key | ax-state | ax-menu --path | ax-raise | ax-close | ax-windows | click --at | key --code, each with --pid and --wid")
    }
}

// MARK: Permitted front apps

// LaunchServices keeps a list of the apps allowed to bring THEMSELVES to the
// front ("LSPermittedFrontASNs"); WindowServer refuses any other app's own
// request (an empty list permits everyone). Requests on an app's behalf (the
// Dock's for cmd+Tab, this tool's set-front) aren't checked against it.
typealias LSCopyMetaFn = @convention(c) (Int32, CFString) -> Unmanaged<CFTypeRef>?
typealias LSSetMetaFn = @convention(c) (Int32, CFString, CFTypeRef) -> Int32
typealias LSCopyAppsFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
typealias LSCopyItemFn = @convention(c) (Int32, CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?

let coreServices = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY)
let lsCopyMeta = dlsym(coreServices, "_LSCopyMetaApplicationInformationItem").map { unsafeBitCast($0, to: LSCopyMetaFn.self) }
let lsSetMeta = dlsym(coreServices, "_LSSetMetaApplicationInformationItem").map { unsafeBitCast($0, to: LSSetMetaFn.self) }
let lsCopyApps = dlsym(coreServices, "_LSCopyRunningApplicationArray").map { unsafeBitCast($0, to: LSCopyAppsFn.self) }
let lsCopyItem = dlsym(coreServices, "_LSCopyApplicationInformationItem").map { unsafeBitCast($0, to: LSCopyItemFn.self) }
let lsPermittedKey: CFString? = dlsym(coreServices, "_kLSPermittedFrontASNsArrayKey").map { $0.assumingMemoryBound(to: CFString.self).pointee }
let lsSession: Int32 = -2

func lsApps() -> [(asn: CFTypeRef, pid: pid_t, name: String)] {
    guard let lsCopyApps, let lsCopyItem, let list = lsCopyApps(lsSession)?.takeRetainedValue() as? [CFTypeRef] else { return [] }
    return list.map { asn in
        let pid = (lsCopyItem(lsSession, asn, "pid" as CFString)?.takeRetainedValue() as? NSNumber)?.int32Value ?? 0
        let name = (lsCopyItem(lsSession, asn, "LSDisplayName" as CFString)?.takeRetainedValue() as? String) ?? "?"
        return (asn, pid, name)
    }
}

func permit(_ args: [String]) {
    guard let lsCopyMeta, let lsSetMeta, let key = lsPermittedKey else { fail("LaunchServices symbols missing") }
    let o = Options(Array(args.dropFirst()))
    switch args.first ?? "show" {
    case "show":
        let now = lsCopyMeta(lsSession, key)?.takeRetainedValue() as? [CFTypeRef]
        let apps = lsApps()
        guard let now, !now.isEmpty else { print("no list: every app may bring itself to the front (\(apps.count) apps running)"); return }
        let excluded = apps.filter { a in !now.contains { CFEqual($0, a.asn) } }
        print("list of \(now.count) apps; not permitted: \(excluded.map { "\($0.name) (\($0.pid))" }.joined(separator: ", "))")
    case "clear":
        print("status", lsSetMeta(lsSession, key, [] as CFArray))
    case "exclude":
        // Everyone but these pids.
        let out = Set((o.multi["pid"] ?? []).compactMap { Int32($0) })
        let apps = lsApps()
        let allowed = apps.filter { !out.contains($0.pid) }.map(\.asn)
        let t = uptimeMs()
        let status = lsSetMeta(lsSession, key, allowed as CFArray)
        print("status \(status) in \(String(format: "%.2f", uptimeMs() - t)) ms: \(allowed.count) of \(apps.count) apps permitted; excluded \(apps.filter { out.contains($0.pid) }.map { "\($0.name) (\($0.pid))" }.joined(separator: ", "))")
    default:
        fail("permit show | clear | exclude --pid P [--pid Q]")
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let argv = Array(CommandLine.arguments.dropFirst())
switch argv.first ?? "" {
case "snapshot": print(jsonString(snapshot(), pretty: true))
case "watch": watch(Options(Array(argv.dropFirst())))
case "type": typeText(Options(Array(argv.dropFirst())))
case "mouse": mouse(Options(Array(argv.dropFirst())))
case "cmdtab": cmdTab()
case "prim": prim(Array(argv.dropFirst()))
case "permit": permit(Array(argv.dropFirst()))
default: fail("usage: lab snapshot | watch | type | mouse | cmdtab | prim | permit (see the top of Lab.swift)")
}
