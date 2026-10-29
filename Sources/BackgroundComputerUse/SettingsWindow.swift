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
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Background Computer Use"
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
        launchAtLogin = SMAppService.mainApp.status == .enabled
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
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("[bcu] launch at login: \(error)")
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Background Computer Use").font(.title2.bold())
                Text("Agents work in your apps on a private display you never see. You keep your focus, cursor and keystrokes.")
                    .font(.callout).foregroundColor(.secondary)
            }

            GroupBox("Permissions (one time)") {
                VStack(alignment: .leading, spacing: 10) {
                    permissionRow("Accessibility", detail: "Read app windows and act on them; keep your cursor and keystrokes safe.",
                                  granted: model.accessibility, action: model.requestAccessibility)
                    permissionRow("Screen Recording", detail: "Screenshots of the agent's windows and the live preview.",
                                  granted: model.screenRecording, action: model.requestScreenRecording)
                    if !model.screenRecording {
                        Text("After granting Screen Recording, quit and reopen the app.").font(.caption).foregroundColor(.secondary)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Connect your agents") {
                VStack(alignment: .leading, spacing: 10) {
                    commandRow("Claude Code", text: model.claudeCommand)
                    commandRow("Codex (~/.codex/config.toml)", text: model.codexConfig)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))

            Text("Agent display: \(model.engine.display.width)×\(model.engine.display.height). Pause with ⌃⌥⌘P, stop with ⌃⌥⌘.")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding(22)
        .frame(width: 560)
    }

    private func permissionRow(_ title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundColor(granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.bold())
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if !granted { Button("Grant…", action: action) }
        }
    }

    private func commandRow(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout.bold())
                Spacer()
                Button(model.copied == title ? "Copied" : "Copy") { model.copy(text, label: title) }
            }
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
        }
    }
}
