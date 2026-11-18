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

        // Another agent in Mail at the same time, starting 40 s into the first.
        var framesC: [(image: CGImage, t: Double, app: String, bundleID: String?)] = []
        var eventsC: [(t: Double, text: String?, point: CGPoint?, click: Bool)] = []
        t = now - 3_600_000 + 40_350
        for i in 0..<100 {
            framesC.append((fake(size, app: "Mail", title: "Inbox", body: String("Re: Thursday's review, moved to 3 pm".prefix(i / 2)), field: nil, step: i), t, "Mail", "com.apple.mail"))
            if i % 8 == 0 { eventsC.append((t - 120, "click (60 ms): Clicked \"Reply\"", CGPoint(x: 500, y: 200), true)) }
            t += 1100 + Double(i % 5)
        }
        RecordingTest.record(into: store, session: "33333333-cccc", label: "Claude Code", size: size, frames: framesC, events: eventsC)

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
        for f in framesA + framesB + framesC { sources[Int64(f.t)] = f.image }
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
        var clockOK = clockOrder(controller.model, "recorded")
        // Scrubbing the Mail run where the other run's frames sit between its
        // own: the playhead moves on instead of snapping back.
        let m = controller.model
        if let from = m.items.indices.first(where: { i in
            m.items[i].frame.app == "Mail" && i + 1 < m.items.count && m.items[i + 1].run == m.items[i].run && m.slot[i + 1] - m.slot[i] >= 3
        }) {
            let ok = controller.trackViewForTest.scrubForwardForTest(from: from, steps: 12)
            clockOK = clockOK && ok
            print("scrub forward past a sparse run's frames: \(ok ? "ok" : "WRONG")")
            let back = controller.trackViewForTest.recenterForTest(from: from)
            clockOK = clockOK && back
            print("jump to the frame shown after a held scrub: \(back ? "ok" : "WRONG")")
            let gap = controller.trackViewForTest.stepIntoGapForTest()
            clockOK = clockOK && gap
            print("a step into the gap before a run: \(gap ? "settled onto its first frame" : "WRONG, held")")
        } else {
            clockOK = false
            print("scrub forward: no sparse frame to start from -> WRONG")
        }

        // Hold the playhead past a Mail frame before the size limit below
        // closes up the clock: it has to stay on the timeline.
        var heldBefore: Double?
        if let mail = m.items.indices.last(where: { m.items[$0].frame.app == "Mail" && $0 + 1 < m.items.count && m.items[$0 + 1].run == m.items[$0].run && m.slot[$0 + 1] - m.slot[$0] >= 3 }),
           controller.trackViewForTest.holdForTest(from: mail) {
            heldBefore = controller.trackViewForTest.heldForTest.time
        }

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
        // The limit took the first run's oldest frames, so it now starts
        // after the Mail run that started later: lanes and gaps still follow
        // the clock.
        let (pruned, prunedHost) = offscreenViewer()
        pruned.model.load()
        spin(1.5)
        pruned.zoomTrack(-2)
        spin(0.5)
        snapshot(prunedHost, to: out.appendingPathComponent("history-after-limit.png"))
        var prunedOK = clockOrder(pruned.model, "after the size limit")
        spin(1.0)
        let heldAfter = controller.trackViewForTest.heldForTest
        let sane = heldBefore != nil && heldAfter.held && heldAfter.time == heldBefore
        prunedOK = prunedOK && sane
        print("held playhead after the size limit: \(sane ? "same time" : "WRONG, held \(heldAfter.held), time \(heldAfter.time) was \(heldBefore ?? -1)")")
        RecordingTest.applyLimit(store, bytes: nil)
        // On the newest frame when a new recording starts: History goes on to it.
        pruned.model.goToNewest()
        spin(0.3)
        var framesD: [(image: CGImage, t: Double, app: String, bundleID: String?)] = []
        t = wallMs() - 5_000
        for i in 0..<4 {
            framesD.append((fake(size, app: "Calendar", title: "Today", body: "", field: nil, step: i), t, "Calendar", "com.apple.iCal"))
            t += 1000
        }
        RecordingTest.record(into: store, session: "44444444-dddd", label: "Agent", size: size, frames: framesD, events: [])
        spin(2.0)
        let followedNew = pruned.model.currentRun?.session == "44444444-dddd" && pruned.model.atEnd
        print("a new recording after the newest frame: \(followedNew ? "followed" : "WRONG, stayed on \(pruned.model.currentRun?.session ?? "-")")")
        prunedOK = prunedOK && followedNew
        // An agent whose screen didn't change records one frame, but its
        // recording goes on: another agent recording then gets its own lane.
        let quiet = wallMs() - 4_000
        RecordingTest.record(into: store, session: "55555555-eeee", label: "Agent", size: size,
                             frames: [(fake(size, app: "Calendar", title: "Week", body: "", field: nil, step: 0), quiet, "Calendar", "com.apple.iCal")],
                             events: [], end: quiet + 3_500)
        var framesF: [(image: CGImage, t: Double, app: String, bundleID: String?)] = []
        for i in 0..<3 { framesF.append((fake(size, app: "Notes", title: "List", body: String(i), field: nil, step: i), quiet + 1_000 + Double(i) * 500, "Notes", "com.apple.Notes")) }
        RecordingTest.record(into: store, session: "66666666-ffff", label: "Agent", size: size, frames: framesF, events: [])
        spin(2.0)
        let pm = pruned.model
        let laneE = pm.runs.indices.first { pm.runs[$0].session == "55555555-eeee" }.map { pm.laneOf[$0] }
        let laneF = pm.runs.indices.first { pm.runs[$0].session == "66666666-ffff" }.map { pm.laneOf[$0] }
        let ownLane = laneE != nil && laneF != nil && laneE != laneF
        print("a quiet agent still recording keeps its lane: \(ownLane ? "ok" : "WRONG, lanes \(String(describing: laneE)) \(String(describing: laneF))")")
        prunedOK = prunedOK && ownLane
        // A live agent whose screen hasn't changed: hold the playhead at a
        // time it was showing that frame, and its next frame doesn't pull
        // History away. Then it stops, and a run that starts right after
        // shares its lane: capture stopped before the packing finished.
        let base = wallMs() - 120_000
        var liveOK = false
        if let live = LiveRecordingTest(store: store, session: "77777777-aaaa", label: "Agent", size: size, start: base) {
            live.add(fake(size, app: "Maps", title: "Map", body: "", field: nil, step: 0), t: base, app: "Maps", bundleID: "com.apple.Maps")
            var framesG: [(image: CGImage, t: Double, app: String, bundleID: String?)] = []
            for i in 0..<20 { framesG.append((fake(size, app: "Books", title: "Library", body: String(i), field: nil, step: i), base + 2_000 + Double(i) * 1_000, "Books", "com.apple.iBooksX")) }
            RecordingTest.record(into: store, session: "88888888-bbbb", label: "Agent", size: size, frames: framesG, events: [])
            let (viewer, _) = offscreenViewer()
            viewer.model.load()
            spin(1.5)
            let vm = viewer.model
            if let a = vm.items.indices.first(where: { vm.runs[vm.items[$0].run].session == "77777777-aaaa" }),
               viewer.trackViewForTest.holdForTest(from: a) {
                live.add(fake(size, app: "Maps", title: "Map", body: "moved", field: nil, step: 1), t: wallMs(), app: "Maps", bundleID: "com.apple.Maps")
                spin(1.5)
                let stayed = vm.current.map { vm.runs[$0.run].session == "77777777-aaaa" && $0.frame.t == base.rounded() } == true
                print("held on a live agent's unchanged frame, then it records: \(stayed ? "stayed" : "WRONG, moved")")
                // Back at the live edge, held on the same unchanged frame while
                // another agent records: its next frame is followed.
                var framesJ: [(image: CGImage, t: Double, app: String, bundleID: String?)] = []
                let soon = wallMs()
                for i in 0..<3 { framesJ.append((fake(size, app: "Books", title: "Shelf", body: String(i), field: nil, step: i), soon + 10 + Double(i) * 10, "Books", "com.apple.iBooksX")) }
                RecordingTest.record(into: store, session: "aaaa0000-dddd", label: "Agent", size: size, frames: framesJ, events: [])
                spin(1.5)
                var edgeOK = false, reopened = false
                let aLast = soon + 200
                if let newestA = vm.items.indices.last(where: { vm.runs[vm.items[$0].run].session == "77777777-aaaa" }) {
                    // Opening History again starts from the newest frame, not the hold.
                    let heldNewest = viewer.trackViewForTest.holdForTest(from: newestA)
                    viewer.open(session: "77777777-aaaa")
                    spin(1.0)
                    reopened = heldNewest && !viewer.trackViewForTest.heldForTest.held && !vm.holdingPast
                        && vm.current.map { vm.runs[$0.run].session == "77777777-aaaa" } == true
                    print("reopened while held: \(reopened ? "let go of the hold" : "WRONG, still held")")
                }
                if let newestA = vm.items.indices.last(where: { vm.runs[vm.items[$0].run].session == "77777777-aaaa" }),
                   viewer.trackViewForTest.holdAtEdgeForTest(from: newestA) {
                    live.add(fake(size, app: "Maps", title: "Map", body: "moved again", field: nil, step: 2), t: aLast, app: "Maps", bundleID: "com.apple.Maps")
                    spin(1.5)
                    edgeOK = vm.current.map { vm.runs[$0.run].session == "77777777-aaaa" && $0.frame.t == aLast.rounded() } == true
                }
                print("held at the live edge on a live agent, then it records: \(edgeOK ? "followed" : "WRONG, stayed")")
                // It stops while its video is still packing, and another run
                // starts right after: History goes on to it, and they share a lane.
                live.finish(packing: 2.0)
                let next = max(wallMs(), aLast) + 1
                var framesH: [(image: CGImage, t: Double, app: String, bundleID: String?)] = []
                for i in 0..<3 { framesH.append((fake(size, app: "Maps", title: "Map", body: "next \(i)", field: nil, step: i), next + Double(i) * 30, "Maps", "com.apple.Maps")) }
                RecordingTest.record(into: store, session: "99999999-cccc", label: "Agent", size: size, frames: framesH, events: [])
                spin(1.2)
                let movedOn = vm.currentRun?.session == "99999999-cccc"
                print("the run stopped while packing, another started: \(movedOn ? "moved on to it" : "WRONG, stayed on \(vm.currentRun?.session ?? "-")")")
                spin(2.5)
                let lane = { (session: String) in vm.runs.indices.first { vm.runs[$0].session == session }.map { vm.laneOf[$0] } }
                let shared = lane("77777777-aaaa") != nil && lane("77777777-aaaa") == lane("99999999-cccc")
                print("a run that starts as another stops shares its lane: \(shared ? "ok" : "WRONG")")
                liveOK = stayed && reopened && edgeOK && movedOn && shared
            } else {
                print("live agent: couldn't hold the playhead -> WRONG")
            }
        }
        // Mid-gesture on a quiet live agent: a reload doesn't follow it from
        // an earlier time, nor put back the last gesture's hold; held at the
        // live edge, when it stops, History goes on to the newest frame.
        var gestureOK = false
        let base2 = wallMs()
        if let quiet = LiveRecordingTest(store: store, session: "bbbb0000-eeee", label: "Agent", size: size, start: base2 - 30_000) {
            quiet.add(fake(size, app: "Photos", title: "All", body: "", field: nil, step: 0), t: base2 - 30_000, app: "Photos", bundleID: "com.apple.Photos")
            var framesK: [(image: CGImage, t: Double, app: String, bundleID: String?)] = []
            // Another agent records all along, so the quiet one's frame is
            // well back from the live edge.
            for i in 0..<25 { framesK.append((fake(size, app: "Music", title: "Library", body: String(i), field: nil, step: i), base2 - 29_000 + Double(i) * 1_000, "Music", "com.apple.Music")) }
            RecordingTest.record(into: store, session: "cccc0000-ffff", label: "Agent", size: size, frames: framesK, events: [])
            let (viewer2, _) = offscreenViewer()
            viewer2.model.load()
            spin(1.5)
            let vm2 = viewer2.model, track = viewer2.trackViewForTest
            let isQuiet = { (i: Int) in vm2.runs[vm2.items[i].run].session == "bbbb0000-eeee" }
            if let first = vm2.items.indices.first(where: isQuiet) {
                let shownT = vm2.items[first].frame.t
                let step = track.spacingForTest
                var dragOK = track.dragForTest(from: first, by: step * 3.6)
                quiet.add(fake(size, app: "Photos", title: "All", body: "new", field: nil, step: 1), t: wallMs(), app: "Photos", bundleID: "com.apple.Photos")
                spin(1.5)
                dragOK = dragOK && vm2.current?.frame.t == shownT
                track.endDragForTest()
                dragOK = dragOK && vm2.current?.frame.t == shownT && track.heldForTest.held
                print("a reload mid-drag on a quiet live agent: \(dragOK ? "kept the earlier frame" : "WRONG, followed it")")
                // A second gesture moves on; a reload doesn't put back the first's hold.
                let settled = track.holdForTest(from: first)
                _ = track.dragForTest(from: nil, by: step * 2.3)
                let x = track.playheadXForTest, midway = settled && track.heldForTest.held && !track.heldForTest.edge
                quiet.add(fake(size, app: "Photos", title: "All", body: "newer", field: nil, step: 2), t: wallMs(), app: "Photos", bundleID: "com.apple.Photos")
                spin(1.5)
                let kept = midway && abs(track.playheadXForTest - x) < 0.5
                track.endDragForTest()
                print("a reload mid-gesture after a hold: \(kept ? "kept the playhead" : "WRONG, put back the old hold")")
                // Held at the live edge on the quiet agent while another records; it stops.
                var framesM: [(image: CGImage, t: Double, app: String, bundleID: String?)] = []
                let later = wallMs()
                for i in 0..<3 { framesM.append((fake(size, app: "Music", title: "Queue", body: String(i), field: nil, step: i), later + 10 + Double(i) * 10, "Music", "com.apple.Music")) }
                RecordingTest.record(into: store, session: "dddd0000-aaaa", label: "Agent", size: size, frames: framesM, events: [])
                spin(1.5)
                var handedOff = false
                var keptEdge = false
                if let newestQuiet = vm2.items.indices.last(where: isQuiet), track.holdAtEdgeForTest(from: newestQuiet) {
                    // It records a frame, and the other agent newer ones, in one reload.
                    quiet.add(fake(size, app: "Photos", title: "All", body: "edge", field: nil, step: 3), t: wallMs(), app: "Photos", bundleID: "com.apple.Photos")
                    var framesM2: [(image: CGImage, t: Double, app: String, bundleID: String?)] = []
                    let then = wallMs()
                    for i in 0..<3 { framesM2.append((fake(size, app: "Music", title: "Queue", body: "m\(i)", field: nil, step: i), then + 10 + Double(i) * 10, "Music", "com.apple.Music")) }
                    RecordingTest.record(into: store, session: "dddd1111-aaaa", label: "Agent", size: size, frames: framesM2, events: [])
                    spin(1.5)
                    keptEdge = track.heldForTest.edge && vm2.currentRun?.session == "bbbb0000-eeee"
                    print("at the live edge, the quiet agent and another record: \(keptEdge ? "still at the edge" : "WRONG, let go of the edge")")
                    quiet.finish(packing: 2.0)
                    var framesN: [(image: CGImage, t: Double, app: String, bundleID: String?)] = []
                    let after = wallMs()
                    for i in 0..<3 { framesN.append((fake(size, app: "Music", title: "Queue", body: "n\(i)", field: nil, step: i), after + 10 + Double(i) * 10, "Music", "com.apple.Music")) }
                    RecordingTest.record(into: store, session: "eeee0000-bbbb", label: "Agent", size: size, frames: framesN, events: [])
                    spin(1.2)
                    handedOff = vm2.currentRun?.session == "eeee0000-bbbb"
                    spin(2.0)
                }
                print("held at the live edge, the agent stops: \(handedOff ? "went on to the newest" : "WRONG, stayed on \(vm2.currentRun?.session ?? "-")")")
                gestureOK = dragOK && kept && keptEdge && handedOff
            }
        }
        exit(ok == total && total > 0 && wrong == 0 && limitOK && clockOK && prunedOK && liveOK && gestureOK ? 0 : 1)
    }

    /// Frames further right are later (gaps only go forward in time), and
    /// runs that share a lane never overlap.
    private static func clockOrder(_ m: HistoryModel, _ when: String) -> Bool {
        let forward = zip(m.byTime, m.byTime.dropFirst()).allSatisfy { m.stretch[$0] <= m.stretch[$1] }
        func span(_ r: Int) -> ClosedRange<Double> { m.items[m.runItems[r].lowerBound].frame.t...m.items[m.runItems[r].upperBound].frame.t }
        var overlapping = 0
        for a in m.runItems.indices {
            for b in m.runItems.indices where a < b && m.laneOf[a] == m.laneOf[b] && span(a).overlaps(span(b)) { overlapping += 1 }
        }
        let firsts = m.runItems.map { HistoryModel.time(m.items[$0.lowerBound].frame.t, seconds: true) }
        print("clock \(when): runs starting \(firsts.joined(separator: ", ")), lanes \(m.laneOf), \(m.lanes) lanes, gaps forward: \(forward), runs overlapping in a lane: \(overlapping) -> \(forward && overlapping == 0 ? "ok" : "WRONG")")
        return forward && overlapping == 0
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
