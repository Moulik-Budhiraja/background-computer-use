import AppKit
import Sparkle
import BCUCore

/// Sparkle updates that never cut an agent off mid-task. Updates download in
/// the background (SUAutomaticallyUpdate) and install when the app quits, or
/// as soon as no agent has a display, a window or a call in flight. "Install
/// and Relaunch" from the update window waits for that moment too.
///
/// Restarting is safe once idle: `bcu mcp` reconnects (and relaunches the app
/// if needed) on its next call, and an idle session has nothing to lose.
final class Updater: NSObject, SPUUpdaterDelegate {
    static private(set) var shared: Updater?

    private let hub: Hub
    private var controller: SPUStandardUpdaterController!
    /// Installs the downloaded update and relaunches; set while one waits for idle.
    private var pendingInstall: (() -> Void)?
    private(set) var pendingVersion: String?
    private var idleTimer: Timer?

    init(hub: Hub) {
        self.hub = hub
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        Self.shared = self
    }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Install the waiting update now, agents or not. The user asked for it.
    func installNow() {
        pendingInstall.map { install in
            clearPending()
            install()
        }
    }

    /// No agent display, no agent window, no call running or just finished.
    private var isIdle: Bool {
        hub.activeEngines.isEmpty && !hub.isActive
    }

    private func installWhenIdle(_ item: SUAppcastItem, _ install: @escaping () -> Void) {
        pendingInstall = install
        pendingVersion = item.displayVersionString
        Log.info("update \(item.displayVersionString) is ready; installing once no agent is working")
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self, self.isIdle else { return }
            Log.info("agents are idle; installing update \(self.pendingVersion ?? "")")
            self.installNow()
        }
    }

    private func clearPending() {
        idleTimer?.invalidate()
        idleTimer = nil
        pendingInstall = nil
        pendingVersion = nil
    }

    // MARK: SPUUpdaterDelegate

    /// A silently downloaded update. Sparkle installs it on quit anyway; this
    /// also installs it once the agents are idle, so it doesn't wait for a quit
    /// that may be days away.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        installWhenIdle(item, immediateInstallHandler)
        return true
    }

    /// "Install and Relaunch" from the update window: wait while agents work.
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        if isIdle { return false }
        installWhenIdle(item, installHandler)
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let code = (error as NSError).code
        // "You're up to date" and user cancellations aren't failures.
        if code == Int(SUError.noUpdateError.rawValue) || code == Int(SUError.installationCanceledError.rawValue) { return }
        Log.info("update failed: \(error.localizedDescription)")
    }
}
