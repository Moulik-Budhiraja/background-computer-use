import AppKit
import Sparkle
import BCUCore

/// Sparkle updates that never cut an agent off mid-task. Updates download in
/// the background (SUAutomaticallyUpdate) and install when the app quits, or
/// once every agent has gone quiet (`UpdateGate`) and the user isn't in Setup
/// or Settings. "Install and Relaunch" from the update window waits for that
/// moment too. The popover says while one waits.
///
/// Restarting is safe once idle: `bcu mcp` reconnects (and relaunches the app
/// if needed) on its next call, and an idle session has nothing to lose.
final class Updater: NSObject, SPUUpdaterDelegate {
    static private(set) var shared: Updater?

    private let hub: Hub
    private let setupOpen: () -> Bool
    private var controller: SPUStandardUpdaterController!
    /// Installs the downloaded update and relaunches; set while one waits for idle.
    private var pendingInstall: (() -> Void)?
    private(set) var pendingVersion: String?
    private var idleTimer: Timer?

    init(hub: Hub, setupOpen: @escaping () -> Bool) {
        self.hub = hub
        self.setupOpen = setupOpen
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

    /// No call running or just finished, and any session with windows open
    /// quiet for a long while; nothing waiting on the user.
    private var isIdle: Bool {
        UpdateGate.canInstall(hub.engines.map(UpdateGate.Session.init), setupOpen: setupOpen())
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
