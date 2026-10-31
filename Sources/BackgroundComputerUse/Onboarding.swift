import AppKit
import SwiftUI
import ApplicationServices
import BCUCore
import BCUShared

/// The first-run window: permissions, then connecting Claude Code and Codex.
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    let model: OnboardingModel
    var onClose: (() -> Void)?

    init(model: OnboardingModel = OnboardingModel()) {
        self.model = model
        let hosting = NSHostingController(rootView: OnboardingView(model: model))
        window = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.view.fittingSize),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "Set Up \(BCUPaths.appName)"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = Theme.ground
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        window.delegate = self
        window.center()
        model.onFinish = { [weak self] in self?.window.close() }
    }

    func show() {
        model.refresh()
        model.startPolling()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.stopPolling()
        onClose?()
    }
}

final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case welcome, accessibility, screenRecording, connect, done
    }

    static let doneKey = "onboardingDone"
    static let stepKey = "onboardingStep"

    @Published var step: Step
    @Published var accessibility = false
    /// Capture works in this process.
    @Published var screenRecording = false
    /// The switch is on, but the app may need to restart before capture works.
    @Published var screenRecordingOn = false
    @Published var installed: Set<AgentKind> = []
    @Published var connected: Set<AgentKind> = []
    @Published var selected: Set<AgentKind> = []
    @Published var connecting = false
    @Published var connectError: String?
    @Published var copied = false
    @Published var openAtLogin = true

    var onFinish: (() -> Void)?
    private var timer: Timer?

    var bcuPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/bcu").path }
    var skillSource: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("skills/\(AgentSetup.skillName)"),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("SKILL.md").path) else { return nil }
        return url
    }

    init(step: Step? = nil) {
        let saved = Step(rawValue: UserDefaults.standard.integer(forKey: Self.stepKey)) ?? .welcome
        self.step = step ?? saved
        refresh()
        selected = installed.subtracting(connected)
    }

    /// Show setup until it's finished once. Someone who already has the
    /// permissions and a connected agent (an earlier install) never sees it.
    static func shouldShow() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: doneKey) { return false }
        let bcu = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/bcu").path
        let ready = AX.isTrusted && Capture.hasPermission
            && AgentKind.allCases.contains { AgentSetup.isConnected($0, bcuPath: bcu) }
        if ready { defaults.set(true, forKey: doneKey) }
        return !ready
    }

    func refresh() {
        let wasTrusted = accessibility
        accessibility = AX.isTrusted
        screenRecording = Capture.hasPermission
        screenRecordingOn = screenRecording || Self.screenRecordingSwitchedOn()
        // ~/.claude.json can be several MB, so only read it where it's shown.
        if timer == nil || step == .connect || step == .done {
            installed = Set(AgentKind.allCases.filter(AgentSetup.isInstalled))
            connected = Set(AgentKind.allCases.filter { AgentSetup.isConnected($0, bcuPath: bcuPath) })
            selected.subtract(connected)
        }

        if step == .accessibility, accessibility, !wasTrusted, timer != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                if self?.step == .accessibility { self?.next() }
            }
        }
        if step == .screenRecording, screenRecording { next() }
    }

    func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Steps

    func go(_ s: Step) {
        step = s
        UserDefaults.standard.set(s.rawValue, forKey: Self.stepKey)
    }

    /// The next step, skipping permissions that are already on.
    func next() {
        var s = step
        repeat {
            guard let n = Step(rawValue: s.rawValue + 1) else { return }
            s = n
        } while (s == .accessibility && accessibility) || (s == .screenRecording && screenRecording)
        go(s)
    }

    func back() {
        if let s = Step(rawValue: step.rawValue - 1) { go(s) }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func requestScreenRecording() {
        // The first request adds the app to the list; the pane is where it's switched on.
        _ = CGRequestScreenCaptureAccess()
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    /// Quit and open again, coming back to the Connect step.
    func relaunch() {
        go(.connect)
        let script = "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$0\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    func toggle(_ agent: AgentKind) {
        if selected.contains(agent) { selected.remove(agent) } else { selected.insert(agent) }
    }

    func connect() {
        let agents = AgentKind.allCases.filter { selected.contains($0) }
        guard !agents.isEmpty else { next(); return }
        connecting = true
        connectError = nil
        let bcu = bcuPath, skill = skillSource
        DispatchQueue.global(qos: .userInitiated).async {
            var errors: [String] = []
            for agent in agents {
                do {
                    guard let skill else { throw SetupError("The skill is missing from the app.") }
                    try AgentSetup.installSkill(from: skill, for: agent)
                    try AgentSetup.addMCPServer(agent, bcuPath: bcu)
                } catch {
                    errors.append("\(agent.displayName) didn't connect. \(error)")
                }
            }
            DispatchQueue.main.async {
                self.connecting = false
                self.refresh()
                if errors.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.next() }
                } else {
                    self.connectError = errors.joined(separator: "\n")
                }
            }
        }
    }

    func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\"\(bcuPath)\" mcp", forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.copied = false }
    }

    func finish() {
        if openAtLogin != LaunchAtLogin.isEnabled { LaunchAtLogin.set(openAtLogin) }
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        UserDefaults.standard.removeObject(forKey: Self.stepKey)
        onFinish?()
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    /// CGPreflightScreenCaptureAccess can keep saying no until the app
    /// restarts. Other apps' window titles are only readable with the
    /// permission, so they show the switch was turned on before then.
    static func screenRecordingSwitchedOn() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let me = getpid()
        return list.contains { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let owner = w[kCGWindowOwnerName as String] as? String, owner != "Window Server", owner != "Dock",
                  let name = w[kCGWindowName as String] as? String else { return false }
            return !name.isEmpty
        }
    }
}

