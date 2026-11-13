// BCU Fixture: stands in for the app the user is in during an invisibility
// test. An ordinary app with one or more ordinary windows that writes down
// everything a user would feel as a line of JSON:
//
// - every key it receives, with how long it took to arrive (typing lag),
//   which window got it and whether that window was key
// - the app becoming active or inactive, a window gaining or losing key or
//   main, being covered or moved (focus stealing)
// - the pointer entering and leaving a hover tile, for each kind of
//   tracking area: always, while the app is active, while the window is key
//   (broken hover)
// - SIGUSR2 makes it bring itself to the front, as an agent's app does
//
//   Fixture --log PATH [--frame x,y,w,h] [--title NAME] [--extra N]
//
// --frame is in global points with a top-left origin, like CGWindowList.
// SIGUSR1 writes the text view's whole text to the log.
import AppKit

func uptimeMs() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000 }

var arguments: [String: String] = [:]
do {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() { if a.hasPrefix("--"), let v = it.next() { arguments[String(a.dropFirst(2))] = v } }
}

let logPath = arguments["log"] ?? "/tmp/bcu-fixture.jsonl"
FileManager.default.createFile(atPath: logPath, contents: nil)
let logHandle = FileHandle(forWritingAtPath: logPath)!
let logLock = NSLock()

func log(_ ev: String, _ extra: [String: Any] = [:]) {
    var o = extra
    o["ev"] = ev
    o["t"] = uptimeMs()
    guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return }
    logLock.lock()
    logHandle.write(data)
    logHandle.write(Data("\n".utf8))
    logLock.unlock()
}

final class FixtureApp: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown || event.type == .keyUp {
            let now = uptimeMs()
            let sent = event.timestamp * 1000
            log(event.type == .keyDown ? "keydown" : "keyup", [
                "ch": event.characters ?? "", "code": Int(event.keyCode), "sent": sent, "lat": now - sent,
                "repeat": event.type == .keyDown ? event.isARepeat : false,
                "win": event.windowNumber, "keywin": keyWindow?.windowNumber ?? 0, "active": isActive,
                "mods": Int(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue),
            ])
        }
        super.sendEvent(event)
    }
}

/// A tile that lights up while the pointer is over it. It has one tracking
/// area of each kind over the same rect, so one parked pointer shows which
/// kinds of hover an agent's step breaks: `always` only ends when the pointer
/// really leaves (it moved, or a window came between), `active-app` also when
/// the app stops being active, `key-window` also when the window loses key.
final class HoverTile: NSView {
    static let kinds: [(String, NSTrackingArea.Options)] = [("always", .activeAlways), ("active-app", .activeInActiveApp), ("key-window", .activeInKeyWindow)]
    private var inside: Set<String> = [] { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        for (name, option) in Self.kinds {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [option, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: ["kind": name]))
        }
    }

    private func kind(_ event: NSEvent) -> String { (event.trackingArea?.userInfo?["kind"] as? String) ?? "?" }
    override func mouseEntered(with event: NSEvent) { inside.insert(kind(event)); log("hover_enter", ["kind": kind(event)]) }
    override func mouseExited(with event: NSEvent) { inside.remove(kind(event)); log("hover_exit", ["kind": kind(event)]) }

    override func draw(_ dirtyRect: NSRect) {
        (inside.count == 3 ? NSColor.systemOrange : (inside.isEmpty ? NSColor(white: 0.82, alpha: 1) : NSColor.systemYellow)).setFill()
        bounds.fill()
        let text = "hover: \(Self.kinds.map(\.0).filter(inside.contains).joined(separator: ", "))" as NSString
        text.draw(at: NSPoint(x: 8, y: 8), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
    }
}

