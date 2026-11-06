import AppKit
import BCUCore
import BCUShared

final class AppDelegate: NSObject, NSApplicationDelegate {
    let hub = Hub()
    private var server: SocketServer?
    private var host: HostServer?
    /// One engine runs per Mac; this app runs it unless a host app's
    /// `bcu serve` already does, in which case it waits for that one to finish.
    private var engineLock: EngineLock?
    private var lockTimer: Timer?
    private var statusController: StatusController?
    private var settings: SettingsWindowController?
    private var onboarding: OnboardingWindowController?
    /// One expanded view per session, made when first opened.
    private var viewers: [String: ViewerWindowController] = [:]
    private var hotKeys: HotKeys?
    private var permissionTimer: Timer?
    private var recordTimer: Timer?
    private var updater: Updater?
    private var history: HistoryWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One instance only.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: BCUPaths.bundleID)
            .filter { $0.processIdentifier != getpid() }
        if !others.isEmpty {
            NSApp.terminate(nil)
            return
        }

        CrashLog.install()
        updater = Updater(hub: hub)
        // A host app's `bcu serve` reads this to start this app rather than run
        // an engine of its own. Kept current as permissions are granted or taken away.
        var record = AppRecord.current()
        record.write()
        recordTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            let now = AppRecord.current()
            if now != record { record = now; now.write() }
        }
        if !startEngine() { waitForEngine() }

        statusController = StatusController(hub: hub,
                                            openSettings: { [weak self] in self?.showSettings() },
                                            openViewer: { [weak self] engine, control in self?.showViewer(engine, control: control) },
                                            openHistory: { [weak self] in self?.showHistory() })
        statusController?.onRefresh = { [weak self] in self?.refreshViewers() }
        hotKeys = HotKeys(
            togglePause: { [weak self] in
                guard let self else { return }
                self.hub.setPausedAll(!self.hub.allPaused)
            },
            stop: { [weak self] in self?.hub.stopAll() }
        )

        if OnboardingModel.shouldShow() {
            showOnboarding()
        } else if !AX.isTrusted || !Capture.hasPermission {
            showSettings()
        }
        // The event tap needs Accessibility; install it as soon as it's granted.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            // Only the running engine taps input; a second tap would hold the user's keys twice.
            guard let self, self.engineLock != nil else { return }
            if AX.isTrusted && !self.hub.focusGuard.tapInstalled {
                self.hub.focusGuard.installTap()
            }
            if self.hub.focusGuard.tapInstalled { timer.invalidate() }
        }
    }

    /// Take the engine lock and start the engine. False if another engine runs.
    private func startEngine() -> Bool {
        guard let lock = EngineLock.acquire(name: BCUPaths.appName, version: BCUVersion.current) else { return false }
        engineLock = lock
        hub.start()
        let host = HostServer(hub: hub, ownerName: BCUPaths.appName, version: BCUVersion.current)
        let server = SocketServer { [hub] tool, args in hub.call(tool: tool, args: args) }
        server.hostHandler = { op, req, connection in host.handle(op, req, connection) }
        do { try server.start() } catch { Log.info("socket failed: \(error)") }
        self.server = server
        self.host = host
        return true
    }

    /// A host app's engine is running. Ask it to stop once its agents are
    /// done, and take over then. Its agents' `bcu mcp` reconnect to this one.
    private func waitForEngine() {
        let owner = EngineLock.current()
        Log.info("another engine is running (\(owner?.name ?? "unknown"), pid \(owner?.pid ?? 0)); asking it to hand over")
        DispatchQueue.global().async {
            _ = try? SocketClient().request(["op": "yield"])
        }
        lockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.startEngine() {
                timer.invalidate()
                self.lockTimer = nil
                Log.info("took over as the engine")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard engineLock != nil else { return }
        hub.shutdown()
        server?.stop()
    }

    /// Expand one session's display. Only one expanded view shows at a time.
    func showViewer(_ engine: Engine, control: Bool = false) {
        statusController?.close()
        for (id, v) in viewers where id != engine.sessionID { v.close() }
        history?.close()
        let viewer = viewers[engine.sessionID] ?? ViewerWindowController(engine: engine, openSettings: { [weak self] in self?.showSettings() },
                                                                          openHistory: { [weak self] e in self?.showHistory(session: e.sessionID) })
        viewers[engine.sessionID] = viewer
        if control { viewer.showInControl() } else { viewer.toggle() }
    }

    /// A viewer whose display was torn down, or whose session a host app
    /// now shows itself, closes and is dropped.
    private func refreshViewers() {
        let shown = Set(hub.shownEngines.map(\.sessionID))
        for (id, v) in viewers {
            if v.engine.display.isRunning && shown.contains(id) {
                v.refresh()
            } else {
                v.close()
                viewers[id] = nil
            }
        }
    }

    /// History, on the newest frame (of `session`, if given). One viewer at a time.
    func showHistory(session: String? = nil) {
        statusController?.close()
        for v in viewers.values { v.close() }
        let h = history ?? HistoryWindowController()
        history = h
        h.show(session: session)
    }

    func showOnboarding() {
        if onboarding == nil {
            let controller = OnboardingWindowController()
            controller.onClose = { [weak self] in self?.onboarding = nil }
            onboarding = controller
        }
        onboarding?.show()
    }

    func showSettings() {
        if settings == nil { settings = SettingsWindowController(engine: hub.engine(for: Hub.defaultSession, client: nil)) }
        settings?.show()
    }
}
