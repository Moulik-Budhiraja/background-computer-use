import AppKit
import CoreServices

/// Chromium browsers can be told where to build a new window (AppleScript's
/// `make new window with properties {bounds:…}`), so it opens straight on
/// the agent display and never shows on the user's screen. That needs the
/// user's OK for this app to control the browser (Automation), asked once
/// per browser: during setup for their default browser, else the first time
/// an agent opens one of its windows.
public enum BrowserAutomation {
    public enum Permission { case allowed, denied, notAsked }

    /// A Chromium browser: "<Name> Framework.framework" and Chrome's scripting
    /// dictionary, with its scriptable window class.
    public static func isScriptableChromium(_ app: URL) -> Bool {
        let frameworks = (try? FileManager.default.contentsOfDirectory(atPath: app.appendingPathComponent("Contents/Frameworks").path)) ?? []
        guard frameworks.contains(where: { $0.hasSuffix(" Framework.framework") }),
              let sdef = try? String(contentsOf: app.appendingPathComponent("Contents/Resources/scripting.sdef"), encoding: .utf8) else { return false }
        return sdef.contains("<class name=\"window\"")
    }

    /// The user's default browser, when it's one whose windows can be placed.
    public static func defaultBrowser() -> (name: String, bundleID: String, url: URL)? {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!),
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, isScriptableChromium(url) else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return (name, id, url)
    }

    private static let pendingLock = NSLock()
    /// Browsers macOS is asking the user about right now, with everyone
    /// waiting for the answer.
    private static var pending: [String: [(Permission) -> Void]] = [:]

    /// Whether this app may control `bundleID`, without asking. macOS can only
    /// tell while the app runs; otherwise `notAsked`. While macOS is asking
    /// the user, also `notAsked`: checking then blocks until they answer.
    public static func permission(_ bundleID: String) -> Permission {
        pendingLock.lock()
        let asking = pending[bundleID] != nil
        pendingLock.unlock()
        if asking { return .notAsked }
        switch determine(bundleID, ask: false) {
        case noErr: return .allowed
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .notAsked
        }
    }

    /// Ask the user (macOS shows its prompt), launching the browser hidden
    /// first if it isn't running, since macOS can only ask about a running app.
    /// Calls back on the main thread.
    public static func request(_ bundleID: String, app: URL? = nil, completion: @escaping (Permission) -> Void) {
        pendingLock.lock()
        let already = pending[bundleID] != nil
        pending[bundleID, default: []].append(completion)
        pendingLock.unlock()
        // One prompt at a time per browser; everyone gets its answer.
        if already { return }
        DispatchQueue.global(qos: .userInitiated).async {
            if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty,
               let url = app ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                config.hides = true
                config.addsToRecentItems = false
                NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
                let deadline = Date().addingTimeInterval(10)
                while NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty && Date() < deadline { usleep(100_000) }
            }
            let status = determine(bundleID, ask: true)
            let result: Permission = status == noErr ? .allowed : (status == OSStatus(errAEEventNotPermitted) ? .denied : .notAsked)
            Log.info("control of \(bundleID): \(result)")
            pendingLock.lock()
            let waiting = pending.removeValue(forKey: bundleID) ?? []
            pendingLock.unlock()
            DispatchQueue.main.async { waiting.forEach { $0(result) } }
        }
    }

    private static func code(_ s: String) -> OSType {
        s.utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }

    // The browser is driven by Apple events sent from this process. Running
    // `osascript` for each one costs a process launch and a compile: 200–900
    // ms on an idle Mac, most of it before the browser hears anything, and
    // many seconds on a busy one (measured: over 6 s while macOS was adding
    // displays, so windows failed to open with the browser idle all along).

    private static func specifier(want: OSType, form: OSType, key: NSAppleEventDescriptor, from: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
        let r = NSAppleEventDescriptor.record()
        r.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: code("want"))
        r.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: code("form"))
        r.setDescriptor(key, forKeyword: code("seld"))
        r.setDescriptor(from, forKeyword: code("from"))
        return r.coerce(toDescriptorType: code("obj "))
    }

    private static func event(_ eventClass: String, _ id: String, to bundleID: String) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(eventClass: code(eventClass), eventID: code(id),
                               targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: bundleID),
                               returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    }

    /// The browser's answer, or nil (logged) if it refused or didn't answer.
    private static func send(_ event: NSAppleEventDescriptor, _ what: String, to bundleID: String, timeout: TimeInterval) -> NSAppleEventDescriptor? {
        do {
            let reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: timeout)
            if let err = reply.paramDescriptor(forKeyword: code("errn")), err.int32Value != 0 {
                Log.info("\(what): \(bundleID) answered error \(err.int32Value) \(reply.paramDescriptor(forKeyword: code("errs"))?.stringValue ?? "")")
                return nil
            }
            return reply
        } catch {
            Log.info("\(what): \(bundleID) didn't take the event: \(error.localizedDescription)")
            return nil
        }
    }

    /// Have the browser build a new window at `bounds` (global points,
    /// top-left origin): `make new window with properties {bounds: …}`.
    /// `made` is false if it refused or didn't answer in time; `id` is the
    /// browser's own id for the window (`id of window` in AppleScript), which
    /// its answer names.
    public static func makeWindow(bundleID: String, bounds: CGRect, timeout: TimeInterval = 5) -> (made: Bool, id: String?) {
        let rect = NSAppleEventDescriptor.list()
        for (i, v) in [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY].enumerated() {
            rect.insert(NSAppleEventDescriptor(int32: Int32(v)), at: i + 1)
        }
        let properties = NSAppleEventDescriptor.record()
        properties.setDescriptor(rect, forKeyword: code("pbnd"))
        let make = event("core", "crel", to: bundleID)
        make.setParam(NSAppleEventDescriptor(typeCode: code("cwin")), forKeyword: code("kocl"))
        make.setParam(properties, forKeyword: code("prdt"))
        guard let reply = send(make, "make new window", to: bundleID, timeout: timeout) else { return (false, nil) }
        // The answer is `window id N`.
        var id: String?
        if let made = reply.paramDescriptor(forKeyword: code("----"))?.coerce(toDescriptorType: code("reco")),
           made.forKeyword(code("form"))?.enumCodeValue == code("ID  "), let n = made.forKeyword(code("seld")) {
            id = n.stringValue ?? String(n.int32Value)
        }
        return (true, id)
    }

    public enum WindowLookup: Equatable { case found(String), none, several, failed }

    /// left, top, right, bottom of a `bounds` value: a QuickDraw rect
    /// (16-bit top, left, bottom, right), or a list as AppleScript shows it.
    private static func edges(_ d: NSAppleEventDescriptor) -> [Int]? {
        if d.descriptorType == code("qdrt"), d.data.count == 8 {
            let v = d.data.withUnsafeBytes { raw in (0..<4).map { Int(raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) } }
            return [v[1], v[0], v[3], v[2]]
        }
        guard d.numberOfItems == 4 else { return nil }
        return (1...4).map { Int(d.atIndex($0)?.int32Value ?? 0) }
    }

    private static func edges(_ r: CGRect) -> [Int] {
        [Int(r.minX.rounded()), Int(r.minY.rounded()), Int(r.maxX.rounded()), Int(r.maxY.rounded())]
    }

    /// Where the browser says its window with this id is (`bounds of window
    /// id <id>`), in global points with a top-left origin. Nil if it has no
    /// such window or didn't say.
    public static func frame(bundleID: String, window id: String, timeout: TimeInterval = 2) -> CGRect? {
        let property = code("prop")
        guard let window = specifier(want: code("cwin"), form: code("ID  "), key: NSAppleEventDescriptor(string: id), from: .null()),
              let target = specifier(want: property, form: property, key: NSAppleEventDescriptor(typeCode: code("pbnd")), from: window) else { return nil }
        let get = event("core", "getd", to: bundleID)
        get.setParam(target, forKeyword: code("----"))
        guard let value = send(get, "window bounds", to: bundleID, timeout: timeout)?.paramDescriptor(forKeyword: code("----")),
              let e = edges(value) else { return nil }
        return CGRect(x: e[0], y: e[1], width: e[2] - e[0], height: e[3] - e[1])
    }

    /// The same frame, to the point (the browser's are whole numbers).
    public static func sameFrame(_ a: CGRect?, _ b: CGRect?) -> Bool {
        guard let a, let b else { return false }
        return edges(a) == edges(b)
    }

    /// The browser's own id for its window with this frame (global points,
    /// top-left origin: the same in the browser's scripting and the window
    /// list). Two of its windows can share a frame (the cascade repeats), and
    /// then nothing tells them apart: `several`.
    public static func windowID(bundleID: String, bounds: CGRect, timeout: TimeInterval = 3) -> WindowLookup {
        let property = code("prop")
        func ofEveryWindow(_ name: String) -> [NSAppleEventDescriptor]? {
            var every = code("all ")
            let all = NSAppleEventDescriptor(descriptorType: code("abso"), bytes: &every, length: MemoryLayout<OSType>.size) ?? .null()
            guard let windows = specifier(want: code("cwin"), form: code("indx"), key: all, from: .null()),
                  let target = specifier(want: property, form: property, key: NSAppleEventDescriptor(typeCode: code(name)), from: windows) else { return nil }
            let get = event("core", "getd", to: bundleID)
            get.setParam(target, forKeyword: code("----"))
            guard let reply = send(get, "window lookup", to: bundleID, timeout: timeout) else { return nil }
            guard let list = reply.paramDescriptor(forKeyword: code("----")), list.numberOfItems > 0 else { return [] }
            return (1...list.numberOfItems).compactMap { list.atIndex($0) }
        }
        // Three questions, not one: asked again, the ids say whether the
        // windows changed between the other two.
        guard let ids = ofEveryWindow("ID  "), let frames = ofEveryWindow("pbnd"), let again = ofEveryWindow("ID  ") else { return .failed }
        func names(_ list: [NSAppleEventDescriptor]) -> [String] { list.map { $0.stringValue ?? String($0.int32Value) } }
        guard names(ids) == names(again), ids.count == frames.count else { return .failed }
        let want = edges(bounds)
        let found = zip(names(ids), frames).filter { edges($0.1) == want }.map(\.0)
        return found.count == 1 ? .found(found[0]) : (found.isEmpty ? .none : .several)
    }

    /// Load `url` in the active tab of one of the browser's windows, named by
    /// the browser's own id for it: `set URL of active tab of window id <id>
    /// to <url>`. The browser makes the window it loads in key, so the user's
    /// typing into the browser is held meanwhile: a few tens of ms. False if
    /// the browser refused or didn't answer.
    public static func setURL(bundleID: String, window id: String, url: String, timeout: TimeInterval = 5) -> Bool {
        let property = code("prop")
        guard let window = specifier(want: code("cwin"), form: code("ID  "), key: NSAppleEventDescriptor(string: id), from: .null()),
              let tab = specifier(want: property, form: property, key: NSAppleEventDescriptor(typeCode: code("acTa")), from: window),
              let target = specifier(want: property, form: property, key: NSAppleEventDescriptor(typeCode: code("URL ")), from: tab) else { return false }
        let set = event("core", "setd", to: bundleID)
        set.setParam(target, forKeyword: code("----"))
        set.setParam(NSAppleEventDescriptor(string: url), forKeyword: code("data"))
        return send(set, "set URL", to: bundleID, timeout: timeout) != nil
    }

    /// Whether the active tab of one of the browser's windows is still
    /// loading (`loading of active tab of window id <id>`). Nil if the
    /// browser didn't say.
    public static func isLoading(bundleID: String, window id: String, timeout: TimeInterval = 1) -> Bool? {
        let property = code("prop")
        guard let window = specifier(want: code("cwin"), form: code("ID  "), key: NSAppleEventDescriptor(string: id), from: .null()),
              let tab = specifier(want: property, form: property, key: NSAppleEventDescriptor(typeCode: code("acTa")), from: window),
              let target = specifier(want: property, form: property, key: NSAppleEventDescriptor(typeCode: code("ldng")), from: tab) else { return nil }
        let get = event("core", "getd", to: bundleID)
        get.setParam(target, forKeyword: code("----"))
        return send(get, "tab loading", to: bundleID, timeout: timeout)?.paramDescriptor(forKeyword: code("----"))?.booleanValue
    }

    private static func determine(_ bundleID: String, ask: Bool) -> OSStatus {
        var target = AEAddressDesc()
        let id = Array(bundleID.utf8)
        guard AECreateDesc(DescType(typeApplicationBundleID), id, id.count, &target) == noErr else { return OSStatus(procNotFound) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
    }
}
