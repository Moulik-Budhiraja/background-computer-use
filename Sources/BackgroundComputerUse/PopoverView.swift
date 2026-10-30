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
    /// Set once the first frame arrives; frames themselves go to `frame`.
    @Published var hasFrame = false
    let frame = FrameLayer()
    @Published var apps: [AgentApp] = []
    @Published var handoffReason: String?
    @Published var handedOffApp: String?
    @Published var paused = false
    @Published var hasWindows = false
    @Published var permissionsMissing = false
    @Published var screenRecordingMissing = false
    @Published var lastGuardEvent: String?
    /// The user is driving the agent display from the expanded view.
    @Published var controlling = false
    /// The "Take over?" prompt is showing.
    @Published var askingControl = false

    /// Set only on the expanded view's model.
    var remote: RemoteControl?
    var onControlChange: ((Bool) -> Void)?
    /// The pointer moved while dragging in the preview (global point on the agent display).
    var onDragPoint: ((CGPoint) -> Void)?
    weak var remoteView: RemoteControlView?

    func excludeFromPreview(_ id: CGWindowID) { stream.excluded = id }
    /// What the take-over button does here.
    var takeOver: (() -> Void)?
    private var previewFPS = 8

    private lazy var stream = PreviewStream(engine: engine) { [weak self] image in
        guard let self else { return }
        self.frame.show(image)
        if !self.hasFrame { self.hasFrame = true }
    }
    private(set) lazy var moreMenu = MoreMenu(engine: engine, openSettings: openSettings)

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
        case .userInControl: statusText = "You're in control"
        }
        var seen = Set<pid_t>()
        apps = engine.windows.windows.compactMap { w in
            guard seen.insert(w.pid).inserted else { return nil }
            return AgentApp(id: w.pid, name: w.appName, icon: NSRunningApplication(processIdentifier: w.pid)?.icon)
        }
        hasWindows = !apps.isEmpty
        let handedOff = engine.windows.windows.first(where: { $0.handedOff })
        handoffReason = handedOff?.handoffReason
        handedOffApp = handedOff?.appName
        paused = engine.paused
        screenRecordingMissing = !Capture.hasPermission
        permissionsMissing = !AX.isTrusted || screenRecordingMissing
        if let e = engine.focusGuard.recentEvents.last, Date().timeIntervalSince(e.time) < 120 {
            lastGuardEvent = e.summary
        } else {
            lastGuardEvent = nil
        }
    }

    func startPreview(fps: Int = 15) {
        guard engine.display.isRunning, Capture.hasPermission else { return }
        previewFPS = fps
        stream.start(fps: fps)
    }

    func stopPreview() {
        stream.stop()
    }

    func setPreviewFPS(_ fps: Int) {
        stream.stop()
        startPreview(fps: fps)
    }

    func beginControl() {
        guard remote != nil, !controlling else { return }
        askingControl = false
        controlling = true
        engine.setUserInControl(true)
        onControlChange?(true)
    }

    func endControl() {
        askingControl = false
        guard controlling else { return }
        controlling = false
        remote?.end()
        engine.setUserInControl(false)
        onControlChange?(false)
    }

    var tally: Tally.Kind {
        switch status {
        case .working: return .live
        case .waiting: return .needs
        case .paused, .userInControl: return .paused
        case .idle: return permissionsMissing ? .needs : .idle
        }
    }

    /// Shown in place of the app list when the agent has no windows.
    var headerLabel: String {
        if permissionsMissing, case .idle = status { return "Setup needed" }
        return statusText
    }
}

/// The ⋯ menu: settings, open at login, display size and quit.
final class MoreMenu: NSObject {
    private let engine: Engine
    private let openSettings: () -> Void

    init(engine: Engine, openSettings: @escaping () -> Void) {
        self.engine = engine
        self.openSettings = openSettings
    }

