import AppKit
import CPrivate

/// Experiment: film the user's window while the agent moves key focus around,
/// and report any frame that differs from the one before the action.
enum FlickerProbe {
    struct Frame { let t: Double; let diff: Int }

    nonisolated(unsafe) static var w = 376, h = 208

    static func small(_ img: CGImage) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? buf : nil
    }

    static func diff(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var n = 0
        var i = 0
        while i < a.count {
            if abs(Int(a[i]) - Int(b[i])) > 10 || abs(Int(a[i+1]) - Int(b[i+1])) > 10 || abs(Int(a[i+2]) - Int(b[i+2])) > 10 { n += 1 }
            i += 4
        }
        return n
    }

    /// Runs `action` while capturing `userWindow` as fast as possible.
    static func run(userWindow: CGWindowID, rect: CGRect? = nil, options: UInt32 = 0, saveDir: String? = nil, durationMs: Double = 500, _ action: () -> String) -> String {
        let grab: () -> CGImage? = {
            if let rect { return BCUCaptureWindowRect(userWindow, rect, options) }
            return BCUCaptureWindow(userWindow)
        }
        guard let first = grab() else { return "can't capture window \(userWindow)" }
        if rect != nil { w = min(first.width, 800); h = min(first.height, 200) } else { w = 376; h = 208 }
        guard let base = small(first) else { return "can't read capture" }
        if let dir = saveDir, let data = Capture.png(first, maxSide: 4000) { try? data.write(to: URL(fileURLWithPath: dir + "/base.png")) }
        nonisolated(unsafe) var worst: (Int, CGImage)? = nil
        let info = "capture \(first.width)x\(first.height) -> \(w)x\(h)"
        nonisolated(unsafe) var frames: [Frame] = []
        let lock = NSLock()
        nonisolated(unsafe) var stop = false
        let t0 = nowMs()
        let thread = Thread {
            var prev = base
            while true {
                lock.lock(); let s = stop; lock.unlock()
                if s { break }
                guard let img = grab(), let px = small(img) else { continue }
                let t = nowMs() - t0
                let d = diff(base, px)
                let dp = diff(prev, px)
                prev = px
                if saveDir != nil, d > (worst?.0 ?? 0) { worst = (d, img) }
                lock.lock(); frames.append(Frame(t: t, diff: d * 100000 + dp)); lock.unlock()
            }
        }
        thread.start()
        sleepMs(80)
        let a0 = nowMs() - t0
        let note = action()
        let a1 = nowMs() - t0
        sleepMs(durationMs)
        lock.lock(); stop = true; lock.unlock()
        sleepMs(30)
        lock.lock(); let fs = frames; lock.unlock()
        if let dir = saveDir, let wv = worst, let data = Capture.png(wv.1, maxSide: 4000) { try? data.write(to: URL(fileURLWithPath: dir + "/worst.png")) }
        let changed = fs.filter { $0.diff % 100000 > 0 || $0.diff / 100000 > 0 }
        var out = "\(info); \(fs.count) frames over \(Int(fs.last?.t ?? 0)) ms (about \(fs.count > 1 ? Int((fs.last!.t - fs.first!.t) / Double(fs.count - 1)) : 0) ms apart); action ran \(Int(a0))–\(Int(a1)) ms: \(note)\n"
        if changed.isEmpty {
            out += "no frame differed from the starting frame"
        } else {
            out += "frames that differ (t: vs-start / vs-previous pixels of \(w * h)):\n"
            out += changed.prefix(40).map { "  \(Int($0.t)): \($0.diff / 100000) / \($0.diff % 100000)" }.joined(separator: "\n")
        }
        return out
    }
}
