import Foundation

public enum BCUVersion {
    /// The app's version: its Info.plist's inside this app, else the VERSION
    /// file it was built from (a `bcu` a host app ships inside its own bundle,
    /// whose Info.plist is the host's).
    public static let current: String = {
        if Bundle.main.bundleIdentifier == BCUPaths.bundleID,
           let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String { return v }
        let v = String(decoding: PackageResources.VERSION, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? "dev" : v
    }()
}

public enum BCUPaths {
    public static let bundleID = "dev.moulik.BackgroundComputerUse"
    public static let appName = "Background Computer Use"

    /// The engine's state, shared by every app that runs it (this app, or a
    /// host app running `bcu serve`): its socket, its lock and the windows
    /// it has open. Only one engine runs on a Mac at a time, so any agent
    /// finds it here. `BCU_HOME` moves it, for tests.
    public static var supportDirectory: URL {
        if let home = ProcessInfo.processInfo.environment["BCU_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("BackgroundComputerUse", isDirectory: true)
    }

    /// The engine listens here; `bcu` and host apps connect here.
    public static var socketPath: String {
        supportDirectory.appendingPathComponent("bcu.sock").path
    }

    /// Held by the running engine for as long as it runs.
    public static var lockPath: String {
        supportDirectory.appendingPathComponent("engine.lock").path
    }

    /// The menu bar app's note of where it is installed and whether it has
    /// its permissions (`AppRecord`).
    public static var appRecordPath: String {
        supportDirectory.appendingPathComponent("app.json").path
    }

    /// Where `Log` writes. A host app running `bcu serve` can pass its own
    /// with `--log-dir`, which sets this.
    nonisolated(unsafe) public static var logDirectoryOverride: URL?

    public static var logDirectory: URL {
        logDirectoryOverride ?? supportDirectory.appendingPathComponent("logs", isDirectory: true)
    }
}
