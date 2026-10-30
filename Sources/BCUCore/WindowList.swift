import AppKit
import CoreGraphics

public struct WindowInfo {
    public let id: CGWindowID
    public let pid: pid_t
    public let owner: String
    public let title: String
    public let bounds: CGRect
    public let layer: Int
    public let onScreen: Bool
    public let alpha: Double
}

/// CGWindowList, which sees every window on every display and Space.
public enum WindowList {
    public static func all(onScreenOnly: Bool = false, includeDesktop: Bool = false) -> [WindowInfo] {
        var options: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly] : [.optionAll]
        if !includeDesktop { options.insert(.excludeDesktopElements) }
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap(parse)
    }

    public static func info(_ id: CGWindowID) -> WindowInfo? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] else { return nil }
        return list.compactMap(parse).first
    }

    public static func of(pid: pid_t, onScreenOnly: Bool = false) -> [WindowInfo] {
        all(onScreenOnly: onScreenOnly).filter { $0.pid == pid }
    }

    private static func parse(_ d: [String: Any]) -> WindowInfo? {
        guard let id = d[kCGWindowNumber as String] as? CGWindowID,
              let pid = d[kCGWindowOwnerPID as String] as? pid_t,
              let boundsDict = d[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
        return WindowInfo(
            id: id,
            pid: pid,
            owner: d[kCGWindowOwnerName as String] as? String ?? "",
            title: d[kCGWindowName as String] as? String ?? "",
            bounds: bounds,
            layer: d[kCGWindowLayer as String] as? Int ?? 0,
            onScreen: d[kCGWindowIsOnscreen as String] as? Bool ?? false,
            alpha: d[kCGWindowAlpha as String] as? Double ?? 1
        )
    }
}
