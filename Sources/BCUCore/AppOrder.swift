import AppKit

/// The order cmd+Tab cycles through: LaunchServices' front-to-back app list.
/// Any activation moves an app up it, even one the guard undoes 10 ms later,
/// so after Chromium takes the front during an agent step it sits second and
/// the user's next cmd+Tab lands on it instead of the app they came from.
enum AppOrder {
    private typealias CopyOrder = @convention(c) (Int32, UInt32) -> Unmanaged<CFArray>?
    private typealias InfoItem = @convention(c) (Int32, CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private static let defaultSession: Int32 = -2

    private static let fns: (CopyOrder, InfoItem)? = {
        let h = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY)
        guard let order = dlsym(h, "_LSCopyApplicationArrayInFrontToBackOrder"),
              let item = dlsym(h, "_LSCopyApplicationInformationItem") else { return nil }
        return (unsafeBitCast(order, to: CopyOrder.self), unsafeBitCast(item, to: InfoItem.self))
    }()

    /// The first `count` apps, front first (about 1 ms). Empty if unavailable.
    static func frontToBack(_ count: Int = 4) -> [pid_t] {
        guard let (copyOrder, item) = fns, let list = copyOrder(defaultSession, UInt32.max)?.takeRetainedValue() as? [AnyObject] else { return [] }
        return list.prefix(count).compactMap { asn in
            (item(defaultSession, asn, "pid" as CFString)?.takeRetainedValue() as? NSNumber).map { pid_t($0.int32Value) }
        }
    }

    /// The order needs repairing when the user's app is in front but the app
    /// second to it is no longer the one before the agent's step, and the
    /// newcomer is an app the guard had to push back (`intruders`).
    /// Returns the app to put back in second place.
    static func displaced(before: [pid_t], now: [pid_t], intruders: Set<pid_t>) -> pid_t? {
        guard before.count >= 2, now.count >= 2, before[0] == now[0], now[0] != now[1] else { return nil }
        let second = before[1]
        guard now[1] != second, intruders.contains(now[1]), !intruders.contains(second), now.contains(second) else { return nil }
        return second
    }
}
