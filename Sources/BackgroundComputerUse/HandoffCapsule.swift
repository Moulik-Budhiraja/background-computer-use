import AppKit
import SwiftUI

/// A notification that grows out of the menu bar icon like the Dynamic
/// Island, opens into a card, then settles back into the icon. Shown when
/// an agent hands a window to the user. One at a time, in its own
/// non-activating panel, so the user's app keeps focus.
final class HandoffCapsule {
    struct Item {
        /// Identifies the handoff, so one that ends can be dropped.
        let key: String
        let title: String
        let body: String
        let icon: NSImage?
        let open: () -> Void
    }

    // Big enough for the card and its shadow; the rest lets clicks through.
    static let width: CGFloat = 440
    static let height: CGFloat = 240
    /// The icon sits a little right of the card's middle, so the card reads
    /// as coming out of it without running off the screen's right edge.
    static let anchor: CGFloat = 0.6

    private let panel: NSPanel
    private let model = CapsuleModel()
    /// The menu bar icon's frame on screen.
    private let iconFrame: () -> NSRect?
    private var queue: [Item] = []
    private var current: Item?
    private var hoverTimer: Timer?

    init(iconFrame: @escaping () -> NSRect?) {
        self.iconFrame = iconFrame
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Keep it out of screenshots and shared screens.
        panel.sharingType = .none
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: CapsuleView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.height)
        panel.contentView = host
        model.onDone = { [weak self] in self?.finish() }
    }

    func notify(_ item: Item) {
        guard current?.key != item.key, !queue.contains(where: { $0.key == item.key }) else { return }
        queue.append(item)
        next()
    }

    /// The handoff ended (the user finished, or the agent took it back).
    func drop(key: String) {
        queue.removeAll { $0.key == key }
        if current?.key == key { model.close() }
    }

    private func next() {
        guard current == nil, !queue.isEmpty, let icon = iconFrame() else { return }
        let item = queue.removeFirst()
        current = item
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: icon.midX, y: icon.midY)) } ?? NSScreen.main
        let area = screen?.frame ?? icon
        let x = min(max(icon.midX - Self.width * Self.anchor, area.minX + 8), area.maxX - Self.width - 8)
        panel.setFrame(NSRect(x: x.rounded(), y: icon.minY - Self.height, width: Self.width, height: Self.height), display: false)
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        model.show(item, anchorX: icon.midX - x)
        watchPointer()
    }

    private func finish() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        current = nil
        panel.orderOut(nil)
        panel.ignoresMouseEvents = true
        next()
    }

    /// The panel takes the mouse only while the pointer is over the card,
    /// so the empty parts around it don't block what's underneath. The app
    /// is never active, so this polls rather than relying on tracking areas.
    private func watchPointer() {
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            let card = self.model.cardRect
            // SwiftUI's frame is flipped (origin top left) within the panel.
            let f = self.panel.frame
            let onScreen = NSRect(x: f.minX + card.minX, y: f.maxY - card.maxY, width: card.width, height: card.height)
            let inside = self.model.stage == .card && !self.model.closing && onScreen.contains(NSEvent.mouseLocation)
            if self.panel.ignoresMouseEvents == inside { self.panel.ignoresMouseEvents = !inside }
            self.model.hover(inside)
        }
    }
}

final class CapsuleModel: ObservableObject {
    /// seed: tucked under the menu bar · pill: just out of the icon ·
    /// card: open. The same steps run backwards to settle into the icon.
    enum Stage { case seed, pill, card }

    static let cardWidth: CGFloat = 348
    static let pill = CGSize(width: 72, height: 28)
    static let holdMs = 6000
    static let holdAfterHoverMs = 2500

    @Published var item: HandoffCapsule.Item?
    @Published var stage: Stage = .seed
    @Published var closing = false
    @Published var contentHeight: CGFloat = 96
    var anchorX: CGFloat = 0
    var onDone: (() -> Void)?
    private var hovered = false
    private var timers: [DispatchWorkItem] = []

