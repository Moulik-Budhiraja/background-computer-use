import AppKit
import SwiftUI
import ServiceManagement
import ApplicationServices
import BCUCore

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let model: SettingsModel

    init(engine: Engine) {
        model = SettingsModel(engine: engine)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Background Computer Use Settings"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.ground
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
        window.delegate = self
        window.center()
    }

    func show() {
        model.refresh()
        model.startPolling()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.stopPolling()
    }
}

final class SettingsModel: ObservableObject {
    let engine: Engine
    @Published var accessibility = false
    @Published var screenRecording = false
    @Published var launchAtLogin = false
    @Published var copied: String?
    private var timer: Timer?

    init(engine: Engine) { self.engine = engine }

    var bcuPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/bcu").path
    }

    var claudeCommand: String {
        "claude mcp add --scope user background-computer-use -- \"\(bcuPath)\" mcp"
    }

    var codexConfig: String {
        "[mcp_servers.background-computer-use]\ncommand = \"\(bcuPath)\"\nargs = [\"mcp\"]"
    }

    func refresh() {
        accessibility = AX.isTrusted
        screenRecording = Capture.hasPermission
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        LaunchAtLogin.set(on)
        refresh()
    }

    func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = label
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.copied = nil }
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var agent = Agent.claude

    private enum Agent: String, CaseIterable, Identifiable {
        case claude = "Claude Code", codex = "Codex"
        var id: String { rawValue }
    }

    private var allowedCount: Int { (model.accessibility ? 1 : 0) + (model.screenRecording ? 1 : 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                AppMark()
                Text("Background Computer Use")
                    .font(.system(size: 22, weight: .bold))
                    .kerning(-0.2)
            }
            .padding(.horizontal, 4)

            section("Permissions", trailing: allowedCount == 2 ? "All allowed" : "\(allowedCount) of 2 allowed") {
                SettingsCard {
                    permissionRow("Accessibility", granted: model.accessibility, action: model.requestAccessibility)
                    RowDivider(inset: 46)
                    permissionRow("Screen Recording", granted: model.screenRecording, action: model.requestScreenRecording)
                }
                if !model.screenRecording {
                    Text("macOS asks you to reopen the app after you allow Screen Recording.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }

            section("Connect your agents") {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Picker("", selection: $agent) {
                                ForEach(Agent.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                            Spacer()
                            Text(agent == .claude ? "Run once in Terminal" : "Add to ~/.codex/config.toml")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        commandWell(agent == .claude ? model.claudeCommand : model.codexConfig, label: agent.rawValue)
                    }
                    .padding(14)
                }
            }

            section("General") {
                SettingsCard {
                    HStack {
                        Text("Open at login")
                        Spacer()
                        Toggle("", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                    .generalRow()
                    RowDivider(inset: 14)
                    HStack {
                        Text("Pause or resume the agent")
                        Spacer()
                        Keycaps(keys: ["⌃", "⌥", "⌘", "P"])
                    }
                    .generalRow()
                    RowDivider(inset: 14)
                    HStack {
                        Text("Stop and close agent windows")
                        Spacer()
                        Keycaps(keys: ["⌃", "⌥", "⌘", "."])
                    }
                    .generalRow()
                    RowDivider(inset: 14)
                    HStack {
                        Text("Agent display")
                        Spacer()
                        Text(verbatim: "\(model.engine.display.width) × \(model.engine.display.height)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .generalRow()
                }
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 26)
        .frame(width: 600)
        .background(Color(nsColor: Theme.ground))
    }

    private func section<Content: View>(_ title: String, trailing: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                if let trailing {
                    Text(trailing).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
            content()
        }
    }

    private func permissionRow(_ title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            ZStack {
                if granted {
                    Circle().fill(Color.primary.opacity(0.08))
                    Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold))
                } else {
                    Circle().strokeBorder(Theme.needs, lineWidth: 1.4)
                    Circle().fill(Theme.needs).frame(width: 6, height: 6)
                }
            }
            .frame(width: 16, height: 16)
            .frame(width: 20)
            Text(title).font(.system(size: 13, weight: .medium))
            Spacer()
            if granted {
                Text("Allowed").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Button("Allow…", action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    private func commandWell(_ text: String, label: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(text)
                .font(.custom("Menlo", size: 11))
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            if model.copied == label {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                    Text("Copied")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            } else {
                IconButton(symbol: "doc.on.doc", help: "Copy", size: 12) { model.copy(text, label: label) }
                    .frame(width: 26, height: 26)
            }
        }
        .padding(.vertical, 6)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: Theme.ground)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

private struct RowDivider: View {
    let inset: CGFloat
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5).padding(.leading, inset)
    }
}

private extension View {
    func generalRow() -> some View {
        padding(.horizontal, 14).frame(height: 40)
    }
}

struct Keycaps: View {
    let keys: [String]
    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 11, weight: key.count == 1 && key.first!.isLetter ? .medium : .regular))
                    .foregroundStyle(.primary.opacity(0.8))
                    .padding(.horizontal, 5)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: Theme.ground)))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
            }
        }
    }
}

/// The app's mark: a display with the agent's cursor and a live dot.
private struct AppMark: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Theme.hud)
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            .frame(width: 56, height: 56)
            .overlay(
                Canvas { ctx, size in
                    let k = size.width / 34
                    ctx.scaleBy(x: k, y: k)
                    let white = Color(hex: 0xF5F5F7), tile = Color(hex: 0x1C1C1E)
                    ctx.stroke(Path(roundedRect: CGRect(x: 4, y: 8, width: 26, height: 18), cornerRadius: 4), with: .color(white), lineWidth: 2.4)
                    var cursor = Path()
                    cursor.addLines([CGPoint(x: 17.5, y: 14.5), CGPoint(x: 17.5, y: 25.3), CGPoint(x: 20.2, y: 22.8),
                                     CGPoint(x: 22.0, y: 27.0), CGPoint(x: 23.9, y: 26.2), CGPoint(x: 22.1, y: 22.1),
                                     CGPoint(x: 25.8, y: 21.9)])
                    cursor.closeSubpath()
                    ctx.fill(cursor, with: .color(white))
                    ctx.stroke(cursor, with: .color(tile), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
                    let dot = Path(ellipseIn: CGRect(x: 23.5, y: 4.5, width: 8, height: 8))
                    ctx.fill(dot, with: .color(Theme.live))
                    ctx.stroke(dot, with: .color(tile), lineWidth: 2)
                }
                .frame(width: 40, height: 40)
            )
            .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
    }
}
