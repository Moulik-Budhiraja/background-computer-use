import AppKit
import SwiftUI
import BCUCore

/// `BackgroundComputerUse --history-selftest <dir>`: records made-up agent
/// frames through the real recorder into `<dir>/recordings` (no display,
/// nothing on screen), checks every frame reads back, and renders the
/// history viewer offscreen to `<dir>/history-*.png`. Exits when done.
enum HistorySelfTest {
    /// `--history-render <dir>`: renders the viewer offscreen from the real
    /// recordings, at the newest frame and at the start of each app segment.
    static func render(_ out: URL) -> Never {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let (controller, host) = offscreenViewer()
        controller.model.load()
        spin(1.5)
        snapshot(host, to: out.appendingPathComponent("history-latest.png"))
        for (n, s) in controller.model.segments.enumerated() {
            controller.model.go(to: s.first + min(2, s.last - s.first), animated: false)
            spin(1.0)
            snapshot(host, to: out.appendingPathComponent("history-segment-\(n)-\(s.app).png"))
            controller.model.go(to: s.last, animated: false)
            spin(1.0)
            snapshot(host, to: out.appendingPathComponent("history-segment-\(n)-\(s.app)-end.png"))
        }
        // Settings, for its History section.
        let model = SettingsModel(engine: Engine(sessionID: "render", label: "Agent", focusGuard: FocusGuard()))
        model.refresh()
        let settings = NSHostingView(rootView: SettingsView(model: model))
        let sw = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 600, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        sw.contentView = settings
        spin(1.0)
        settings.setFrameSize(settings.fittingSize)
        snapshot(settings, to: out.appendingPathComponent("settings.png"))
        exit(0)
    }

