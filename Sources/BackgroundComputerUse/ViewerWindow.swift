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
    private let engine: Engine
    private let model: PopoverModel
    private var dim: NSPanel?
    private var panel: OverlayPanel?

    init(engine: Engine) {
        self.engine = engine
        model = PopoverModel(engine: engine, openSettings: {}, openViewer: {})
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

        // 88% of the visible screen, at the agent display's aspect ratio.
        let area = screen.visibleFrame
        let aspect = CGFloat(engine.display.width) / CGFloat(engine.display.height)
        var w = area.width * 0.88
        var h = w / aspect + 44
        if h > area.height * 0.9 {
            h = area.height * 0.9
            w = (h - 44) * aspect
        }
        let frame = NSRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)

        let p = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.onEscape = { [weak self] in self?.close() }
        p.contentView = NSHostingView(rootView: ExpandedView(model: model, onCollapse: { [weak self] in self?.close() }))

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
        model.startPreview(width: engine.display.width, fps: 15)
    }

    func refresh() {
        if isShown { model.refresh() }
    }

    func close() {
        guard let p = panel, let d = dim else { return }
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
    let onCollapse: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HeaderBar(model: model, expandSymbol: "arrow.down.right.and.arrow.up.left", onExpand: onCollapse, showSettings: false)
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black)
                if let image = model.preview {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.12)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08)))
        .environment(\.colorScheme, .dark)
    }
}
