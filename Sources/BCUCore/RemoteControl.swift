import AppKit
import CPrivate

/// The user driving the agent display from the expanded view, like a VNC
/// client. Mouse and key events from the preview are posted to the window
/// under the pointer on the agent display, the same way the agent's own
/// input is: per process, without moving the real cursor or activating the app.
public final class RemoteControl {
    private let engine: Engine
    private let queue = DispatchQueue(label: "bcu.remote", qos: .userInteractive)

    /// Keeps the window the user last clicked as its app's key window, so
    /// typed keys land in it. Released after a pause in input.
    private var scope: KeyScope?
    private var idleRelease: DispatchWorkItem?
    private var keyTarget: WindowInfo?
    /// What a press does: goes to the app, or moves or resizes the window.
    /// Moving and resizing are done here through accessibility: if the press
    /// went to the app, the window server would run the drag against the
    /// user's real cursor, which is on their own screen, and carry the window away.
    private enum Mode: Equatable {
        case forward
        case drag(DragKind)
    }

    public enum DragKind: Equatable {
        case move
        case resize(Edges)
    }

    public struct Edges: OptionSet, Equatable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let left = Edges(rawValue: 1)
        public static let right = Edges(rawValue: 2)
        public static let top = Edges(rawValue: 4)
        public static let bottom = Edges(rawValue: 8)
    }

    /// A window drag, for the preview to draw. A window moved or resized
    /// through accessibility shows on screen about 100 ms later, so the
    /// preview draws where it is going right away.
    public struct DragVisual {
        public let windowID: CGWindowID
        public let kind: DragKind
        /// The window's frame when the drag started, in global points.
        public let start: CGRect
        public let pressPoint: CGPoint
        /// What the window looked like, for a move.
        public let snapshot: CGImage?
    }

    public enum DragEvent {
        case began(DragVisual)
        case ended(CGWindowID, CGRect)
    }

    /// Called on the main thread.
    public var onDrag: ((DragEvent) -> Void)?

    /// The pointer shape the window under the pointer would show.
    public enum Cursor: Equatable {
        case arrow, pointingHand, iBeam
        case resize(Edges)
    }

    /// Called on the main thread when the shape under the pointer changes.
    public var onCursor: ((Cursor) -> Void)?
    private let hoverQueue = DispatchQueue(label: "bcu.remote.hover", qos: .userInitiated)
    private let hoverLock = NSLock()
    private var latestHover: CGPoint?
    private var hoverQueued = false
    private var lastCursor: Cursor = .arrow

    /// The agent display's menu bar, which a window's top can't go above.
    static let menuBarHeight: CGFloat = 30
    /// How much of a window has to stay on the display when it's dragged off an edge.
    static let keepVisible: CGFloat = 80

    /// Where a window dragged from `from` to `to` ends up. Like macOS, it can
    /// hang off the left, right and bottom edges (nothing on the user's
    /// screens borders those), but its top stays below the menu bar.
    public static func dragFrame(_ kind: DragKind, start f: CGRect, from: CGPoint, to: CGPoint, display b: CGRect) -> CGRect {
        let dx = to.x - from.x, dy = to.y - from.y
        let top = b.minY + menuBarHeight
        switch kind {
        case .move:
            let keep = min(keepVisible, f.width, f.height)
            let x = min(max(f.minX + dx, b.minX - f.width + keep), b.maxX - keep)
            let y = min(max(f.minY + dy, top), b.maxY - keep)
            return CGRect(x: x, y: y, width: f.width, height: f.height)
        case .resize(let e):
            let minW: CGFloat = 240, minH: CGFloat = 160
            var minX = f.minX, maxX = f.maxX, minY = f.minY, maxY = f.maxY
            if e.contains(.left) { minX = min(max(minX + dx, b.minX), maxX - minW) }
            if e.contains(.right) { maxX = max(min(maxX + dx, b.maxX), minX + minW) }
            if e.contains(.top) { minY = min(max(minY + dy, top), maxY - minH) }
            if e.contains(.bottom) { maxY = max(min(maxY + dy, b.maxY), minY + minH) }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    /// A button press. A click goes to the app whole on release, so the
    /// user's real button is up by then. A drag starts once the pointer has
    /// moved a few points.
    private struct Press {
        let type: CGEventType
        let point: CGPoint
        let button: Int64
        let clickCount: Int
        let flags: CGEventFlags
        let window: WindowInfo
        /// The window's frame when the press started.
        let frame: CGRect
        var mode: Mode
        var dragging = false
        /// The mouseDown has gone to the app.
        var sent = false
        var ax: AXUIElement?
        /// The app's menus already open when the press started.
        var menusBefore: Set<CGWindowID> = []
    }
    private var press: Press?
    private static let dragThreshold: CGFloat = 4
    /// Drags arrive faster than a window can be moved or resized; only the latest is used.
    private let dragLock = NSLock()
    private var latestDrag: (type: CGEventType, point: CGPoint, flags: CGEventFlags)?
    private var dragQueued = false
    private var clickGroup: Int64 = 0
    private var cache: (ms: Double, windows: [WindowInfo]) = (0, [])
    private var lastMove: CGPoint?

    private static let releaseAfterMs = 1500

    public init(engine: Engine) {
        self.engine = engine
    }

    // MARK: Mouse

    /// A mouse event at a global point on the agent display.
    public func mouse(_ type: CGEventType, at point: CGPoint, button: Int64, clickCount: Int, flags: CGEventFlags) {
        if type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged {
            dragLock.lock()
            latestDrag = (type, point, flags)
            let schedule = !dragQueued
            dragQueued = true
            dragLock.unlock()
            guard schedule else { return }
            queue.async {
                self.dragLock.lock()
                let d = self.latestDrag
                self.latestDrag = nil
                self.dragQueued = false
                self.dragLock.unlock()
                if let d { self.postMouse(d.type, at: d.point, button: button, clickCount: 1, flags: d.flags) }
            }
            return
        }
        queue.async { self.postMouse(type, at: point, button: button, clickCount: clickCount, flags: flags) }
    }

    /// A scroll event (copied from the user's own, so trackpad phases and
    /// momentum carry over) at a global point on the agent display.
    public func scroll(_ event: CGEvent, at point: CGPoint) {
        guard let e = event.copy() else { return }
        queue.async {
            guard let w = self.window(at: point) else { return }
            // Chromium scrolls whatever the pointer last moved over.
            if self.lastMove != point {
                self.post(.mouseMoved, w, point, phase: 2, state: 0, button: 0, flags: [])
                self.lastMove = point
            }
            e.location = point
            BCUEventSetIntegerField(e, 40, Int64(w.pid))
            BCUEventSetIntegerField(e, 51, Int64(w.id))
            BCUEventSetIntegerField(e, 91, Int64(w.id))
            BCUEventSetIntegerField(e, 92, Int64(w.id))
            // Chromium ignores wheel events without the point inside the target window.
            BCUEventSetWindowLocation(e, CGPoint(x: point.x - w.bounds.minX, y: point.y - w.bounds.minY))
            BCUPostEventToPid(w.pid, e, false)
        }
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint, button: Int64, clickCount: Int, flags: CGEventFlags) {
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // A press whose release never came would otherwise block every later click.
            if let stale = press {
                engine.focusGuard.endAction(pid: stale.window.pid)
                press = nil
            }
            guard let (w, mode) = target(at: point, button: button) else { return }
            clickGroup = Int64(DispatchTime.now().uptimeNanoseconds & 0x7fff_ffff)
            // Popups (menus, suggestion lists) aren't key windows; keys keep
            // going to the window that opened them.
            if w.layer == 0 { makeKey(w) }
            // The user is in the viewer, so any app the click brings forward goes back.
            engine.focusGuard.beginAction(pid: w.pid, cause: "your click in the expanded view", strict: true)
            Log.info("remote: press button \(button) count \(clickCount) on \(w.owner) window \(w.id) at \(Int(point.x - w.bounds.minX)),\(Int(point.y - w.bounds.minY)) mode \(mode)")
            press = Press(type: type, point: point, button: button, clickCount: clickCount, flags: flags, window: w,
                          frame: WindowList.info(w.id)?.bounds ?? w.bounds, mode: mode,
                          ax: mode == .forward ? nil : AX.window(pid: w.pid, id: w.id),
                          menusBefore: Set(Self.menuWindows(w.pid).map(\.id)))
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard var p = press else { return }
            if !p.dragging {
                guard hypot(point.x - p.point.x, point.y - p.point.y) >= Self.dragThreshold else { return }
                p.dragging = true
                if case .drag(let kind) = p.mode { beginDrag(p, kind) }
            }
            if p.mode == .forward {
                if !p.sent {
                    sendDown(p)
                    p.sent = true
                }
                post(type, p.window, point, phase: 3, state: 1, button: button, flags: flags)
                // Some apps hand drags in places this can't predict to the
                // window server, which moves the window by the real cursor.
                // From then on, move it here instead.
                if let now = WindowList.info(p.window.id), now.bounds.origin != p.frame.origin {
                    p.mode = .drag(.move)
                    p.ax = AX.window(pid: p.window.pid, id: p.window.id)
                    beginDrag(p, .move)
                }
            }
            apply(p, at: point)
            press = p
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard let p = press else { return }
            Log.info("remote: release button \(p.button) count \(p.clickCount) dragged \(p.dragging)")
            if !p.dragging {
                if p.button == 0, p.window.layer > 0, pressMenuItem(at: p.point, pid: p.window.pid) {
                    // pressed through accessibility
                } else if p.button == 1, showContextMenu(at: p.point, pid: p.window.pid) {
                    watchForMenu(pid: p.window.pid, before: p.menusBefore, opener: .showMenu(p.point, p.window.pid))
                } else {
                    sendDown(p)
                    post(type, p.window, p.point, phase: 3, state: Int64(p.clickCount), button: p.button, flags: flags)
                    watchForMenu(pid: p.window.pid, before: p.menusBefore, opener: .click(p))
                }
            } else {
                apply(p, at: point)
                if p.sent {
                    post(type, p.window, point, phase: 3, state: Int64(p.clickCount), button: p.button, flags: flags)
                }
                if case .drag(let kind) = p.mode {
                    let final = Self.dragFrame(kind, start: p.frame, from: p.point, to: point, display: engine.display.bounds)
                    let id = p.window.id
                    DispatchQueue.main.async { self.onDrag?(.ended(id, final)) }
                }
            }
            press = nil
            if p.mode != .forward {
                cache.ms = 0
                if p.dragging { engine.windows.noteUserPlaced(p.window.id) }
            }
            engine.focusGuard.endAction(pid: p.window.pid)
            scheduleRelease()
        case .mouseMoved:
            guard press == nil, let w = window(at: point) else { return }
            post(.mouseMoved, w, point, phase: 2, state: 0, button: 0, flags: flags)
            lastMove = point
        default:
            break
        }
    }

    private func beginDrag(_ p: Press, _ kind: DragKind) {
        let snapshot = kind == .move ? BCUCaptureWindow(p.window.id) : nil
        let visual = DragVisual(windowID: p.window.id, kind: kind, start: p.frame, pressPoint: p.point, snapshot: snapshot)
        DispatchQueue.main.async { self.onDrag?(.began(visual)) }
    }

    /// The window a press at `point` belongs to, and what it does there:
    /// near a window's edge it resizes, on its title bar (or the empty part
    /// of a tab strip or toolbar) a drag moves it, anywhere else it goes to the app.
    private func target(at point: CGPoint, button: Int64) -> (WindowInfo, Mode)? {
        guard engine.display.bounds.contains(point) else { return nil }
        let list = windows()
        if button == 0, let (w, edges) = resizeEdges(at: point, in: list) {
            return (w, .drag(.resize(edges)))
        }
        guard let w = list.first(where: { $0.bounds.contains(point) }) else { return nil }
        if button == 0, isTitleBar(w, point) { return (w, .drag(.move)) }
        return (w, .forward)
    }

    /// A resizable window whose edge is within a few points of `point`.
    private func resizeEdges(at point: CGPoint, in list: [WindowInfo]) -> (WindowInfo, Edges)? {
        for w in list where w.layer == 0 {
            let f = w.bounds
            guard f.insetBy(dx: -5, dy: -5).contains(point) else { continue }
            var edges: Edges = []
            if abs(point.x - f.minX) <= 5 { edges.insert(.left) }
            if abs(point.x - f.maxX) <= 5 { edges.insert(.right) }
            if abs(point.y - f.minY) <= 3 { edges.insert(.top) }
            if abs(point.y - f.maxY) <= 5 { edges.insert(.bottom) }
            if !edges.isEmpty, resizable(w) { return (w, edges) }
            if f.contains(point) { return nil }
        }
        return nil
    }

    private var resizableCache: [CGWindowID: Bool] = [:]
    private let resizableLock = NSLock()

    private func resizable(_ w: WindowInfo) -> Bool {
        resizableLock.lock()
        if let known = resizableCache[w.id] { resizableLock.unlock(); return known }
        resizableLock.unlock()
        let value = AX.window(pid: w.pid, id: w.id).map { AX.isSettable($0, "AXSize") } ?? false
        resizableLock.lock(); resizableCache[w.id] = value; resizableLock.unlock()
        return value
    }

    private static let titleBarRoles: Set<String> = ["AXWindow", "AXToolbar", "AXTabGroup", "AXGroup", "AXSplitGroup", "AXUnknown", "AXStaticText"]

    private func isTitleBar(_ w: WindowInfo, _ point: CGPoint) -> Bool {
        guard w.layer == 0, point.y - w.bounds.minY < 52, let el = AX.element(at: point, pid: w.pid) else { return false }
        return Self.titleBarRoles.contains(AX.string(el, "AXRole") ?? "")
    }

    /// Move or resize the window for a drag that has reached `point`.
    private func apply(_ p: Press, at point: CGPoint) {
        guard p.dragging, let ax = p.ax, case .drag(let kind) = p.mode else { return }
        let f = Self.dragFrame(kind, start: p.frame, from: p.point, to: point, display: engine.display.bounds)
        if f.origin != p.frame.origin { AX.setPosition(ax, f.origin) }
        if f.size != p.frame.size { AX.setSize(ax, f.size) }
    }

    // MARK: Pointer shape

    /// The pointer is over `point`: work out the shape the app would show
    /// there. The app can't set it itself, because the user's real pointer
    /// is over the preview, not its window.
    public func hover(_ point: CGPoint) {
        hoverLock.lock()
        latestHover = point
        let schedule = !hoverQueued
        hoverQueued = true
        hoverLock.unlock()
        guard schedule else { return }
        hoverQueue.async {
            self.hoverLock.lock()
            let p = self.latestHover
            self.latestHover = nil
            self.hoverQueued = false
            self.hoverLock.unlock()
            guard let p else { return }
            let c = self.cursor(at: p)
            guard c != self.lastCursor else { return }
            self.lastCursor = c
            DispatchQueue.main.async { self.onCursor?(c) }
        }
    }

    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]
    private static let controlRoles: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXDisclosureTriangle", "AXImage"]

    private func cursor(at point: CGPoint) -> Cursor {
        let list = Self.displayWindows(engine.display.bounds)
        if let (_, edges) = resizeEdges(at: point, in: list) { return .resize(edges) }
        guard let w = list.first(where: { $0.bounds.contains(point) }), let el = AX.element(at: point, pid: w.pid) else { return .arrow }
        let role = AX.string(el, "AXRole") ?? ""
        if Self.textRoles.contains(role) { return .iBeam }
        // Walk up: a link anywhere above means a pointing hand; a web area
        // means web content, where text shows an I-beam and controls a hand.
        var current: AXUIElement? = AX.element(el, "AXParent")
        var inLink = role == "AXLink", inWeb = role == "AXWebArea"
        var depth = 0
        while let e = current, depth < 14, !inWeb {
            let r = AX.string(e, "AXRole") ?? ""
            if r == "AXLink" { inLink = true }
            if r == "AXWebArea" { inWeb = true }
            if r == "AXWindow" { break }
            current = AX.element(e, "AXParent")
            depth += 1
        }
        if inLink { return .pointingHand }
        if inWeb {
            if role == "AXStaticText" { return .iBeam }
            if Self.controlRoles.contains(role) && role != "AXImage" { return .pointingHand }
        }
        return .arrow
    }

    /// Open the context menu of the element under a right click through
    /// accessibility (the action VoiceOver uses). A synthetic right click
    /// can open the menu too, but the app activates to show it, the focus
    /// guard puts the user's app back, and macOS closes the menu.
    private func showContextMenu(at point: CGPoint, pid: pid_t) -> Bool {
        var current = AX.element(at: point, pid: pid)
        for _ in 0..<6 {
            guard let el = current else { return false }
            if AX.actions(el).contains("AXShowMenu") {
                return AX.perform(el, "AXShowMenu") == .success
            }
            current = AX.element(el, "AXParent")
        }
        return false
    }

    // MARK: Menus

    /// A menu the app opened, mirrored in the preview. While an app's menu
    /// is open, macOS sends every real click to that menu, and the user's
    /// pointer is on their own screen, so the app's menu would close at the
    /// user's next click. So the app's menu is read and closed, the preview
    /// shows a native copy, and the chosen item is pressed in a reopened one.
    public struct MenuEntry {
        public let title: String
        public let enabled: Bool
        public let checked: Bool
        public let separator: Bool
        public let children: [MenuEntry]
    }

    public struct ProxyMenu {
        public let entries: [MenuEntry]
        /// The app menu's top left, in global points.
        public let origin: CGPoint
        public let token: Int
    }

    /// Called on the main thread when the app opened a menu.
    public var onMenu: ((ProxyMenu) -> Void)?

    private enum MenuOpener {
        case showMenu(CGPoint, pid_t)
        case click(Press)
    }

    private let menuQueue = DispatchQueue(label: "bcu.remote.menu", qos: .userInteractive)
    private var openers: [Int: MenuOpener] = [:]
    private var menuToken = 0
    /// The newest mirrored menu (tests).
    public var latestMenuToken: Int { menuQueue.sync { menuToken } }

    private static func menuWindows(_ pid: pid_t) -> [WindowInfo] {
        WindowList.of(pid: pid, onScreenOnly: true).filter { $0.layer >= 100 && $0.layer < 1000 }
    }

    private func watchForMenu(pid: pid_t, before: Set<CGWindowID>, opener: MenuOpener) {
        menuQueue.async {
            guard let (window, menu) = Self.waitForMenu(pid: pid, before: before, timeoutMs: 400) else { return }
            let entries = Self.readMenu(menu, depth: 0)
            guard !entries.isEmpty else { return }
            Self.closeMenu(menu, window: window.id, pid: pid)
            self.menuToken += 1
            let token = self.menuToken
            self.openers = [token: opener]
            let proxy = ProxyMenu(entries: entries, origin: window.bounds.origin, token: token)
            Log.info("remote: mirrored a \(entries.count)-item menu")
            DispatchQueue.main.async { self.onMenu?(proxy) }
        }
    }

    /// The user picked an item in a mirrored menu: open the app's menu again
    /// and press the item at `path` (indexes, through submenus).
    public func chooseMenuItem(token: Int, path: [Int]) {
        menuQueue.async {
            guard let opener = self.openers[token], !path.isEmpty else { return }
            let pid: pid_t
            switch opener {
            case .showMenu(_, let p): pid = p
            case .click(let press): pid = press.window.pid
            }
            let before = Set(Self.menuWindows(pid).map(\.id))
            self.queue.sync {
                switch opener {
                case .showMenu(let point, let pid): _ = self.showContextMenu(at: point, pid: pid)
                case .click(let p):
                    self.sendDown(p)
                    let up: CGEventType = p.button == 0 ? .leftMouseUp : p.button == 1 ? .rightMouseUp : .otherMouseUp
                    self.post(up, p.window, p.point, phase: 3, state: Int64(p.clickCount), button: p.button, flags: p.flags)
                }
            }
            guard let (_, root) = Self.waitForMenu(pid: pid, before: before, timeoutMs: 800) else {
                Log.info("remote: the menu didn't open again, so the choice wasn't made")
                return
            }
            var menu = root
            for (i, index) in path.enumerated() {
                let items = AX.children(menu).filter { AX.string($0, "AXRole") == "AXMenuItem" }
                guard index < items.count else { return }
                let item = items[index]
                if i == path.count - 1 {
                    let err = AX.perform(item, "AXPress")
                    Log.info("remote: chose \"\(AX.string(item, "AXTitle") ?? "")\" (\(AX.errorName(err)))")
                    return
                }
                guard let sub = Self.submenu(of: item) else { return }
                menu = sub
            }
        }
    }

    private static func waitForMenu(pid: pid_t, before: Set<CGWindowID>, timeoutMs: Double) -> (WindowInfo, AXUIElement)? {
        let deadline = nowMs() + timeoutMs
        while nowMs() < deadline {
            if let w = menuWindows(pid).first(where: { !before.contains($0.id) }) {
                // Find the menu element through the item under the window's middle.
                var current = AX.element(at: CGPoint(x: w.bounds.midX, y: w.bounds.minY + 12), pid: pid)
                for _ in 0..<4 {
                    guard let el = current else { break }
                    if AX.string(el, "AXRole") == "AXMenu" { return (w, el) }
                    current = AX.element(el, "AXParent")
                }
            }
            sleepMs(15)
        }
        return nil
    }

    /// An item's submenu, with its items. Apps fill a submenu in when it
    /// opens, so an empty one is opened first.
    private static func submenu(of item: AXUIElement) -> AXUIElement? {
        guard let sub = AX.children(item).first(where: { AX.string($0, "AXRole") == "AXMenu" }) else { return nil }
        func items() -> Int { AX.children(sub).filter { AX.string($0, "AXRole") == "AXMenuItem" }.count }
        if items() == 0 {
            AX.perform(item, "AXPress")
            let deadline = nowMs() + 300
            while items() == 0 && nowMs() < deadline { sleepMs(10) }
        }
        return sub
    }

    private static func readMenu(_ menu: AXUIElement, depth: Int) -> [MenuEntry] {
        AX.children(menu).filter { AX.string($0, "AXRole") == "AXMenuItem" }.map { item in
            let title = AX.string(item, "AXTitle") ?? ""
            let mark = AX.string(item, "AXMenuItemMarkChar") ?? ""
            var children: [MenuEntry] = []
            if depth < 3, let sub = submenu(of: item) {
                children = readMenu(sub, depth: depth + 1)
            }
            return MenuEntry(title: title, enabled: AX.bool(item, "AXEnabled") ?? true, checked: !mark.isEmpty,
                             separator: title.isEmpty && children.isEmpty, children: children)
        }
    }

    private static func closeMenu(_ menu: AXUIElement, window: CGWindowID, pid: pid_t) {
        if let first = AX.children(menu).first { AX.perform(first, "AXCancel") }
        let deadline = nowMs() + 200
        while WindowList.info(window).map({ $0.onScreen }) == true && nowMs() < deadline { sleepMs(10) }
        if WindowList.info(window).map({ $0.onScreen }) == true {
            try? Input.pressKey(pid: pid, key: "escape", modifiers: [])
        }
    }

    /// A click on an open menu: press the item through accessibility, which
    /// works however the app tracks its menus.
    private func pressMenuItem(at point: CGPoint, pid: pid_t) -> Bool {
        guard let el = AX.element(at: point, pid: pid), AX.string(el, "AXRole") == "AXMenuItem" else { return false }
        if AX.bool(el, "AXEnabled") == false { return true }
        return AX.perform(el, "AXPress") == .success
    }

    private func sendDown(_ p: Press) {
        // AppKit ignores a mouseDown on a background window without a move first.
        post(.mouseMoved, p.window, p.point, phase: 2, state: 0, button: 0, flags: p.flags)
        sleepMs(10)
        if p.button != 0 {
            // Chromium opens a context menu only after a click has opened its
            // user-activation gate: an off-screen left click, harmless elsewhere.
            let off = CGPoint(x: -1, y: -1)
            post(.leftMouseDown, p.window, off, phase: 1, state: 1, button: 0, flags: [])
            sleepMs(1)
            post(.leftMouseUp, p.window, off, phase: 2, state: 1, button: 0, flags: [])
            sleepMs(40)
        }
        post(p.type, p.window, p.point, phase: 3, state: Int64(p.clickCount), button: p.button, flags: p.flags)
    }

    private func post(_ type: CGEventType, _ w: WindowInfo, _ point: CGPoint, phase: Int64, state: Int64, button: Int64, flags: CGEventFlags) {
        let cgButton: CGMouseButton = button == 0 ? .left : button == 1 ? .right : .center
        guard let src = CGEventSource(stateID: .hidSystemState),
              let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: point, mouseButton: cgButton) else { return }
        Input.stampMouse(e, pid: w.pid, windowID: w.id, phase: phase, clickState: state, button: button,
                         group: type == .mouseMoved ? 0 : clickGroup, location: point)
        e.flags = flags
        BCUPostEventToPid(w.pid, e, false)
    }

    // MARK: Keyboard

    /// A key event from the user, sent to the window they last clicked (or
    /// the front window on the agent display).
    public func key(_ event: CGEvent) {
        guard let e = event.copy() else { return }
        queue.async {
            guard let w = self.keyTarget ?? self.frontWindow() else { return }
            self.makeKey(w)
            // A shortcut like cmd+N can make the app bring itself forward; undo that.
            self.engine.focusGuard.beginAction(pid: w.pid, cause: "your keys in the expanded view", strict: true)
            // Menu shortcuts only reach NSMenu without the authentication message.
            let menu = e.flags.contains(.maskCommand) || e.flags.contains(.maskControl)
            BCUPostEventToPid(w.pid, e, !menu)
            self.engine.focusGuard.endAction(pid: w.pid)
            self.scheduleRelease()
        }
    }

    // MARK: Key window

    private func makeKey(_ w: WindowInfo) {
        idleRelease?.cancel()
        if let scope, scope.target == w.id, keyTarget?.id == w.id { return }
        scope?.exit()
        scope = try? KeyScope.enter(pid: w.pid, window: w.id)
        keyTarget = w
    }

    /// Give key back inside the app once the user stops, so their own window
    /// in that app is key again if they switch to it.
    private func scheduleRelease() {
        idleRelease?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.press == nil else { return }
            // Giving key back closes an open menu; wait until the user is done with it.
            if let pid = self.scope?.pid,
               WindowList.of(pid: pid, onScreenOnly: true).contains(where: { $0.layer >= 100 && $0.layer < 1000 }) {
                self.scheduleRelease()
                return
            }
            self.scope?.exit()
            self.scope = nil
        }
        idleRelease = item
        queue.asyncAfter(deadline: .now() + .milliseconds(Self.releaseAfterMs), execute: item)
    }

    /// Wait for queued input to be posted (tests).
    public func flush() { queue.sync {} }

    /// Stop: give key back and forget targets.
    public func end() {
        queue.async {
            self.idleRelease?.cancel()
            if let p = self.press { self.engine.focusGuard.endAction(pid: p.window.pid) }
            self.scope?.exit()
            self.scope = nil
            self.keyTarget = nil
            self.press = nil
        }
    }

    // MARK: Windows

    /// The front window under a point on the agent display, matching what the preview draws.
    public func window(at point: CGPoint) -> WindowInfo? {
        // A window on the user's screen can reach the agent display's edge; never send it anything.
        guard engine.display.bounds.contains(point) else { return nil }
        return windows().first { $0.bounds.contains(point) }
    }

    private func frontWindow() -> WindowInfo? {
        windows().first { $0.layer == 0 }
    }

    private func windows() -> [WindowInfo] {
        let now = nowMs()
        if now - cache.ms < 60 { return cache.windows }
        let list = Self.displayWindows(engine.display.bounds)
        cache = (now, list)
        return list
    }

    /// Windows on the agent display that take input, front to back.
    private static func displayWindows(_ b: CGRect) -> [WindowInfo] {
        let skipOwners: Set<String> = ["Window Server", "Dock", "Control Center", "SystemUIServer", "Notification Center"]
        return WindowList.all(onScreenOnly: true).filter {
            b.intersects($0.bounds) && $0.alpha > 0 && $0.bounds.width > 2 && $0.bounds.height > 2
                && !skipOwners.contains($0.owner) && $0.layer != 24 && $0.layer != 25 && $0.pid != getpid()
        }
    }
}
