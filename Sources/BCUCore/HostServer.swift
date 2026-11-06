import AppKit
import BCUShared

/// What a host app needs to show agent sessions in its own UI, over the
/// engine's socket: live session state, preview frames, take-over input and
/// handoffs. The menu bar app does all of this in process; `docs/embedding.md`
/// describes the protocol and `clients/typescript` is a client for it.
///
/// Requests are lines like `{"id": 1, "op": "hello"}`; each gets one reply
/// with the same `id` and `ok`. Pushed lines have `event` instead of `id`.
/// Points are on the session's agent display, top-left origin, in points.
public final class HostServer {
    /// Bumped when a change would break an existing client.
    public static let protocolVersion = 1

    private let hub: Hub
    private let ownerName: String
    private let version: String
    /// Another engine asked this one to step aside once its agents are done (`yield`).
    public var onYield: (() -> Void)?

    private final class Client {
        let connection: SocketConnection
        var subscribed = false
        /// Sessions of this host only; nil with `all`.
        var host: String?
        var all = false
        var release: (() -> Void)?
        var lastSessions: Data?
        var streams: [Int: Stream] = [:]
        /// Sessions this client has taken over, with the input path for each.
        var remotes: [String: RemoteControl] = [:]
        init(_ connection: SocketConnection) { self.connection = connection }

        func shows(_ e: Engine) -> Bool { all || (host != nil && e.host == host) }
    }

    private final class Stream {
        let id: Int
        let engine: Engine
        var frames: FrameStream!
        var maxWidth: Int
        var quality: Double
        var seq = 0
        init(id: Int, engine: Engine, maxWidth: Int, quality: Double) {
            self.id = id
            self.engine = engine
            self.maxWidth = maxWidth
            self.quality = quality
        }
    }

    private let lock = NSLock()
    private var clients: [Int: Client] = [:]
    private var nextStream = 0
    private var pushScheduled = false
    private let pushQueue = DispatchQueue(label: "bcu.host.push")
    private var observer: Int?
    private var pointerObserver: NSObjectProtocol?

    public init(hub: Hub, ownerName: String, version: String) {
        self.hub = hub
        self.ownerName = ownerName
        self.version = version
        observer = hub.addObserver { [weak self] in self?.schedulePush() }
        pointerObserver = NotificationCenter.default.addObserver(forName: Engine.pointerNotification, object: nil, queue: nil) { [weak self] n in
            guard let self, let e = n.object as? Engine, let p = n.userInfo?["pointer"] as? AgentPointer else { return }
            self.sendPointer(e, p)
        }
    }

    deinit {
        if let observer { hub.removeObserver(observer) }
        if let pointerObserver { NotificationCenter.default.removeObserver(pointerObserver) }
    }

    /// For `SocketServer.hostHandler`. Socket threads.
    public func handle(_ op: String, _ req: JSONObject, _ connection: SocketConnection) -> JSONObject? {
        let client = self.client(for: connection)
        do {
            return try dispatch(op, Args(req), client)
        } catch {
            return ["ok": false, "error": "\(error)"]
        }
    }

    private func client(for connection: SocketConnection) -> Client {
        lock.lock()
        if let c = clients[connection.id] { lock.unlock(); return c }
        let c = Client(connection)
        clients[connection.id] = c
        lock.unlock()
        connection.onClose { [weak self] in self?.drop(connection.id) }
        return c
    }

    /// The client went away: its claims, streams and take-overs end with it.
    private func drop(_ id: Int) {
        lock.lock()
        guard let c = clients.removeValue(forKey: id) else { lock.unlock(); return }
        let streams = Array(c.streams.values)
        let remotes = c.remotes
        c.streams = [:]
        c.remotes = [:]
        lock.unlock()
        c.release?()
        for s in streams { s.frames.stop() }
        for (session, remote) in remotes {
            remote.end()
            hub.engine(id: session)?.setUserInControl(false)
        }
    }

