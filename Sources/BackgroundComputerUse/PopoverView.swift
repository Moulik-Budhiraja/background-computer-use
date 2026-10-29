import AppKit
import SwiftUI
import BCUCore

struct AgentApp: Identifiable {
    let id: pid_t
    let name: String
    let icon: NSImage?
}

final class PopoverModel: ObservableObject {
    let engine: Engine
    let openSettings: () -> Void
    let openViewer: () -> Void

    @Published var statusText = "Idle"
    @Published var status: EngineStatus = .idle
    @Published var preview: CGImage?
    @Published var apps: [AgentApp] = []
    @Published var handoffReason: String?
    @Published var paused = false
    @Published var hasWindows = false
    @Published var permissionsMissing = false
    @Published var lastGuardEvent: String?

    private lazy var stream = PreviewStream(engine: engine) { [weak self] image in self?.preview = image }

    init(engine: Engine, openSettings: @escaping () -> Void, openViewer: @escaping () -> Void) {
        self.engine = engine
        self.openSettings = openSettings
        self.openViewer = openViewer
    }

    func refresh() {
        status = engine.status
        switch status {
        case .idle: statusText = "Idle"
        case .working(let s): statusText = s
        case .waiting(let s): statusText = s
        case .paused: statusText = "Paused"
        }
        var seen = Set<pid_t>()
        apps = engine.windows.windows.compactMap { w in
            guard seen.insert(w.pid).inserted else { return nil }
            return AgentApp(id: w.pid, name: w.appName, icon: NSRunningApplication(processIdentifier: w.pid)?.icon)
        }
        hasWindows = !apps.isEmpty
        handoffReason = engine.windows.windows.first(where: { $0.handedOff })?.handoffReason
        paused = engine.paused
        permissionsMissing = !AX.isTrusted || !Capture.hasPermission
        if let e = engine.focusGuard.recentEvents.last, Date().timeIntervalSince(e.time) < 120 {
            lastGuardEvent = e.summary
        } else {
            lastGuardEvent = nil
        }
    }

    func startPreview(width: Int = 880, fps: Int = 8) {
        guard engine.display.isRunning, Capture.hasPermission else { return }
        stream.start(width: width, fps: fps)
    }

    func stopPreview() {
        stream.stop()
    }
}

/// Borderless SF Symbol button.
struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color = .secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Status dot, the agent's apps, and borderless controls. Shared by the
/// popover and the expanded view.
struct HeaderBar: View {
    @ObservedObject var model: PopoverModel
    let expandSymbol: String
    let onExpand: () -> Void
    var showSettings = true

    private var dotColor: Color {
        switch model.status {
        case .idle: return .secondary.opacity(0.6)
        case .working: return .green
        case .waiting: return .orange
        case .paused: return .yellow
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(dotColor).frame(width: 7, height: 7).help(model.statusText)
            if model.apps.isEmpty {
                Text(model.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                ForEach(model.apps) { app in
                    HStack(spacing: 4) {
                        if let icon = app.icon {
                            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                        }
                        Text(app.name).font(.caption).lineLimit(1)
                    }
                }
            }
            if let event = model.lastGuardEvent {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help(event)
            }
            Spacer(minLength: 4)
            IconButton(symbol: model.paused ? "play.fill" : "pause.fill", help: model.paused ? "Resume (⌃⌥⌘P)" : "Pause (⌃⌥⌘P)") {
                model.engine.setPaused(!model.paused)
            }
            IconButton(symbol: "stop.fill", help: "Stop: close the agent's windows (⌃⌥⌘.)") {
                model.engine.stopAll()
            }
            if model.hasWindows && model.handoffReason == nil {
                IconButton(symbol: "hand.raised.fill", help: "Take over: move the window to your screen and pause") {
                    model.engine.takeOver()
                }
            }
            IconButton(symbol: expandSymbol, help: "Expand", action: onExpand)
            if showSettings {
                IconButton(symbol: model.permissionsMissing ? "exclamationmark.triangle.fill" : "gearshape.fill",
                           help: "Settings", tint: model.permissionsMissing ? .orange : .secondary) {
                    model.openSettings()
                }
                IconButton(symbol: "power", help: "Quit") { NSApp.terminate(nil) }
            }
        }
    }
}

struct PopoverView: View {
    @ObservedObject var model: PopoverModel

    var body: some View {
        VStack(spacing: 8) {
            HeaderBar(model: model, expandSymbol: "arrow.up.left.and.arrow.down.right", onExpand: model.openViewer)

            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.85))
                if let image = model.preview {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else if model.permissionsMissing {
                    Image(systemName: "eye.slash").font(.title2).foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: 440, height: 275)
            .onTapGesture(count: 2) { model.openViewer() }

            if let reason = model.handoffReason {
                HStack(spacing: 8) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                    Text(reason).font(.caption).lineLimit(2)
                    Spacer()
                    IconButton(symbol: "checkmark.circle.fill", help: "Done: hand it back to the agent", tint: .green) {
                        model.engine.handBack()
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 460)
    }
}
