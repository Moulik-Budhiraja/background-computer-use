import AppKit
import SwiftUI
import BCUCore

/// Sits over the expanded preview. Before take-over, a click on the preview
/// asks to take over. While the user is in control, mouse and key events on
/// it are mapped to the agent display and sent to the window there.
struct RemoteSurface: NSViewRepresentable {
    @ObservedObject var model: PopoverModel
    let remote: RemoteControl

    func makeNSView(context: Context) -> RemoteControlView {
        let v = RemoteControlView()
        v.remote = remote
        v.display = model.engine.display
        v.onRequestControl = { [weak model] in model?.askingControl = true }
        v.onDragPoint = { [weak model] p in model?.onDragPoint?(p) }
        model.remoteView = v
        return v
    }

    func updateNSView(_ v: RemoteControlView, context: Context) {
        v.controlling = model.controlling
        if model.controlling {
            DispatchQueue.main.async {
                if v.window?.firstResponder !== v { v.window?.makeFirstResponder(v) }
            }
        }
    }
}

final class RemoteControlView: NSView {
    var remote: RemoteControl!
    var display: AgentDisplay!
    var onRequestControl: () -> Void = {}
    var onDragPoint: (CGPoint) -> Void = { _ in }
    var controlling = false {
        didSet { if !controlling { remoteCursor = .arrow } }
    }
    private var tracking: NSTrackingArea?
    /// The shape the app under the pointer would show.
    private var remoteCursor: NSCursor = .arrow

    func setRemoteCursor(_ c: RemoteControl.Cursor) {
        remoteCursor = Self.nsCursor(c)
        guard controlling, let window, window.isVisible else { return }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if bounds.contains(p) { remoteCursor.set() }
    }

    override func cursorUpdate(with event: NSEvent) {
        if controlling { remoteCursor.set() } else { super.cursorUpdate(with: event) }
    }