    private func later(_ ms: Int, _ f: @escaping () -> Void) {
        let w = DispatchWorkItem(block: f)
        timers.append(w)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms), execute: w)
    }

    private func clearTimers() {
        timers.forEach { $0.cancel() }
        timers = []
    }

    func show(_ item: HandoffCapsule.Item, anchorX: CGFloat) {
        clearTimers()
        hovered = false
        closing = false
        self.anchorX = anchorX
        stage = .seed
        self.item = item
        // Let the seed draw before it grows.
        later(30) { withAnimation(Self.grow) { self.stage = .pill } }
        later(250) { withAnimation(Self.grow) { self.stage = .card } }
        hold(Self.holdMs)
    }

    func close() {
        guard item != nil, !closing else { return }
        clearTimers()
        closing = true
        later(120) { withAnimation(Self.shrink) { self.stage = .pill } }
        later(340) { withAnimation(Self.shrink) { self.stage = .seed } }
        later(560) {
            self.item = nil
            self.closing = false
            self.onDone?()
        }
    }

    private func hold(_ ms: Int) {
        later(ms) { if !self.hovered { self.close() } }
    }

    func hover(_ inside: Bool) {
        guard inside != hovered else { return }
        hovered = inside
        if !inside && !closing && item != nil {
            clearTimers()
            hold(Self.holdAfterHoverMs)
        }
    }

    /// The capsule's shape for the current stage, in the panel's (flipped) coordinates.
    var cardRect: CGRect {
        switch stage {
        case .card:
            let w = Self.cardWidth
            let x = min(max(anchorX - w * HandoffCapsule.anchor, 16), HandoffCapsule.width - w - 16)
            return CGRect(x: x, y: 6, width: w, height: contentHeight)
        case .pill:
            return CGRect(x: anchorX - Self.pill.width / 2, y: 6, width: Self.pill.width, height: Self.pill.height)
        case .seed:
            return CGRect(x: anchorX - 14, y: -22, width: 28, height: 20)
        }
    }

    var cornerRadius: CGFloat {
        switch stage {
        case .card: return 24
        case .pill: return 14
        case .seed: return 10
        }
    }

    // A slight overshoot growing out, and a quick ease back in.
    static let grow = Animation.timingCurve(0.3, 1.3, 0.5, 1, duration: 0.38)
    static let shrink = Animation.timingCurve(0.5, 0, 0.7, 0.4, duration: 0.22)
}

private struct CapsuleView: View {
    @ObservedObject var model: CapsuleModel
    static let ground = Color(hex: 0x1B1B1E)

    var body: some View {
        let rect = model.cardRect
        ZStack(alignment: .topLeading) {
            if let item = model.item {
                ZStack(alignment: .topLeading) {
                    Circle().fill(Theme.needs).frame(width: 6, height: 6)
                        .frame(width: rect.width, height: rect.height)
                        .opacity(model.stage == .pill ? 1 : 0)
                        .animation(.easeOut(duration: 0.12), value: model.stage)
                    content(item)
                        .frame(width: CapsuleModel.cardWidth, alignment: .topLeading)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { model.contentHeight = $0 }
                        .opacity(model.stage == .card && !model.closing ? 1 : 0)
                        .animation(model.stage == .card && !model.closing ? .easeOut(duration: 0.2).delay(0.14) : .easeOut(duration: 0.12),
                                   value: model.stage == .card && !model.closing)
                }
                .frame(width: rect.width, height: rect.height, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: model.cornerRadius, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: model.cornerRadius, style: .continuous)
                        .fill(Self.ground)
                        .shadow(color: .black.opacity(model.stage == .seed ? 0 : 0.28), radius: 25, y: 18)
                )
                .offset(x: rect.minX, y: rect.minY)
            }
        }
        .frame(width: HandoffCapsule.width, height: HandoffCapsule.height, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
    }

    private func content(_ item: HandoffCapsule.Item) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if let icon = item.icon {
                        Image(nsImage: icon).resizable().frame(width: 32, height: 32)
                    } else {
                        Circle().fill(Theme.needs.opacity(0.2)).frame(width: 32, height: 32)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("now").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                    }
                    Text(item.body)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                CapsuleButton(title: "Dismiss", primary: false) { model.close() }
                CapsuleButton(title: "Open", primary: true) {
                    item.open()
                    model.close()
                }
            }
        }
        .padding(14)
    }
}

private struct CapsuleButton: View {
    let title: String
    let primary: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(primary ? Color(hex: 0x1B1B1E) : .white)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(Capsule().fill(fill))
            // AppKit takes the click: the app is never active, so a SwiftUI
            // button's first click could go to activating it.
            .overlay(ClickCatcher(help: "", onHover: { hovering = $0 }, action: action))
    }

    private var fill: Color {
        if primary { return hovering ? Color(hex: 0xE8E8EA) : .white }
        return .white.opacity(hovering ? 0.18 : 0.12)
    }
}