    private func dispatch(_ op: String, _ a: Args, _ c: Client) throws -> JSONObject? {
        switch op {
        case "hello":
            return ["ok": true, "engine": engineInfo()]

        case "catalog":
            return ["ok": true, "tools": ToolCatalog.tools, "instructions": ToolCatalog.serverInstructions]

        case "subscribe":
            let host = a.string("host")
            lock.lock()
            c.release?()
            c.release = nil
            c.host = host
            c.all = a.bool("all") ?? (host == nil)
            c.subscribed = true
            c.lastSessions = nil
            lock.unlock()
            if let host { c.release = hub.claim(host: host) }
            schedulePush(now: true)
            return ["ok": true]

        case "recordings":
            // A host chooses whether its own sessions are recorded, and where.
            // Until it does, they aren't.
            guard let host = a.string("host"), !host.isEmpty else { throw ToolError("recordings needs host: your host ID") }
            guard let dir = a.string("directory") else {
                hub.setRecordings(host: host, nil)
                return ["ok": true, "recording": false]
            }
            guard dir.hasPrefix("/") else { throw ToolError("directory must be an absolute path") }
            let url = URL(fileURLWithPath: dir, isDirectory: true).standardizedFileURL
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let limit = a.int("limit_mb") ?? Recordings.defaultLimitMB
            let days = a.int("retention_days") ?? Recordings.defaultRetentionDays
            // The same folder again (a reconnect, a new limit): keep recording into the runs under way.
            let store: Recordings
            if let current = hub.recordings(host: host), current.directory.standardizedFileURL == url {
                store = current
                store.retentionDays = days
                store.limitMB = limit
                store.maintain()
            } else {
                store = Recordings(directory: url, limitMB: limit, retentionDays: days)
                hub.setRecordings(host: host, store)
            }
            return ["ok": true, "recording": true, "directory": store.directory.path,
                    "limit_mb": store.limitMB, "retention_days": store.retentionDays]

        case "unsubscribe":
            lock.lock()
            c.subscribed = false
            let release = c.release
            c.release = nil
            lock.unlock()
            release?()
            return ["ok": true]

        case "sessions":
            let host = a.string("host")
            let all = a.bool("all") ?? (host == nil)
            let list = hub.engines.filter { all || $0.host == host }.map(sessionJSON)
            return ["ok": true, "engine": engineInfo(), "sessions": list]

        case "pause":
            try engine(a).setPaused(a.bool("paused") ?? true)
            return ["ok": true]

        case "stop":
            try engine(a).stopAll()
            return ["ok": true]

        case "take_over":
            let e = try engine(a)
            if a.bool("on") ?? true {
                guard e.display.isRunning else { throw ToolError("that session has no display yet") }
                lock.lock()
                let existing = c.remotes[e.sessionID]
                lock.unlock()
                if existing == nil {
                    let remote = makeRemote(e, c)
                    lock.lock(); c.remotes[e.sessionID] = remote; lock.unlock()
                }
                e.setUserInControl(true)
            } else {
                lock.lock()
                let remote = c.remotes.removeValue(forKey: e.sessionID)
                lock.unlock()
                remote?.end()
                e.setUserInControl(false)
            }
            return ["ok": true]

        case "hand_back":
            try engine(a).handBack()
            return ["ok": true]

        case "open_handoff":
            let e = try engine(a)
            guard e.handoffWindow != nil else { throw ToolError("that session hasn't handed a window off") }
            let area = try rect(a.raw["area"]) ?? DispatchQueue.main.sync { Self.screenUnderPointer() }
            e.bringHandoffToUser(area: area)
            return ["ok": true]

        case "frames":
            let e = try engine(a)
            lock.lock()
            nextStream += 1
            let s = Stream(id: nextStream, engine: e, maxWidth: a.int("max_width") ?? 1600, quality: a.double("quality") ?? 0.6)
            lock.unlock()
            let connection = c.connection
            s.frames = FrameStream(engine: e) { [weak s] image in
                guard let s, connection.backlog < 2 else { return }
                self.sendFrame(s, image, connection)
            }
            s.frames.window = CGWindowID(a.int("window") ?? 0)
            s.frames.excluded = CGWindowID(a.int("exclude") ?? 0)
            lock.lock(); c.streams[s.id] = s; lock.unlock()
            s.frames.start(fps: a.int("fps") ?? 15)
            return ["ok": true, "stream": s.id]

        case "frames_update":
            let s = try stream(a, c)
            if let w = a.int("window") { s.frames.window = CGWindowID(w) }
            if let x = a.int("exclude") { s.frames.excluded = CGWindowID(x) }
            if let m = a.int("max_width") { s.maxWidth = m }
            if let q = a.double("quality") { s.quality = q }
            if let fps = a.int("fps") { s.frames.start(fps: fps) }
            return ["ok": true]

        case "frames_stop":
            let s = try stream(a, c)
            s.frames.stop()
            lock.lock(); c.streams[s.id] = nil; lock.unlock()
            return ["ok": true]

        case "input":
            let e = try engine(a)
            lock.lock()
            let remote = c.remotes[e.sessionID]
            lock.unlock()
            guard let remote, e.userInControl else { throw ToolError("take over the session first (take_over)") }
            let events = (a.raw["events"] as? [JSONObject]) ?? [a.raw["event"] as? JSONObject].compactMap { $0 }
            for ev in events { try HostInput.post(Args(ev), to: remote, display: e.display) }
            return ["ok": true]

        case "menu_pick":
            let e = try engine(a)
            lock.lock()
            let remote = c.remotes[e.sessionID]
            lock.unlock()
            guard let remote else { throw ToolError("take over the session first (take_over)") }
            guard let token = a.int("token"), let path = a.raw["path"] as? [Int] else { throw ToolError("menu_pick needs token and path") }
            remote.chooseMenuItem(token: token, path: path)
            return ["ok": true]

        case "yield":
            DispatchQueue.main.async { self.onYield?() }
            return ["ok": true, "yielding": onYield != nil]

        default:
            throw ToolError("unknown op \(op)")
        }
    }