    private static func nsCursor(_ c: RemoteControl.Cursor) -> NSCursor {
        switch c {
        case .arrow: return .arrow
        case .pointingHand: return .pointingHand
        case .iBeam: return .iBeam
        case .resize(let e):
            if #available(macOS 15.0, *) {
                let position: NSCursor.FrameResizePosition
                switch (e.contains(.top), e.contains(.bottom), e.contains(.left), e.contains(.right)) {
                case (true, _, true, _): position = .topLeft
                case (true, _, _, true): position = .topRight
                case (_, true, true, _): position = .bottomLeft
                case (_, true, _, true): position = .bottomRight
                case (true, _, _, _): position = .top
                case (_, true, _, _): position = .bottom
                case (_, _, true, _): position = .left
                default: position = .right
                }
                return .frameResize(position: position, directions: .all)
            }
            return e.contains(.left) || e.contains(.right) ? .resizeLeftRight : .resizeUpDown
        }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { controlling }
    // The click that brings the panel back to key also goes through.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // activeAlways: the panel never activates this app.
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    /// Where the preview image is drawn: the display's aspect ratio fitted into the view.
    private var imageRect: CGRect {
        let b = display.bounds
        guard b.width > 0, b.height > 0 else { return .zero }
        let s = min(bounds.width / b.width, bounds.height / b.height)
        let w = b.width * s, h = b.height * s
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    /// The global point on the agent display under the event, or nil outside
    /// the image. Drags and releases are clamped so they finish inside.
    private func agentPoint(_ event: NSEvent, clamp: Bool = false) -> CGPoint? {
        let p = convert(event.locationInWindow, from: nil)
        let r = imageRect
        guard r.width > 0 else { return nil }
        var fx = (p.x - r.minX) / r.width
        var fy = (p.y - r.minY) / r.height
        if clamp {
            fx = min(max(fx, 0), 0.9999)
            fy = min(max(fy, 0), 0.9999)
        } else if fx < 0 || fx >= 1 || fy < 0 || fy >= 1 {
            return nil
        }
        let b = display.bounds
        return CGPoint(x: b.minX + fx * b.width, y: b.minY + fy * b.height)
    }

    private func send(_ type: CGEventType, _ event: NSEvent, clamp: Bool = false) {
        guard controlling, let p = agentPoint(event, clamp: clamp) else { return }
        remote.mouse(type, at: p, button: Int64(event.buttonNumber), clickCount: max(1, event.clickCount),
                     flags: event.cgEvent?.flags ?? [])
    }

    override func mouseDown(with event: NSEvent) {
        guard controlling else {
            if agentPoint(event) != nil { onRequestControl() }
            return
        }
        window?.makeFirstResponder(self)
        send(.leftMouseDown, event)
    }
    override func mouseDragged(with event: NSEvent) {
        send(.leftMouseDragged, event, clamp: true)
        if controlling, let p = agentPoint(event, clamp: true) { onDragPoint(p) }
    }
    override func mouseUp(with event: NSEvent) { send(.leftMouseUp, event, clamp: true) }

    override func rightMouseDown(with event: NSEvent) {
        guard controlling else { return }
        window?.makeFirstResponder(self)
        send(.rightMouseDown, event)
    }
    override func rightMouseDragged(with event: NSEvent) { send(.rightMouseDragged, event, clamp: true) }
    override func rightMouseUp(with event: NSEvent) { send(.rightMouseUp, event, clamp: true) }

    override func otherMouseDown(with event: NSEvent) { send(.otherMouseDown, event) }
    override func otherMouseDragged(with event: NSEvent) { send(.otherMouseDragged, event, clamp: true) }
    override func otherMouseUp(with event: NSEvent) { send(.otherMouseUp, event, clamp: true) }

    override func mouseMoved(with event: NSEvent) {
        send(.mouseMoved, event)
        if controlling, let p = agentPoint(event) {
            remote.hover(p)
            remoteCursor.set()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard controlling, let p = agentPoint(event), let cg = event.cgEvent else { return }
        remote.scroll(cg, at: p)
    }

    // MARK: Mirrored menus

    private struct MenuPick {
        let token: Int
        let path: [Int]
    }

    /// Show a native copy of a menu the app opened, where the app put it.
    func showProxyMenu(_ m: RemoteControl.ProxyMenu) {
        guard controlling, window != nil else { return }
        let menu = buildMenu(m.entries, token: m.token, path: [])
        menu.popUp(positioning: nil, at: viewPoint(m.origin), in: self)
    }

    private func buildMenu(_ entries: [RemoteControl.MenuEntry], token: Int, path: [Int]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (i, e) in entries.enumerated() {
            if e.separator { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: e.title, action: #selector(pickMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = e.enabled
            item.state = e.checked ? .on : .off
            item.representedObject = MenuPick(token: token, path: path + [i])
            if !e.children.isEmpty {
                item.submenu = buildMenu(e.children, token: token, path: path + [i])
                item.action = nil
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func pickMenuItem(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? MenuPick else { return }
        remote.chooseMenuItem(token: pick.token, path: pick.path)
    }

    /// A global point on the agent display to this view's coordinates.
    private func viewPoint(_ p: CGPoint) -> CGPoint {
        let r = imageRect, b = display.bounds
        return CGPoint(x: r.minX + (p.x - b.minX) / b.width * r.width, y: r.minY + (p.y - b.minY) / b.height * r.height)
    }

    // MARK: Keys

    private func forward(_ event: NSEvent) -> Bool {
        guard controlling, let cg = event.cgEvent else { return false }
        // cmd+Q would quit the whole app, the user's own windows included.
        if event.type == .keyDown, event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "q" {
            NSSound.beep()
            return true
        }
        remote.key(cg)
        return true
    }

    override func keyDown(with event: NSEvent) { if !forward(event) { super.keyDown(with: event) } }
    override func keyUp(with event: NSEvent) { if !forward(event) { super.keyUp(with: event) } }
    override func flagsChanged(with event: NSEvent) { if !forward(event) { super.flagsChanged(with: event) } }

    // Shortcuts reach the agent's app instead of this app's menus.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard controlling, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        return forward(event)
    }
}
