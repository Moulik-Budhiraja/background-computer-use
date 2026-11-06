import AppKit
import CoreServices

/// Chromium browsers can be told where to build a new window (AppleScript's
/// `make new window with properties {bounds:…}`), so it opens straight on
/// the agent display and never shows on the user's screen. That needs the
/// user's OK for this app to control the browser (Automation), asked once
/// per browser: during setup for their default browser, else the first time
/// an agent opens one of its windows.
public enum BrowserAutomation {
    public enum Permission { case allowed, denied, notAsked }

    /// A Chromium browser: "<Name> Framework.framework" and Chrome's scripting
    /// dictionary, with its scriptable window class.
    public static func isScriptableChromium(_ app: URL) -> Bool {
        let frameworks = (try? FileManager.default.contentsOfDirectory(atPath: app.appendingPathComponent("Contents/Frameworks").path)) ?? []
        guard frameworks.contains(where: { $0.hasSuffix(" Framework.framework") }),
              let sdef = try? String(contentsOf: app.appendingPathComponent("Contents/Resources/scripting.sdef"), encoding: .utf8) else { return false }
        return sdef.contains("<class name=\"window\"")
    }

    /// The user's default browser, when it's one whose windows can be placed.
    public static func defaultBrowser() -> (name: String, bundleID: String, url: URL)? {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!),
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, isScriptableChromium(url) else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return (name, id, url)
    }

    private static let pendingLock = NSLock()
    /// Browsers macOS is asking the user about right now, with everyone
    /// waiting for the answer.
    private static var pending: [String: [(Permission) -> Void]] = [:]

    /// Whether this app may control `bundleID`, without asking. macOS can only
    /// tell while the app runs; otherwise `notAsked`. While macOS is asking
    /// the user, also `notAsked`: checking then blocks until they answer.
    public static func permission(_ bundleID: String) -> Permission {
        pendingLock.lock()
        let asking = pending[bundleID] != nil
        pendingLock.unlock()
        if asking { return .notAsked }
        switch determine(bundleID, ask: false) {
        case noErr: return .allowed
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .notAsked
        }
    }

    /// Ask the user (macOS shows its prompt), launching the browser hidden
    /// first if it isn't running, since macOS can only ask about a running app.
    /// Calls back on the main thread.
    public static func request(_ bundleID: String, app: URL? = nil, completion: @escaping (Permission) -> Void) {
        pendingLock.lock()
        let already = pending[bundleID] != nil
        pending[bundleID, default: []].append(completion)
        pendingLock.unlock()
        // One prompt at a time per browser; everyone gets its answer.
        if already { return }
        DispatchQueue.global(qos: .userInitiated).async {
            if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty,
               let url = app ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                config.hides = true
                config.addsToRecentItems = false
                NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
                let deadline = Date().addingTimeInterval(10)
                while NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty && Date() < deadline { usleep(100_000) }
            }
            let status = determine(bundleID, ask: true)
            let result: Permission = status == noErr ? .allowed : (status == OSStatus(errAEEventNotPermitted) ? .denied : .notAsked)
            Log.info("control of \(bundleID): \(result)")
            pendingLock.lock()
            let waiting = pending.removeValue(forKey: bundleID) ?? []
            pendingLock.unlock()
            DispatchQueue.main.async { waiting.forEach { $0(result) } }
        }
    }

    private static func determine(_ bundleID: String, ask: Bool) -> OSStatus {
        var target = AEAddressDesc()
        let id = Array(bundleID.utf8)
        guard AECreateDesc(DescType(typeApplicationBundleID), id, id.count, &target) == noErr else { return OSStatus(procNotFound) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
    }
}
