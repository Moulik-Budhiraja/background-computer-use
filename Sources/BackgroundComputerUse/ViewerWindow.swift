import AppKit
import SwiftUI
import BCUCore

/// A borderless panel that can take Esc without activating the app.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

private final class DimView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// "Expand": a large live view of the agent display floating over a dimmed
/// backdrop on the screen under the cursor. Not macOS full screen, and
/// non-activating, so the user's own app stays active underneath.
final class ViewerWindowController {
    let engine: Engine
    private let model: PopoverModel
    private let remote: RemoteControl
    private var dim: NSPanel?
    private var panel: OverlayPanel?
    private var resignObserver: NSObjectProtocol?

    init(engine: Engine, openSettings: @escaping () -> Void) {
        self.engine = engine
        var close: () -> Void = {}
        model = PopoverModel(engine: engine, openSettings: { close(); openSettings() }, openViewer: {})
        remote = RemoteControl(engine: engine)
        close = { [weak self] in self?.close() }
        model.remote = remote
        model.takeOver = { [weak model] in model?.beginControl() }
        model.onControlChange = { [weak self] on in self?.controlChanged(on) }
        model.onDragPoint = { [weak self] p in self?.dragMoved(to: p) }
        remote.onDrag = { [weak self] e in self?.dragChanged(e) }
        remote.onCursor = { [weak model] c in model?.remoteView?.setRemoteCursor(c) }
        remote.onMenu = { [weak model] m in model?.remoteView?.showProxyMenu(m) }
    }

    // MARK: Window drags

    private var drag: RemoteControl.DragVisual?
    private var lastDragPoint: CGPoint?
    private var settle: Timer?

    /// A window moved or resized through accessibility shows up about 100 ms
    /// later, so the preview draws it where the pointer puts it right away:
    /// a moved window as a picture (with the real one left out of the
    /// capture), a resized one as an outline.
    private func dragChanged(_ e: RemoteControl.DragEvent) {
        model.frame.displayBounds = engine.display.bounds
        switch e {
        case .began(let v):
            settle?.invalidate()
            drag = v
            if v.kind == .move { model.excludeFromPreview(v.windowID) }
            dragMoved(to: lastDragPoint ?? v.pressPoint)
        case .ended(let id, let final):
            let image = drag?.snapshot
            drag = nil
            lastDragPoint = nil
            model.frame.showGhost(final, image: image)
            // Keep drawing it until the real window is there.
            let started = Date()
            settle?.invalidate()
            settle = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
                guard let self else { t.invalidate(); return }
                let now = WindowList.info(id)?.bounds
                let arrived = now.map { abs($0.minX - final.minX) < 1 && abs($0.minY - final.minY) < 1
                    && abs($0.width - final.width) < 1 && abs($0.height - final.height) < 1 } ?? true
                guard arrived || Date().timeIntervalSince(started) > 0.8 else { return }
                t.invalidate()
                self.model.excludeFromPreview(0)
                // One more frame so the capture has the window before the picture goes.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    if self.drag == nil { self.model.frame.hideGhost() }
                }
            }
        }
    }

    private func dragMoved(to point: CGPoint) {
        lastDragPoint = point
        guard let v = drag else { return }
        let f = RemoteControl.dragFrame(v.kind, start: v.start, from: v.pressPoint, to: point, display: engine.display.bounds)
        model.frame.showGhost(f, image: v.snapshot)
    }

    /// Show the viewer and go straight into control (the take-over button).
    func showInControl() {
        show()
        model.beginControl()
    }

    /// In control, the backdrop goes away so the rest of the screen works as
    /// usual, and the preview runs faster.
    private func controlChanged(_ on: Bool) {
        guard let dim, let panel else { return }
        dim.ignoresMouseEvents = on
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            dim.animator().alphaValue = on ? 0 : 1
        }
        // In control, as fast as capture allows (about 50 fps).
        model.setPreviewFPS(on ? 60 : 30)
        if on { panel.makeKey() }
        // If an app brought itself forward and the guard sent it back, the
        // user's app is active again and took key from the panel. While the
        // pointer is still over the panel, the user is still in it: take key back.
        if on {
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self, weak panel] _ in
                guard let self, let panel, self.model.controlling else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    guard self.model.controlling, !panel.isKeyWindow, panel.frame.contains(NSEvent.mouseLocation),
                          NSEvent.pressedMouseButtons == 0 else { return }
                    panel.makeKey()
                }
            }
        } else if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
    }

    var isShown: Bool { panel != nil }

    func toggle() {
        if isShown { close() } else { show() }
    }

    func show() {
        guard panel == nil else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens[0]

        let dimPanel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        dimPanel.level = .floating
        dimPanel.isOpaque = false
        dimPanel.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        dimPanel.hasShadow = false
        dimPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let dimView = DimView(frame: NSRect(origin: .zero, size: screen.frame.size))
        dimView.onClick = { [weak self] in self?.close() }
        dimPanel.contentView = dimView

        // 88% of the visible screen, sized so the preview keeps the agent
        // display's aspect ratio inside the panel's padding and header.
        let area = screen.visibleFrame
        let aspect = CGFloat(engine.display.width) / CGFloat(engine.display.height)
        let padX = ExpandedView.horizontalChrome, padY = ExpandedView.verticalChrome
        var w = area.width * 0.88
        var h = (w - padX) / aspect + padY
        if h > area.height * 0.9 {
            h = area.height * 0.9
            w = (h - padY) * aspect + padX
        }
        let frame = NSRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)

        let p = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.onEscape = { [weak self] in
            guard let self else { return }
            if self.model.askingControl { self.model.askingControl = false } else { self.close() }
        }
        p.contentView = NSHostingView(rootView: ExpandedView(model: model, remote: remote, onCollapse: { [weak self] in self?.close() }))

        dimPanel.alphaValue = 0
        p.alphaValue = 0
        dimPanel.orderFrontRegardless()
        p.orderFrontRegardless()
        p.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            dimPanel.animator().alphaValue = 1
            p.animator().alphaValue = 1
        }
        dim = dimPanel
        panel = p
        model.refresh()
        model.startPreview(fps: 30)
    }

    func refresh() {
        if isShown { model.refresh() }
    }

    func close() {
        guard let p = panel, let d = dim else { return }
        model.endControl()
        panel = nil
        dim = nil
        model.stopPreview()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 0
            d.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
            d.orderOut(nil)
        })
    }
}

private struct ExpandedView: View {
    @ObservedObject var model: PopoverModel
    let remote: RemoteControl
    let onCollapse: () -> Void

    static let padding: CGFloat = 12
    static let headerHeight: CGFloat = 28
    static let spacing: CGFloat = 8
    static let horizontalChrome = padding * 2
    static let verticalChrome = padding * 2 + headerHeight + spacing

    var body: some View {
        VStack(spacing: Self.spacing) {
            HeaderBar(model: model, expandSymbol: "arrow.down.right.and.arrow.up.left", onExpand: onCollapse, showMore: false)
            PreviewPane(model: model, cornerRadius: 10, remote: remote)
        }
        .padding(Self.padding)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.hud))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
    }
}