final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate {
    var windows: [NSWindow] = []
    var textView: NSTextView!
    var hoverTile: HoverTile!
    var activateSource: DispatchSourceSignal?
    var signalSource: DispatchSourceSignal?

    /// Global top-left rect to AppKit's bottom-left origin.
    func cocoa(_ r: CGRect) -> NSRect {
        let primary = NSScreen.screens.first { $0.frame.origin == .zero }?.frame ?? NSScreen.main!.frame
        return NSRect(x: r.minX, y: primary.maxY - r.maxY, width: r.width, height: r.height)
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        let title = arguments["title"] ?? "BCU Fixture"
        var frame = CGRect(x: 240, y: 140, width: 900, height: 620)
        if let f = arguments["frame"]?.split(separator: ",").compactMap({ Double($0) }), f.count == 4 {
            frame = CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
        }
        let main = makeWindow(title: title, frame: frame, primary: true)
        let extra = Int(arguments["extra"] ?? "0") ?? 0
        for i in 0..<extra {
            _ = makeWindow(title: "\(title) \(i + 2)", frame: frame.offsetBy(dx: CGFloat(60 * (i + 1)), dy: CGFloat(60 * (i + 1))), primary: false)
        }
        NSApp.activate(ignoringOtherApps: true)
        main.makeKeyAndOrderFront(nil)
        main.makeFirstResponder(textView)

        signal(SIGUSR1, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        src.setEventHandler { [weak self] in log("text", ["text": self?.textView.string ?? ""]) }
        src.resume()
        signalSource = src

        // SIGUSR2: bring itself to the front the way Chromium does when it
        // shows a window, to see what a self-activation looks like from outside.
        signal(SIGUSR2, SIG_IGN)
        let act = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        act.setEventHandler { [weak self] in
            log("self_activate", ["active_before": NSApp.isActive])
            self?.windows.first?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        act.resume()
        activateSource = act

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            // Global top-left frames, as CGWindowList gives them.
            let primary = NSScreen.screens.first { $0.frame.origin == .zero }?.frame ?? .zero
            func global(_ r: NSRect) -> [Double] { [r.minX, primary.maxY - r.maxY, r.width, r.height] }
            let tile = global(main.convertToScreen(self.hoverTile.convert(self.hoverTile.bounds, to: nil)))
            log("ready", [
                "pid": Int(getpid()),
                "windows": self.windows.map { ["num": $0.windowNumber, "title": $0.title, "frame": global($0.frame)] as [String: Any] },
                "tile": tile,
                "text": global(main.convertToScreen(self.textView.enclosingScrollView!.convert(self.textView.enclosingScrollView!.bounds, to: nil))),
            ])
        }
    }

    func makeWindow(title: String, frame: CGRect, primary: Bool) -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setFrame(cocoa(frame), display: false)
        let content = NSView(frame: NSRect(origin: .zero, size: w.contentLayoutRect.size))
        content.autoresizingMask = [.width, .height]
        w.contentView = content
        if primary {
            let tileH: CGFloat = 90
            let scroll = NSScrollView(frame: NSRect(x: 0, y: tileH + 16, width: content.bounds.width, height: content.bounds.height - tileH - 16))
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            let tv = NSTextView(frame: scroll.bounds)
            tv.autoresizingMask = [.width]
            tv.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            tv.isAutomaticSpellingCorrectionEnabled = false
            tv.isAutomaticTextReplacementEnabled = false
            tv.isAutomaticQuoteSubstitutionEnabled = false
            tv.isAutomaticDashSubstitutionEnabled = false
            tv.isAutomaticTextCompletionEnabled = false
            tv.isContinuousSpellCheckingEnabled = false
            tv.delegate = self
            scroll.documentView = tv
            content.addSubview(scroll)
            textView = tv
            let tile = HoverTile(frame: NSRect(x: 16, y: 8, width: content.bounds.width - 32, height: tileH))
            tile.autoresizingMask = [.width, .maxYMargin]
            content.addSubview(tile)
            hoverTile = tile
        }
        windows.append(w)
        w.orderFront(nil)
        return w
    }

    func buildMenu() {
        let main = NSMenu()
        func add(_ title: String, _ items: [(String, Selector?, String)]) {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: title)
            for (t, sel, key) in items { sub.addItem(NSMenuItem(title: t, action: sel, keyEquivalent: key)) }
            top.submenu = sub
            main.addItem(top)
        }
        add("BCU Fixture", [("Quit BCU Fixture", #selector(NSApplication.terminate(_:)), "q")])
        add("File", [("Close", #selector(NSWindow.performClose(_:)), "w")])
        add("Edit", [("Undo", Selector(("undo:")), "z"), ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
                     ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")])
        add("View", [("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f")])
        add("Window", [("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")])
        NSApp.mainMenu = main
    }

    func textDidChange(_ notification: Notification) { log("text_len", ["len": (textView.string as NSString).length]) }

    func applicationDidBecomeActive(_ n: Notification) { log("app_active") }
    func applicationDidResignActive(_ n: Notification) { log("app_inactive") }
    func applicationDidHide(_ n: Notification) { log("app_hidden") }
    func applicationDidUnhide(_ n: Notification) { log("app_unhidden") }

    private func note(_ ev: String, _ n: Notification) {
        guard let w = n.object as? NSWindow else { return }
        log(ev, ["win": w.windowNumber, "title": w.title])
    }
    func windowDidBecomeKey(_ n: Notification) { note("win_key", n) }
    func windowDidResignKey(_ n: Notification) { note("win_unkey", n) }
    func windowDidBecomeMain(_ n: Notification) { note("win_main", n) }
    func windowDidResignMain(_ n: Notification) { note("win_unmain", n) }
    func windowDidMove(_ n: Notification) { note("win_moved", n) }
    func windowDidChangeScreen(_ n: Notification) { note("win_screen", n) }
    func windowDidChangeOcclusionState(_ n: Notification) {
        guard let w = n.object as? NSWindow else { return }
        log("win_occlusion", ["win": w.windowNumber, "visible": w.occlusionState.contains(.visible)])
    }
}

let app = FixtureApp.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