    func show(below view: NSView?) {
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(settingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        let display = NSMenuItem(title: "Agent display \(engine.display.width) × \(engine.display.height)", action: nil, keyEquivalent: "")
        display.isEnabled = false
        menu.addItem(display)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Background Computer Use", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        if let view {
            let y = view.isFlipped ? view.bounds.maxY + 4 : -4
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: view)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    @objc private func settingsAction() { openSettings() }
    @objc private func toggleLogin() { LaunchAtLogin.set(!LaunchAtLogin.isEnabled) }
}

/// Borderless SF Symbol button with a 28pt hit area.
struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color = .secondary
    var size: CGFloat = 13
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering && isEnabled ? 0.07 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Status mark. Shape and color both change, so it reads without color too.
struct Tally: View {
    enum Kind { case live, needs, paused, idle }
    let kind: Kind

    var body: some View {
        Group {
            switch kind {
            case .live: dot(Theme.live)
            case .needs: dot(Theme.needs)
            case .paused:
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 1).frame(width: 2.5, height: 8)
                    RoundedRectangle(cornerRadius: 1).frame(width: 2.5, height: 8)
                }
                .foregroundStyle(Theme.quiet)
            case .idle:
                Circle().strokeBorder(Theme.quiet, lineWidth: 1.5).frame(width: 8, height: 8)
            }
        }
        .frame(width: 22, height: 28)
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .background(Circle().fill(color.opacity(0.2)).frame(width: 14, height: 14))
    }
}

private final class ViewHolder { weak var view: NSView? }

private struct AnchorView: NSViewRepresentable {
    let holder: ViewHolder
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        holder.view = v
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct MoreButton: View {
    @ObservedObject var model: PopoverModel
    @State private var holder = ViewHolder()

    var body: some View {
        IconButton(symbol: "ellipsis", help: "More", size: 14) {
            model.moreMenu.show(below: holder.view)
        }
        .background(AnchorView(holder: holder))
        .overlay(alignment: .topTrailing) {
            if model.permissionsMissing {
                Circle().fill(Theme.needs).frame(width: 6, height: 6).offset(x: -5, y: 5).allowsHitTesting(false)
            }
        }
    }
}

/// Status, the agent's apps, and borderless controls. Shared by the
/// popover and the expanded view.
struct HeaderBar: View {
    @ObservedObject var model: PopoverModel
    let expandSymbol: String
    let onExpand: () -> Void
    var showMore = true

    var body: some View {
        HStack(spacing: 2) {
            Tally(kind: model.tally).help(model.statusText)
            HStack(spacing: 12) {
                if model.apps.isEmpty {
                    Text(model.headerLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.apps) { app in
                        HStack(spacing: 5) {
                            if let icon = app.icon {
                                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                            }
                            Text(app.name).font(.system(size: 12, weight: .medium))
                        }
                    }
                }
                if let event = model.lastGuardEvent {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .help("Focus guard: \(event)")
                }
            }
            .lineLimit(1)
            .padding(.leading, 2)
            Spacer(minLength: 4)
            HStack(spacing: 0) {
                IconButton(symbol: model.paused ? "play.fill" : "pause.fill",
                           help: model.paused ? "Resume (⌃⌥⌘P)" : "Pause (⌃⌥⌘P)") {
                    model.engine.setPaused(!model.paused)
                }
                IconButton(symbol: "stop.fill", help: "Stop: close the agent's windows (⌃⌥⌘.)") {
                    model.engine.stopAll()
                }
                .disabled(!model.hasWindows)
                if model.controlling {
                    Button { model.endControl() } label: {
                        Text("Done")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .frame(height: 22)
                            .background(Capsule().fill(Color.accentColor))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Give the display back to the agent")
                    .padding(.horizontal, 3)
                } else if model.hasWindows, let takeOver = model.takeOver {
                    IconButton(symbol: "hand.raised.fill", help: "Take over: use the agent's windows yourself", action: takeOver)
                }
                Rectangle().fill(Theme.hairline).frame(width: 1, height: 14).padding(.leading, 2).padding(.trailing, 4)
                IconButton(symbol: expandSymbol, help: "Expand", action: onExpand)
                if showMore { MoreButton(model: model) }
            }
        }
        .frame(height: 28)
    }
}

/// The live view of the agent display, with its empty, setup, paused and
/// handoff states drawn over it.
struct PreviewPane: View {
    @ObservedObject var model: PopoverModel
    var cornerRadius: CGFloat = 8
    /// Only the expanded view passes this; it makes the preview controllable.
    var remote: RemoteControl? = nil

