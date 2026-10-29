import Foundation

public enum BCUPaths {
    public static let bundleID = "dev.moulik.BackgroundComputerUse"
    public static let appName = "Background Computer Use"

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("BackgroundComputerUse", isDirectory: true)
    }

    /// The app listens here; `bcu` connects here.
    public static var socketPath: String {
        supportDirectory.appendingPathComponent("bcu.sock").path
    }

    public static var logDirectory: URL {
        supportDirectory.appendingPathComponent("logs", isDirectory: true)
    }
}