    private func engine(_ a: Args) throws -> Engine {
        guard let id = a.string("session") else { throw ToolError("missing session") }
        guard let e = hub.engine(id: id) else { throw ToolError("no session \(id)") }
        return e
    }

    private func stream(_ a: Args, _ c: Client) throws -> Stream {
        lock.lock(); defer { lock.unlock() }
        guard let id = a.int("stream"), let s = c.streams[id] else { throw ToolError("no such stream") }
        return s
    }

    private func rect(_ v: Any?) throws -> CGRect? {
        guard let v else { return nil }
        guard let o = v as? JSONObject, let x = (o["x"] as? NSNumber)?.doubleValue, let y = (o["y"] as? NSNumber)?.doubleValue,
              let w = (o["width"] as? NSNumber)?.doubleValue, let h = (o["height"] as? NSNumber)?.doubleValue else {
            throw ToolError("area needs x, y, width and height (global points, top-left origin)")
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// The visible part of the screen under the pointer, in global points
    /// with a top-left origin. Main thread.
    static func screenUnderPointer() -> CGRect {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main,
              let primary = NSScreen.screens.first else { return .zero }
        let f = screen.visibleFrame
        return CGRect(x: f.minX, y: primary.frame.maxY - f.maxY, width: f.width, height: f.height)
    }

    // MARK: Take-over

    private func makeRemote(_ e: Engine, _ c: Client) -> RemoteControl {
        let remote = RemoteControl(engine: e)
        let connection = c.connection
        let session = e.sessionID
        remote.onCursor = { cur in
            connection.send(["event": "cursor", "session": session, "css": Self.css(cur)])
        }
        remote.onMenu = { m in
            let o = Self.local(m.origin, e)
            connection.send(["event": "menu", "session": session, "token": m.token, "x": o.x, "y": o.y,
                             "entries": m.entries.map(Self.menuJSON)])
        }
        remote.onDrag = { d in
            switch d {
            case .began(let v):
                var kind: JSONObject = ["type": "move"]
                if case .resize(let edges) = v.kind { kind = ["type": "resize", "edges": Self.edgeNames(edges)] }
                connection.send(["event": "drag", "session": session, "phase": "began", "window": Int(v.windowID),
                                 "kind": kind, "frame": Self.rectJSON(v.start, e), "press": Self.pointJSON(v.pressPoint, e)])
            case .ended(let id, let frame):
                connection.send(["event": "drag", "session": session, "phase": "ended", "window": Int(id),
                                 "frame": Self.rectJSON(frame, e)])
            }
        }
        return remote
    }

    static func css(_ c: RemoteControl.Cursor) -> String {
        switch c {
        case .arrow: return "default"
        case .pointingHand: return "pointer"
        case .iBeam: return "text"
        case .resize(let e):
            let v = e.contains(.top) || e.contains(.bottom), h = e.contains(.left) || e.contains(.right)
            if v && h { return (e.contains(.top) == e.contains(.left)) ? "nwse-resize" : "nesw-resize" }
            return h ? "ew-resize" : "ns-resize"
        }
    }

    static func edgeNames(_ e: RemoteControl.Edges) -> [String] {
        var out: [String] = []
        if e.contains(.left) { out.append("left") }
        if e.contains(.right) { out.append("right") }
        if e.contains(.top) { out.append("top") }
        if e.contains(.bottom) { out.append("bottom") }
        return out
    }

    static func menuJSON(_ m: RemoteControl.MenuEntry) -> JSONObject {
        var o: JSONObject = ["title": m.title, "enabled": m.enabled, "checked": m.checked, "separator": m.separator]
        if !m.children.isEmpty { o["children"] = m.children.map(menuJSON) }
        return o
    }

    // MARK: State

    private func engineInfo() -> JSONObject {
        [
            "protocol": Self.protocolVersion,
            "version": version,
            "owner": ownerName,
            "pid": Int(getpid()),
            "permissions": ["accessibility": AX.isTrusted, "screen_recording": Capture.hasPermission],
            "max_displays": AgentDisplay.maxDisplays,
            "display": ["width": AgentDisplay.defaultWidth, "height": AgentDisplay.defaultHeight],
        ]
    }

    static func local(_ p: CGPoint, _ e: Engine) -> CGPoint {
        let o = e.display.bounds.origin
        return CGPoint(x: p.x - o.x, y: p.y - o.y)
    }

    static func pointJSON(_ p: CGPoint, _ e: Engine) -> JSONObject {
        let l = local(p, e)
        return ["x": l.x, "y": l.y]
    }

    static func rectJSON(_ r: CGRect, _ e: Engine) -> JSONObject {
        let l = local(r.origin, e)
        return ["x": l.x, "y": l.y, "width": r.width, "height": r.height]
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func sessionJSON(_ e: Engine) -> JSONObject {
        var status: JSONObject
        switch e.status {
        case .idle: status = ["state": "idle", "text": "Idle"]
        case .working(let t): status = ["state": "working", "text": t]
        case .waiting(let t): status = ["state": "waiting", "text": t]
        case .paused: status = ["state": "paused", "text": "Paused"]
        case .userInControl: status = ["state": "user_in_control", "text": "You're in control"]
        }
        let running = e.display.isRunning
        let windows: [JSONObject] = e.windows.windows.map { w in
            var o: JSONObject = ["id": Int(w.id), "app": w.appName, "pid": Int(w.pid), "kind": w.kind.rawValue,
                                 "handed_off": w.handedOff, "with_user": w.withUser]
            if let b = w.bundleID { o["bundle_id"] = b }
            if let r = w.handoffReason { o["handoff_reason"] = r }
            if running, !w.withUser, let b = WindowList.info(w.id)?.bounds { o["frame"] = Self.rectJSON(b, e) }
            return o
        }
        var o: JSONObject = [
            "id": e.sessionID,
            "label": e.label,
            "status": status,
            "active": e.isActive,
            "paused": e.paused,
            "user_in_control": e.userInControl,
            "windows": windows,
            "activity": e.activity.suffix(20).map { ["time": Self.iso.string(from: $0.time), "text": $0.text, "error": $0.isError] },
        ]
        if let h = e.host { o["host"] = h }
        if let p = hub.parent(of: e.sessionID) { o["parent"] = p }
        if running { o["display"] = ["width": e.display.width, "height": e.display.height] }
        if let w = e.handoffWindow {
            var h: JSONObject = ["window": Int(w.id), "app": w.appName, "with_user": w.withUser]
            if let r = w.handoffReason { h["reason"] = r }
            o["handoff"] = h
        }
        if running, let p = e.lastPointer { o["pointer"] = Self.pointJSON(p, e) }
        return o
    }

    /// Coalesces changes: at most one `sessions` push per client every 50 ms,
    /// and only when something in it changed.
    private func schedulePush(now: Bool = false) {
        lock.lock()
        if pushScheduled { lock.unlock(); return }
        pushScheduled = true
        lock.unlock()
        pushQueue.asyncAfter(deadline: .now() + (now ? 0 : 0.05)) { [weak self] in self?.push() }
    }

    private func push() {
        lock.lock()
        pushScheduled = false
        let targets = clients.values.filter(\.subscribed)
        lock.unlock()
        guard !targets.isEmpty else { return }
        let engines = hub.engines
        let info = engineInfo()
        var json: [String: JSONObject] = [:]
        for e in engines where targets.contains(where: { $0.shows(e) }) { json[e.sessionID] = sessionJSON(e) }
        for c in targets {
            let list = engines.filter(c.shows).compactMap { json[$0.sessionID] }
            let line = WireCodec.encodeLine(["event": "sessions", "engine": info, "sessions": list])
            lock.lock()
            let same = c.lastSessions == line
            if !same { c.lastSessions = line }
            lock.unlock()
            if !same { c.connection.send(line) }
        }
    }

    private func sendPointer(_ e: Engine, _ p: AgentPointer) {
        lock.lock()
        let targets = clients.values.filter { $0.subscribed && $0.shows(e) }
        lock.unlock()
        guard !targets.isEmpty else { return }
        var o: JSONObject = ["event": "pointer", "session": e.sessionID]
        let l = Self.local(p.point, e)
        o["x"] = l.x
        o["y"] = l.y
        switch p.kind {
        case .move: o["kind"] = "move"
        case .click: o["kind"] = "click"
        case .drag(let to): o["kind"] = "drag"; o["to"] = Self.pointJSON(to, e)
        }
        for c in targets { c.connection.send(o) }
    }

    private func sendFrame(_ s: Stream, _ image: CGImage, _ connection: SocketConnection) {
        guard let jpeg = FrameStream.jpeg(image, maxWidth: s.maxWidth, quality: s.quality) else { return }
        s.seq += 1
        var o: JSONObject = ["event": "frame", "stream": s.id, "session": s.engine.sessionID, "seq": s.seq,
                             "mime": "image/jpeg", "data": jpeg.base64EncodedString()]
        let window = s.frames.window
        if window != 0 {
            o["window"] = Int(window)
        } else {
            o["display"] = ["width": s.engine.display.width, "height": s.engine.display.height]
        }
        connection.send(o)
    }
}

/// Take-over input from a host app, in DOM terms (what a web view gets),
/// turned into the events `RemoteControl` posts to the agent's windows.
enum HostInput {
    static func post(_ a: Args, to remote: RemoteControl, display: AgentDisplay) throws {
        let type = a.string("type") ?? ""
        let b = display.bounds
        let flags = KeyMap.flags(modifiers(a))
        func point(clamp: Bool) throws -> CGPoint {
            guard var x = a.double("x"), var y = a.double("y") else { throw ToolError("\(type) needs x and y") }
            if clamp {
                x = min(max(x, 0), b.width - 0.01)
                y = min(max(y, 0), b.height - 0.01)
            }
            return CGPoint(x: b.minX + x, y: b.minY + y)
        }
        // DOM buttons: 0 left, 1 middle, 2 right. CG: 0 left, 1 right, 2 other.
        let button: Int64 = [0: 0, 1: 2, 2: 1][a.int("button") ?? 0] ?? 0
        let clicks = max(1, a.int("clicks") ?? 1)
        switch type {
        case "mousedown":
            let t: CGEventType = button == 0 ? .leftMouseDown : button == 1 ? .rightMouseDown : .otherMouseDown
            remote.mouse(t, at: try point(clamp: false), button: button, clickCount: clicks, flags: flags)
        case "mouseup":
            let t: CGEventType = button == 0 ? .leftMouseUp : button == 1 ? .rightMouseUp : .otherMouseUp
            remote.mouse(t, at: try point(clamp: true), button: button, clickCount: clicks, flags: flags)
        case "mousemove":
            // DOM `buttons`: 1 left, 2 right, 4 middle.
            let held = a.int("buttons") ?? 0
            if held & 1 != 0 {
                remote.mouse(.leftMouseDragged, at: try point(clamp: true), button: 0, clickCount: 1, flags: flags)
            } else if held & 2 != 0 {
                remote.mouse(.rightMouseDragged, at: try point(clamp: true), button: 1, clickCount: 1, flags: flags)
            } else if held & 4 != 0 {
                remote.mouse(.otherMouseDragged, at: try point(clamp: true), button: 2, clickCount: 1, flags: flags)
            } else {
                let p = try point(clamp: false)
                remote.mouse(.mouseMoved, at: p, button: 0, clickCount: 1, flags: flags)
                remote.hover(p)
            }
        case "scroll":
            // DOM deltas in pixels: positive y scrolls down, positive x right.
            let dx = Int32((a.double("dx") ?? 0).rounded()), dy = Int32((a.double("dy") ?? 0).rounded())
            guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -dy, wheel2: -dx, wheel3: 0) else { return }
            e.flags = flags
            remote.scroll(e, at: try point(clamp: false))
        case "keydown", "keyup":
            let down = type == "keydown"
            let code = a.string("code") ?? ""
            let key = a.string("key") ?? ""
            guard let keyCode = keyCode(code: code, key: key) else { throw ToolError("unknown key code \(code)") }
            // cmd+Q would quit the whole app, the user's own windows included.
            if flags.contains(.maskCommand) && keyCode == 12 { return }
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else { return }
            if modifierCodes.contains(keyCode) {
                e.type = .flagsChanged
            } else if key.count == 1 {
                let units = Array(key.utf16)
                e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
            e.flags = flags
            if a.bool("repeat") == true { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            remote.key(e)
        default:
            throw ToolError("unknown input type \(type)")
        }
    }

    /// `modifiers` as a list (["shift", "meta"]) or the DOM booleans
    /// (shiftKey, ctrlKey, altKey, metaKey).
    static func modifiers(_ a: Args) -> [String] {
        if let list = a.raw["modifiers"] as? [String] { return list }
        var out: [String] = []
        if a.bool("shiftKey") == true { out.append("shift") }
        if a.bool("ctrlKey") == true { out.append("ctrl") }
        if a.bool("altKey") == true { out.append("alt") }
        if a.bool("metaKey") == true { out.append("cmd") }
        return out
    }

    static let modifierCodes: Set<CGKeyCode> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    /// DOM `KeyboardEvent.code` (the physical key) to a Mac virtual key code.
    static let codes: [String: CGKeyCode] = [
        "Enter": 36, "Tab": 48, "Space": 49, "Backspace": 51, "Escape": 53, "Delete": 117,
        "Home": 115, "End": 119, "PageUp": 116, "PageDown": 121, "Insert": 114, "Help": 114,
        "ArrowLeft": 123, "ArrowRight": 124, "ArrowDown": 125, "ArrowUp": 126,
        "F1": 122, "F2": 120, "F3": 99, "F4": 118, "F5": 96, "F6": 97, "F7": 98, "F8": 100,
        "F9": 101, "F10": 109, "F11": 103, "F12": 111, "F13": 105, "F14": 107, "F15": 113,
        "F16": 106, "F17": 64, "F18": 79, "F19": 80, "F20": 90,
        "MetaRight": 54, "MetaLeft": 55, "ShiftLeft": 56, "CapsLock": 57, "AltLeft": 58,
        "ControlLeft": 59, "ShiftRight": 60, "AltRight": 61, "ControlRight": 62, "Fn": 63,
        "Minus": 27, "Equal": 24, "BracketLeft": 33, "BracketRight": 30, "Backslash": 42,
        "Semicolon": 41, "Quote": 39, "Comma": 43, "Period": 47, "Slash": 44, "Backquote": 50,
        "IntlBackslash": 10, "ContextMenu": 110,
        "Numpad0": 82, "Numpad1": 83, "Numpad2": 84, "Numpad3": 85, "Numpad4": 86, "Numpad5": 87,
        "Numpad6": 88, "Numpad7": 89, "Numpad8": 91, "Numpad9": 92, "NumpadDecimal": 65,
        "NumpadMultiply": 67, "NumpadAdd": 69, "NumpadSubtract": 78, "NumpadDivide": 75,
        "NumpadEnter": 76, "NumpadEqual": 81, "NumLock": 71,
    ]

    static func keyCode(code: String, key: String) -> CGKeyCode? {
        if let c = codes[code] { return c }
        if code.hasPrefix("Key"), code.count == 4, let ch = code.last, let c = KeyMap.chars[Character(ch.lowercased())] { return c }
        if code.hasPrefix("Digit"), code.count == 6, let ch = code.last, let c = KeyMap.chars[ch] { return c }
        return try? KeyMap.code(for: key).0
    }
}
