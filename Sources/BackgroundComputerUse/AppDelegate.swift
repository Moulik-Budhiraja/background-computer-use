import AppKit
import BCUCore
import BCUShared

final class AppDelegate: NSObject, NSApplicationDelegate {
    let hub = Hub()
    private var server: SocketServer?
    private var statusController: StatusController?
    private var settings: SettingsWindowController?
    /// One expanded view per session, made when first opened.
    private var viewers: [String: ViewerWindowController] = [:]
    private var hotKeys: HotKeys?
    private var permissionTimer: Timer?
    private var updater: Updater?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One instance only.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: BCUPaths.bundleID)
            .filter { $0.processIdentifier != getpid() }
        if !others.isEmpty {
            NSApp.terminate(nil)
            return
        }

        CrashLog.install()
        hub.start()
        updater = Updater(hub: hub)

        let server = SocketServer { [hub] tool, args in hub.call(tool: tool, args: args) }
        do { try server.start() } catch { Log.info("socket failed: \(error)") }
        self.server = server

        statusController = StatusController(hub: hub,
                                            openSettings: { [weak self] in self?.showSettings() },
                                            openViewer: { [weak self] engine, control in self?.showViewer(engine, control: control) })
        statusController?.onRefresh = { [weak self] in self?.refreshViewers() }
        hotKeys = HotKeys(
            togglePause: { [weak self] in
                guard let self else { return }
                self.hub.setPausedAll(!self.hub.allPaused)
            },
            stop: { [weak self] in self?.hub.stopAll() }
        )

        if !AX.isTrusted || !Capture.hasPermission {
            showSettings()
        }
        // The event tap needs Accessibility; install it as soon as it's granted.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else { return }
            if AX.isTrusted && !self.hub.focusGuard.tapInstalled {
                self.hub.focusGuard.installTap()
            }
            if self.hub.focusGuard.tapInstalled { timer.invalidate() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hub.shutdown()
        server?.stop()
    }

    /// Expand one session's display. Only one expanded view shows at a time.
    func showViewer(_ engine: Engine, control: Bool = false) {
        statusController?.close()
        for (id, v) in viewers where id != engine.sessionID { v.close() }
        let viewer = viewers[engine.sessionID] ?? ViewerWindowController(engine: engine, openSettings: { [weak self] in self?.showSettings() })
        viewers[engine.sessionID] = viewer
        if control { viewer.showInControl() } else { viewer.toggle() }
    }

    /// A viewer whose display was torn down closes and is dropped.
    private func refreshViewers() {
        for (id, v) in viewers {
            if v.engine.display.isRunning {
                v.refresh()
            } else {
                v.close()
                viewers[id] = nil
            }
        }
    }

    func showSettings() {
        if settings == nil { settings = SettingsWindowController(engine: hub.engine(for: Hub.defaultSession, client: nil)) }
        settings?.show()
    }
}
