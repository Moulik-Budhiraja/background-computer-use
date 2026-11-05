import AppKit
import SwiftUI
import BCUCore

/// History: what agents' displays showed over the last week, as a large
/// panel over a dimmed backdrop like the expanded view, laid out and driven
/// like Coast's timeline. It opens on the newest frame. Two fingers (or the
/// wheel, or a drag on the track) move through time, ← → step a frame,
/// ⌥← ⌥→ or the chevrons on the frame's edges jump between apps, ⌘← ⌘→ go
/// to the start and end, ⌘+ ⌘− zoom the track, pinch zooms the frame, and
/// Esc closes.
final class HistoryWindowController {
    let model = HistoryModel()
    private let frameView = HistoryFrameView()
    private let trackView = HistoryTrackView()
    private let loader = FrameLoader()
    private var dim: NSPanel?
    private var panel: OverlayPanel?
    private var keyMonitor: Any?

    init() {
        trackView.model = model
        frameView.onScroll = { [weak self] e in self?.trackView.scrollWheel(with: e) }
        model.onItemsChanged = { [weak self] in self?.trackView.needsDisplay = true }
        model.onIndexChanged = { [weak self] animated in
            self?.trackView.follow(animated: animated)
            self?.showCurrent()
        }
        loader.onImage = { [weak self] key, image in
            guard let self, let item = self.model.current, let run = self.model.currentRun,
                  FrameLoader.key(run, item.frame) == key else { return }
            self.frameView.show(image, key: key, pointer: self.model.pointer)
        }
    }

    var isShown: Bool { panel != nil }
    var frameViewForTest: HistoryFrameView { frameView }
    var trackViewForTest: HistoryTrackView { trackView }

    private func showCurrent() {
        guard let item = model.current, let run = model.currentRun else { frameView.clear(); return }
        frameView.displaySize = run.size
        if let image = loader.cached(run, item.frame) {
            frameView.show(image, key: FrameLoader.key(run, item.frame), pointer: model.pointer)
        } else {
            loader.request(run, item.frame)
        }
    }

    /// Opens on the newest frame, or `session`'s newest.
    func show(session: String? = nil) {
        if panel != nil { model.load(session: session); return }
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

        // Sized like the expanded view, with room for the track.
        let area = screen.visibleFrame
        let aspect = CGFloat(AgentDisplay.defaultWidth) / CGFloat(AgentDisplay.defaultHeight)
        let padX = HistoryView.horizontalChrome, padY = HistoryView.verticalChrome
        var w = area.width * 0.88
        var h = (w - padX) / aspect + padY
        if h > area.height * 0.92 {
            h = area.height * 0.92
            w = (h - padY) * aspect + padX
        }
        let frame = NSRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)

        let p = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.onEscape = { [weak self] in self?.close() }
        p.contentView = NSHostingView(rootView: HistoryView(controller: self, model: model, frameView: frameView, trackView: trackView))

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
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let panel = self.panel, e.window === panel else { return e }
            return self.handleKey(e) ? nil : e
        }
        model.load(session: session)
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .shift, .control])
        switch Int(e.keyCode) {
        case 123: // ←
            if mods == .command { model.go(to: 0) } else if mods == .option { model.previousSegment() } else { model.step(-1) }
        case 124: // →
            if mods == .command { model.go(to: model.items.count - 1) } else if mods == .option { model.nextSegment() } else { model.step(1) }
        case 53: // Esc
            close()
        case 24 where mods.contains(.command), 69 where mods.contains(.command): // ⌘= ⌘+
            zoomTrack(1)
        case 27 where mods.contains(.command), 78 where mods.contains(.command): // ⌘-
            zoomTrack(-1)
        default:
            return false
        }
        return true
    }

    func zoomTrack(_ step: Int) {
        trackView.zoom(step)
        model.objectWillChange.send()
    }

    var canZoomIn: Bool { trackView.canZoomIn }
    var canZoomOut: Bool { trackView.canZoomOut }

    func close() {
        guard let p = panel, let d = dim else { return }
        panel = nil
        dim = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        frameView.resetZoom()
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

struct HistoryView: View {
    let controller: HistoryWindowController
    @ObservedObject var model: HistoryModel
    let frameView: HistoryFrameView
    let trackView: HistoryTrackView
    @State private var hovering = false

    static let padding: CGFloat = 12
    static let headerHeight: CGFloat = 28
    static let trackHeight: CGFloat = 76
    static let spacing: CGFloat = 8
    static let horizontalChrome = padding * 2
    static let verticalChrome = padding * 2 + headerHeight + trackHeight + spacing * 2

    var body: some View {
        VStack(spacing: Self.spacing) {
            header
            ZStack {
                Theme.monitor
                HistoryFrameRep(view: frameView)
                if model.loaded && model.isEmpty { empty }
                if !model.isEmpty {
                    HStack {
                        chevron("chevron.left", help: "Previous app (⌥←)", enabled: model.hasPreviousSegment, action: model.previousSegment)
                        Spacer()
                        chevron("chevron.right", help: "Next app (⌥→)", enabled: model.hasNextSegment, action: model.nextSegment)
                    }
                    .padding(.horizontal, 12)
                    .opacity(hovering ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: hovering)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
            .onHover { hovering = $0 }
            HistoryTrackRep(view: trackView)
                .frame(height: Self.trackHeight)
        }
        .padding(Self.padding)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.hud))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 2) {
            if !model.isEmpty {
                if model.isLive { Tally(kind: .live).help("Recording now") }
                HStack(spacing: 6) {
                    if let icon = model.appIcon {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    }
                    Text(model.appName).font(.system(size: 12, weight: .semibold))
                    Text(model.agentLabel).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    if let action = model.actionText {
                        Text(action)
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .truncationMode(.tail)
                            .help(action)
                    }
                }
                .lineLimit(1)
                .padding(.leading, model.isLive ? 2 : 6)
            } else {
                Text("History").font(.system(size: 12, weight: .semibold)).padding(.leading, 6)
            }
            Spacer(minLength: 8)
            if !model.isEmpty {
                Text(model.timeText)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 6)
            }
            HStack(spacing: 0) {
                IconButton(symbol: "text.viewfinder", help: model.highlightText ? "Hide text highlights" : "Highlight text you can copy",
                           tint: model.highlightText ? .accentColor : .secondary) {
                    model.highlightText.toggle()
                    frameView.highlightText = model.highlightText
                }
                IconButton(symbol: "minus.magnifyingglass", help: "Zoom out the timeline (⌘−)") { controller.zoomTrack(-1) }
                    .disabled(!controller.canZoomOut)
                IconButton(symbol: "plus.magnifyingglass", help: "Zoom in the timeline (⌘+)") { controller.zoomTrack(1) }
                    .disabled(!controller.canZoomIn)
                IconButton(symbol: "forward.end.fill", help: "Latest (⌘→)") { model.go(to: model.items.count - 1) }
                    .disabled(model.atEnd)
                Rectangle().fill(Theme.hairline).frame(width: 1, height: 14).padding(.leading, 2).padding(.trailing, 4)
                IconButton(symbol: "xmark", help: "Close (Esc)") { controller.close() }
            }
        }
        .frame(height: Self.headerHeight)
    }

    private func chevron(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.black.opacity(0.5)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0)
        .disabled(!enabled)
        .help(help)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 20, weight: .regular))
            Text("No recordings yet").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
            Text("Whatever agents do on their screens shows up here for a week.")
                .font(.system(size: 12))
        }
        .foregroundStyle(.white.opacity(0.45))
    }
}