    private static func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private static func offscreenViewer() -> (HistoryWindowController, NSView) {
        let controller = HistoryWindowController()
        let host = NSHostingView(rootView: HistoryView(controller: controller, model: controller.model,
                                                       frameView: controller.frameViewForTest, trackView: controller.trackViewForTest))
        let w: CGFloat = 1400
        let h = (w - HistoryView.horizontalChrome) * 10 / 16 + HistoryView.verticalChrome
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: w, height: h), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = host
        objc_setAssociatedObject(host, &windowKey, window, .OBJC_ASSOCIATION_RETAIN)
        return (controller, host)
    }

    private static var windowKey = 0

    static func run(_ out: URL) -> Never {
        let rec = out.appendingPathComponent("recordings")
        try? FileManager.default.removeItem(at: rec)
        AppRecordings.store = Recordings(directory: rec)
        let store = AppRecordings.store
        let size = CGSize(width: 1600, height: 1000)
        let now = wallMs()

        // Claude Code in a browser, then TextEdit; later Codex in Notes.
        var framesA: [(image: CGImage, t: Double, app: String, bundleID: String?)] = []
        var eventsA: [(t: Double, text: String?, point: CGPoint?, click: Bool)] = []
        var t = now - 3_600_000
        let page = "Pricing · Plans for every team"
        for i in 0..<150 {
            let url = String("https://example.com/pricing".prefix(min(27, i / 2)))
            framesA.append((fake(size, app: "Helium", title: page, body: i < 54 ? "" : page, field: url, step: i), t, "Helium", "net.imput.helium"))
            if i % 6 == 0 {
                eventsA.append((t - 200, "click (84 ms): Clicked \"Address and search bar\"", nil, false))
                eventsA.append((t - 220, nil, CGPoint(x: 420 + Double(i), y: 120), true))
            }
            t += 700 + Double(i % 7)
        }
        for i in 0..<90 {
            let text = String("Notes from the pricing page: Pro is $20 a month, Team is $35 per seat.".prefix(i))
            framesA.append((fake(size, app: "TextEdit", title: "Untitled", body: text, field: nil, step: i), t, "TextEdit", "com.apple.TextEdit"))
            if i % 10 == 0 { eventsA.append((t - 150, "type_text (310 ms): Typed 10 characters", CGPoint(x: 700, y: 400), false)) }
            t += 900 + Double(i % 7)
        }
        RecordingTest.record(into: store, session: "11111111-aaaa", label: "Claude Code", size: size, frames: framesA, events: eventsA)

        var framesB: [(image: CGImage, t: Double, app: String, bundleID: String?)] = []
        var eventsB: [(t: Double, text: String?, point: CGPoint?, click: Bool)] = []
        t = now - 600_000
        for i in 0..<60 {
            framesB.append((fake(size, app: "Notes", title: "Groceries", body: String("Eggs, milk, bread, coffee, lemons".prefix(i)), field: nil, step: i), t, "Notes", "com.apple.Notes"))
            if i % 12 == 0 { eventsB.append((t - 100, "set_value (40 ms): Set the value of element 12", CGPoint(x: 600, y: 300), true)) }
            t += 1000 + Double(i % 7)
        }
        RecordingTest.record(into: store, session: "22222222-bbbb", label: "Codex", size: size, frames: framesB, events: eventsB)

        // Read every frame back, and check it's that frame's picture: closer
        // to its own source than to the frames either side of it.
        var sources: [Int64: CGImage] = [:]
        for f in framesA + framesB { sources[Int64(f.t)] = f.image }
        let runs = store.all()
        var total = 0, ok = 0, wrong = 0, worst = 0.0, sum = 0.0
        for r in runs {
            let frames = r.frames
            for (i, f) in frames.enumerated() {
                total += 1
                let start = CACurrentMediaTime()
                let image = r.image(for: f)
                let ms = (CACurrentMediaTime() - start) * 1000
                sum += ms; worst = max(worst, ms)
                guard let image else { continue }
                ok += 1
                guard let own = sources[Int64(f.t)] else { continue }
                let mine = difference(image, own)
                let neighbours = [i - 1, i + 1].filter(frames.indices.contains).compactMap { sources[Int64(frames[$0].t)] }
                if neighbours.contains(where: { difference(image, $0) < mine }) { wrong += 1 }
            }
        }
        print("\(wrong) frames decoded to the wrong picture")
        let bytes = (FileManager.default.enumerator(at: rec, includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL] ?? [])
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        let staged = (FileManager.default.enumerator(atPath: rec.path)?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".jpg") }.count
        print("runs \(runs.count), frames \(ok)/\(total) decoded, avg \(String(format: "%.1f", sum / Double(max(1, total)))) ms, worst \(String(format: "%.1f", worst)) ms, \(bytes / 1024) KB on disk, \(staged) JPEGs left in staging")

        // The viewer, offscreen.
        let (controller, host) = offscreenViewer()
        controller.model.load()
        spin(1.5)
        snapshot(host, to: out.appendingPathComponent("history-latest.png"))
        controller.model.go(to: 120, animated: false)
        spin(1.0)
        snapshot(host, to: out.appendingPathComponent("history-browser.png"))
        controller.zoomTrack(-2)
        controller.model.go(to: 200, animated: false)
        spin(1.0)
        snapshot(host, to: out.appendingPathComponent("history-zoomed-out.png"))

        // Retention: a run that ended 8 days ago goes; recent ones stay.
        let old = store.directory.appendingPathComponent("20200101-000000-old")
        try? FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let meta: [String: Any] = ["v": 1, "session": "old", "label": "Agent", "start": now - 9 * 86_400_000, "end": now - 8 * 86_400_000, "w": 1600, "h": 1000]
        try? JSONSerialization.data(withJSONObject: meta).write(to: old.appendingPathComponent("meta.json"))
        store.maintain()
        spin(1.0)
        let kept = (try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? []
        print("after cleanup: \(kept.sorted().joined(separator: ", ")) (old run \(kept.contains(old.lastPathComponent) ? "KEPT, wrong" : "deleted"))")
        // Size limit: squeeze to about half; the oldest chunks go, the newest run stays whole.
        let before = store.usedBytes()
        let newest = store.all().last.map { ($0.id, $0.frames.count) }
        RecordingTest.applyLimit(store, bytes: before / 2)
        let after = store.usedBytes()
        let left = store.all()
        let newestKept = left.last.map { ($0.id, $0.frames.count) }
        let firstLeft = left.first?.frames.first.map { HistoryModel.time($0.t, seconds: true) } ?? "-"
        var decodedAfter = 0
        for r in left { for f in r.frames where r.image(for: f) != nil { decodedAfter += 1 } }
        let leftFrames = left.reduce(0) { $0 + $1.frames.count }
        let limitOK = after <= before / 2 && newestKept?.0 == newest?.0 && newestKept?.1 == newest?.1 && decodedAfter == leftFrames && leftFrames < total
        print("size limit: \(before / 1024) KB -> \(after / 1024) KB (limit \(before / 2048) KB), \(leftFrames) frames left from \(firstLeft), all decode: \(decodedAfter == leftFrames), newest run whole: \(newestKept?.1 == newest?.1) -> \(limitOK ? "ok" : "WRONG")")
        RecordingTest.applyLimit(store, bytes: nil)
        exit(ok == total && total > 0 && wrong == 0 && limitOK ? 0 : 1)
    }

    /// Mean gray difference between two pictures, at 160×100.
    private static func difference(_ a: CGImage, _ b: CGImage) -> Double {
        func gray(_ i: CGImage) -> [UInt8] {
            var px = [UInt8](repeating: 0, count: 160 * 100)
            let ctx = CGContext(data: &px, width: 160, height: 100, bitsPerComponent: 8, bytesPerRow: 160,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.interpolationQuality = .medium
            ctx.draw(i, in: CGRect(x: 0, y: 0, width: 160, height: 100))
            return px
        }
        let x = gray(a), y = gray(b)
        return Double(zip(x, y).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(x.count)
    }

    private static func snapshot(_ view: NSView, to url: URL) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.path)")
    }

    /// A made-up agent display: wallpaper, one window with a title bar, an
    /// optional address field and some text.
    private static func fake(_ size: CGSize, app: String, title: String, body: String, field: String?, step: Int) -> CGImage {
        let w = Int(size.width * 1.5), h = Int(size.height * 1.5)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        let s: CGFloat = 1.5
        NSGradient(starting: NSColor(hex: 0x2B3A55), ending: NSColor(hex: 0x6A4C7A))!.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: 60)
        let win = NSRect(x: 80 * s, y: 60 * s, width: 1300 * s, height: 860 * s)
        NSColor(hex: 0xFAFAFA).setFill()
        NSBezierPath(roundedRect: win, xRadius: 12 * s, yRadius: 12 * s).fill()
        NSColor(hex: 0xE8E8EA).setFill()
        NSBezierPath(roundedRect: NSRect(x: win.minX, y: win.maxY - 52 * s, width: win.width, height: 52 * s), xRadius: 12 * s, yRadius: 12 * s).fill()
        for (i, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            NSColor(hex: UInt32(c)).setFill()
            NSBezierPath(ovalIn: NSRect(x: win.minX + (20 + CGFloat(i) * 20) * s, y: win.maxY - 32 * s, width: 12 * s, height: 12 * s)).fill()
        }
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14 * s, weight: .semibold), .foregroundColor: NSColor(hex: 0x333333)]
        (title as NSString).draw(at: NSPoint(x: win.minX + 110 * s, y: win.maxY - 35 * s), withAttributes: titleAttrs)
        var y = win.maxY - 110 * s
        if let field {
            NSColor.white.setFill()
            let f = NSRect(x: win.minX + 40 * s, y: y, width: win.width - 80 * s, height: 38 * s)
            NSBezierPath(roundedRect: f, xRadius: 8 * s, yRadius: 8 * s).fill()
            NSColor(hex: 0x0A84FF).setStroke()
            let p = NSBezierPath(roundedRect: f, xRadius: 8 * s, yRadius: 8 * s); p.lineWidth = 2 * s; p.stroke()
            (field as NSString).draw(at: NSPoint(x: f.minX + 14 * s, y: f.minY + 9 * s),
                                     withAttributes: [.font: NSFont.systemFont(ofSize: 16 * s), .foregroundColor: NSColor.black])
            y -= 70 * s
        }
        let bodyAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22 * s, weight: field == nil ? .regular : .bold),
                                                        .foregroundColor: NSColor(hex: 0x1D1D1F)]
        (body as NSString).draw(in: NSRect(x: win.minX + 40 * s, y: win.minY + 40 * s, width: win.width - 80 * s, height: y - win.minY - 40 * s),
                                withAttributes: bodyAttrs)
        if field != nil, !body.isEmpty {
            for r in 0..<3 {
                NSColor(hex: [0xEAF2FF, 0xF2EAFF, 0xEAFFF0][r]).setFill()
                NSBezierPath(roundedRect: NSRect(x: win.minX + (40 + CGFloat(r) * 410) * s, y: win.minY + 80 * s, width: 380 * s, height: 420 * s),
                             xRadius: 14 * s, yRadius: 14 * s).fill()
                (["Free", "Pro  $20", "Team  $35"][r] as NSString).draw(at: NSPoint(x: win.minX + (64 + CGFloat(r) * 410) * s, y: win.minY + 440 * s),
                                                                     withAttributes: bodyAttrs)
            }
        }
        // A block that moves every frame, so neighbouring frames never look alike.
        NSColor(hex: 0xFF9F0A).setFill()
        NSRect(x: win.minX + CGFloat(step % 12) * 100 * s, y: 8 * s, width: 90 * s, height: 44 * s).fill()
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }
}
