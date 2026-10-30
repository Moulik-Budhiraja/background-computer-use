import AppKit
import BCUCore
import BCUShared

final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = Engine()
    private var server: SocketServer?
    private var statusController: StatusController?
    private var settings: SettingsWindowController?
    private var viewer: ViewerWindowController?
    private var hotKeys: HotKeys?
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One instance only.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: BCUPaths.bundleID)
            .filter { $0.processIdentifier != getpid() }
        if !others.isEmpty {
            NSApp.terminate(nil)
            return
        }

        do {
            try engine.start()
        } catch {
            Log.info("engine start failed: \(error)")
        }

        let server = SocketServer { [engine] tool, args in engine.call(tool: tool, args: args) }
        do { try server.start() } catch { Log.info("socket failed: \(error)") }
        self.server = server

        statusController = StatusController(engine: engine,
                                            openSettings: { [weak self] in self?.showSettings() },
                                            openViewer: { [weak self] in self?.showViewer() },
                                            takeOver: { [weak self] in self?.showViewer(control: true) })
        statusController?.onRefresh = { [weak self] in self?.viewer?.refresh() }
        hotKeys = HotKeys(
            togglePause: { [weak self] in
                guard let self else { return }
                self.engine.setPaused(!self.engine.paused)
            },
            stop: { [weak self] in self?.engine.stopAll() }
        )

        if !AX.isTrusted || !Capture.hasPermission {
            showSettings()
        }
        // The event tap needs Accessibility; install it as soon as it's granted.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else { return }
            if AX.isTrusted && !self.engine.focusGuard.tapInstalled {
                self.engine.focusGuard.installTap()
            }
            if self.engine.focusGuard.tapInstalled { timer.invalidate() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.shutdown()
        server?.stop()
    }

    func showViewer(control: Bool = false) {
        statusController?.close()
        if viewer == nil { viewer = ViewerWindowController(engine: engine, openSettings: { [weak self] in self?.showSettings() }) }
        if control { viewer?.showInControl() } else { viewer?.toggle() }
    }

    func showSettings() {
        if settings == nil { settings = SettingsWindowController(engine: engine) }
        settings?.show()
    }
}