// MARK: View

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    private var needsRestart: Bool {
        model.step == .screenRecording && model.screenRecordingOn && !model.screenRecording
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 44)
            art
            copy
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5)
            footer
        }
        .frame(width: 640)
        .background(Color(nsColor: Theme.ground))
    }

    @ViewBuilder private var art: some View {
        switch model.step {
        case .welcome:
            WelcomeArt()
        case .accessibility:
            PrivacyPaneArt(pane: .accessibility, isOn: model.accessibility)
        case .screenRecording:
            PrivacyPaneArt(pane: .screenRecording, isOn: model.screenRecordingOn)
        case .connect:
            ArtStage {
                HStack(spacing: 16) {
                    ForEach(AgentKind.allCases) { agent in
                        AgentCard(agent: agent,
                                  installed: model.installed.contains(agent),
                                  connected: model.connected.contains(agent),
                                  selected: model.selected.contains(agent),
                                  busy: model.connecting,
                                  toggle: { model.toggle(agent) })
                    }
                }
                .frame(width: Art.size.width, height: Art.size.height)
            }
        case .done:
            MenuBarArt(agentName: (AgentKind.allCases.first { model.connected.contains($0) } ?? .claude).displayName)
        }
    }

    private var title: String {
        switch model.step {
        case .welcome: return "Your agents get their own screen"
        case .accessibility: return "Let agents use your apps"
        case .screenRecording: return needsRestart ? "Reopen the app" : "Let agents see their windows"
        case .connect: return "Connect your agents"
        case .done: return "You're ready"
        }
    }

    private var line: String {
        switch model.step {
        case .welcome: return "They do all their work in their own windows so they don't get in your way."
        case .accessibility: return "Turn on Background Computer Use in this list."
        case .screenRecording:
            return needsRestart ? "macOS won't let it record until it restarts." : "Same thing, but in the Screen Recording list."
        case .connect: return "Pick the agents you want to use this with."
        case .done: return "Ask an agent to use any app. You can watch it from the menu bar."
        }
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .kerning(-0.4)
                .foregroundStyle(Color.primary)
            Text(line)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            extra.padding(.top, 8)
        }
        .padding(.horizontal, 40)
        .padding(.top, 28)
        .frame(width: 640, height: 152, alignment: .topLeading)
    }

    @ViewBuilder private var extra: some View {
        switch model.step {
        case .accessibility:
            StatusLine(on: model.accessibility)
        case .screenRecording:
            StatusLine(on: model.screenRecordingOn)
        case .connect:
            if let error = model.connectError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .lineLimit(2)
                    .textSelection(.enabled)
            } else {
                Button(action: model.copyCommand) {
                    HStack(spacing: 4) {
                        Text(model.copied ? "Copied" : "Other agent? Copy the MCP command")
                        if !model.copied { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)) }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        case .done:
            HStack(spacing: 10) {
                Keycaps(keys: ["⌃", "⌥", "⌘", "P"])
                Text("pauses all agents").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .welcome:
            EmptyView()
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if model.step == .done {
                Button { model.openAtLogin.toggle() } label: {
                    HStack(spacing: 8) {
                        Checkbox(on: model.openAtLogin, size: 16)
                        Text("Open at login").font(.system(size: 13)).foregroundStyle(Color.primary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 16)
            } else {
                StepDots(current: model.step.rawValue, count: 4).padding(.leading, 16)
            }
            Spacer()
            if model.step != .welcome && model.step != .done && !needsRestart {
                Button("Back", action: model.back)
                    .buttonStyle(QuietButtonStyle())
                    .disabled(model.connecting)
            }
            Button(primaryTitle, action: primaryAction)
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(model.connecting)
        }
        .padding(.horizontal, 24)
        .frame(height: 64)
    }

    private var primaryTitle: String {
        switch model.step {
        case .welcome: return "Get Started"
        case .accessibility: return model.accessibility ? "Continue" : "Open System Settings"
        case .screenRecording:
            if needsRestart { return "Quit & Reopen" }
            return model.screenRecording ? "Continue" : "Open System Settings"
        case .connect:
            if model.connecting { return "Connecting…" }
            return model.selected.isEmpty ? "Continue" : "Connect"
        case .done: return "Done"
        }
    }

    private func primaryAction() {
        switch model.step {
        case .welcome: model.next()
        case .accessibility: model.accessibility ? model.next() : model.requestAccessibility()
        case .screenRecording:
            if needsRestart { model.relaunch() }
            else if model.screenRecording { model.next() }
            else { model.requestScreenRecording() }
        case .connect: model.connect()
        case .done: model.finish()
        }
    }
}

private struct StatusLine: View {
    let on: Bool

    var body: some View {
        HStack(spacing: 8) {
            if on {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.live)
            } else {
                ZStack {
                    Circle().strokeBorder(Theme.needs, lineWidth: 1.4)
                    Circle().fill(Theme.needs).frame(width: 5, height: 5)
                }
                .frame(width: 13, height: 13)
            }
            Text(on ? "On" : "Off")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(on ? Color(hex: 0x1E8A42) : Theme.needsInk)
        }
    }
}

private struct StepDots: View {
    let current: Int
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(Color.primary.opacity(i == current ? 1 : (i < current ? 0.35 : 0.18)))
                    .frame(width: i == current ? 18 : 6, height: 6)
            }
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor))
            .overlay(RoundedRectangle(cornerRadius: 7).fill(.black.opacity(configuration.isPressed ? 0.12 : 0)))
            .opacity(isEnabled ? 1 : 0.6)
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

private struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(configuration.isPressed ? 0.08 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}
