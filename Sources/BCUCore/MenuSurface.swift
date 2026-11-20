/// Where the menu's content is showing: the popover under the icon, or the
/// small panel used when the icon can't be seen. Both draw the same preview
/// layers, so only one can be up at a time.
public enum MenuSurface: Equatable {
    case popover, panel

    /// What has to close before `next` shows, given what's up now.
    public static func toClose(before next: MenuSurface, showing: [MenuSurface]) -> [MenuSurface] {
        showing.filter { $0 != next }
    }
}
