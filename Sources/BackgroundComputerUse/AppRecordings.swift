import Foundation
import BCUCore
import BCUShared

/// The menu bar app's recordings: of the sessions it shows (those no host
/// app owns), in its own folder, with the size limit from Settings. A host
/// app chooses for its own sessions (`Hub.setRecordings`).
enum AppRecordings {
    private static let limitKey = "historyLimitMB"

    static var store = Recordings(
        directory: BCUPaths.supportDirectory.appendingPathComponent("recordings", isDirectory: true),
        limitMB: (UserDefaults.standard.object(forKey: limitKey) as? Int) ?? Recordings.defaultLimitMB)

    static func setLimit(_ mb: Int) {
        UserDefaults.standard.set(mb, forKey: limitKey)
        store.limitMB = mb
    }
}
