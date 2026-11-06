import Foundation
import BCUShared

/// The menu bar app's note of itself: where it is installed, which host
/// protocol it speaks and whether it has its permissions. The app keeps it
/// up to date while it runs.
///
/// A host app's `bcu serve` reads it. When the app is installed and set up,
/// the host starts the app and uses its engine rather than running one of
/// its own. Then the agents that use the app's own `bcu` (Claude Code,
/// Codex) show up in the menu bar and the host's agents in the host. On an
/// engine the host ran, nothing would show the app's agents.
public struct AppRecord: Equatable {
    public var path: String
    public var version: String
    public var protocolVersion: Int
    public var accessibility: Bool
    public var screenRecording: Bool

    /// This app, now.
    public static func current(bundle: Bundle = .main) -> AppRecord {
        AppRecord(path: bundle.bundleURL.path, version: BCUVersion.current,
                  protocolVersion: HostServer.protocolVersion,
                  accessibility: AX.isTrusted, screenRecording: Capture.hasPermission)
    }

    public static func read() -> AppRecord? {
        guard let data = FileManager.default.contents(atPath: BCUPaths.appRecordPath),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject,
              let path = o["path"] as? String, let proto = o["protocol"] as? Int else { return nil }
        return AppRecord(path: path, version: o["version"] as? String ?? "",
                         protocolVersion: proto,
                         accessibility: o["accessibility"] as? Bool ?? false,
                         screenRecording: o["screen_recording"] as? Bool ?? false)
    }

    public func write() {
        let o: JSONObject = ["path": path, "version": version, "protocol": protocolVersion,
                             "accessibility": accessibility, "screen_recording": screenRecording]
        guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        try? FileManager.default.createDirectory(at: BCUPaths.supportDirectory, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: BCUPaths.appRecordPath), options: .atomic)
    }

    /// Still installed there, speaks this engine's protocol, and has what it
    /// needs to run agents.
    public var isUsable: Bool {
        protocolVersion == HostServer.protocolVersion && accessibility && screenRecording
            && FileManager.default.fileExists(atPath: path)
    }
}