    var body: some View {
        ZStack {
            Theme.monitor
            if model.permissionsMissing {
                setup
            } else if !model.hasWindows {
                empty
            } else if model.hasFrame {
                FrameView(frame: model.frame)
            }
            if let remote, model.hasWindows, !model.permissionsMissing {
                RemoteSurface(model: model, remote: remote)
            }
            if !model.permissionsMissing {
                if let app = model.handedOffApp, !model.controlling {
                    handoffMarker(app).allowsHitTesting(false)
                } else if model.paused && !model.controlling {
                    pausedScrim
                }
            }
            if model.askingControl {
                controlPrompt
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(model.controlling ? Color.accentColor : Color.primary.opacity(0.08),
                          lineWidth: model.controlling ? 2 : 0.5))
    }

    private var controlPrompt: some View {
        ZStack {
            Color.black.opacity(0.55)
                .contentShape(Rectangle())
                .onTapGesture { model.askingControl = false }
            VStack(spacing: 10) {
                Image(systemName: "hand.raised.fill").font(.system(size: 18)).foregroundStyle(.white.opacity(0.8))
                Text("Take over?").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Text("The agent pauses while you use its windows. Your mouse and keyboard work in them while the pointer is over this view.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                HStack(spacing: 8) {
                    Button { model.askingControl = false } label: {
                        Text("Cancel").frame(width: 92, height: 28)
                            .background(Capsule().fill(Color.white.opacity(0.14)))
                            .contentShape(Capsule())
                    }
                    .keyboardShortcut(.cancelAction)
                    Button { model.beginControl() } label: {
                        Text("Take over").frame(width: 92, height: 28)
                            .background(Capsule().fill(Color.accentColor))
                            .contentShape(Capsule())
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.top, 4)
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.hud))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.dashed").font(.system(size: 20, weight: .regular))
            Text("Nothing running").font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.45))
    }

    private var setup: some View {
        VStack(spacing: 12) {
            Image(systemName: "eye.slash").font(.system(size: 20)).foregroundStyle(.white.opacity(0.45))
            Text(model.screenRecordingMissing ? "Screen Recording is off" : "Accessibility is off")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
            Button(action: model.openSettings) {
                HStack(spacing: 4) {
                    Text("Open Settings")
                    Image(systemName: "arrow.up.forward").font(.system(size: 9, weight: .bold))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(Color.white.opacity(0.14)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var pausedScrim: some View {
        ZStack {
            Color(hex: 0x0C0C0D, alpha: 0.74)
            VStack(spacing: 10) {
                Button { model.engine.setPaused(false) } label: {
                    Circle().fill(.white).frame(width: 44, height: 44)
                        .overlay(Image(systemName: "play.fill").font(.system(size: 16)).foregroundStyle(Color(hex: 0x1D1D1F)).offset(x: 1.5))
                        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
                .help("Resume (⌃⌥⌘P)")
                Text("Paused").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.74))
            }
        }
    }

    private func handoffMarker(_ app: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "display").font(.system(size: 12))
            Text("\(app) is on your screen").font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.78))
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Capsule().fill(Color.black.opacity(0.45)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

struct PopoverView: View {
    @ObservedObject var model: PopoverModel

    var body: some View {
        VStack(spacing: 10) {
            HeaderBar(model: model, expandSymbol: "arrow.up.left.and.arrow.down.right", onExpand: model.openViewer)

            PreviewPane(model: model)
                .frame(width: 440, height: 275)
                .onTapGesture(count: 2) { model.openViewer() }

            if let reason = model.handoffReason {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.needs.opacity(0.14))
                        .frame(width: 28, height: 28)
                        .overlay(Image(systemName: "hand.raised").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.needsInk))
                    Text(reason)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { model.engine.handBack() } label: {
                        Circle().fill(Color.accentColor).frame(width: 28, height: 28)
                            .overlay(Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Done: hand it back to the agent")
                }
                .padding(.horizontal, 2)
                .padding(.top, 2)
            }
        }
        .padding(10)
        .frame(width: 460)
    }
}
