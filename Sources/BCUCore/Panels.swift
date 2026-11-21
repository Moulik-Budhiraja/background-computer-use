import AppKit
import ApplicationServices

/// Open and save panels (a file picker, "Save As") run in a macOS service
/// process (`com.apple.appkit.xpc.openAndSavePanelService`), not in the app
/// that shows them. The app's sheet window only displays what the service
/// draws, from a window of the service's own laid exactly over it. Keys and
/// clicks posted to the app don't reach the panel, but posted to that
/// window they do, without the app's key window changing at all: the user
/// in the same app keeps typing into their own window.
public enum Panel {
    public struct Remote: Equatable {
        public let pid: pid_t
        public let window: CGWindowID
        public let frame: CGRect
    }

    /// The service window drawing the sheet window `sheet` of the app `appPid`.
    public static func remote(sheet: CGWindowID, appPid: pid_t) -> Remote? {
        guard let s = WindowList.info(sheet) else { return nil }
        return match(sheet: s, appPid: appPid, candidates: WindowList.all(), isService: isPanelService)
    }

    /// The candidate laid exactly over `sheet` by a panel service process.
    static func match(sheet: WindowInfo, appPid: pid_t, candidates: [WindowInfo], isService: (pid_t) -> Bool) -> Remote? {
        let over = candidates.filter { $0.pid != appPid && $0.id != sheet.id && $0.bounds == sheet.bounds && $0.layer == sheet.layer }
        guard let w = over.first(where: { isService($0.pid) }) else { return nil }
        return Remote(pid: w.pid, window: w.id, frame: w.bounds)
    }

    /// The window of the same service a click at `p` lands on: a sheet the
    /// panel put over itself (Go to Folder) has a window of its own.
    public static func window(of remote: Remote, at p: CGPoint) -> Remote {
        let hits = WindowList.all().filter { $0.pid == remote.pid && $0.layer == 0 && $0.bounds.contains(p) && $0.bounds.width > 64 }
        guard let best = hits.min(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) else { return remote }
        return Remote(pid: best.pid, window: best.id, frame: best.bounds)
    }

    private static var serviceCache: [pid_t: Bool] = [:]
    private static let cacheLock = NSLock()

    /// Whether `pid` is an AppKit panel service (an XPC service of AppKit's).
    static func isPanelService(_ pid: pid_t) -> Bool {
        cacheLock.lock()
        if let known = serviceCache[pid] { cacheLock.unlock(); return known }
        cacheLock.unlock()
        var buf = [CChar](repeating: 0, count: 4096)
        let path = proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
        let yes = path.contains("AppKit.framework") && path.contains(".xpc/") && path.lowercased().contains("panel")
        cacheLock.lock(); serviceCache[pid] = yes; cacheLock.unlock()
        return yes
    }

    // MARK: Reading the panel

    /// The panel's sheet nested in it, if one is up (Go to Folder).
    static func innerSheet(_ panel: AXUIElement) -> AXUIElement? {
        var queue = AX.children(panel)
        var seen = 0
        while !queue.isEmpty && seen < 400 {
            let el = queue.removeFirst()
            seen += 1
            if AX.string(el, "AXRole") == "AXSheet" { return el }
            queue.append(contentsOf: AX.children(el))
        }
        return nil
    }

    /// The first element under `root` (breadth first, not inside a nested
    /// sheet unless `root` is one) that `match` accepts.
    static func find(_ root: AXUIElement, limit: Int = 1500, _ match: (AXUIElement, String) -> Bool) -> AXUIElement? {
        var queue = AX.children(root)
        var seen = 0
        while !queue.isEmpty && seen < limit {
            let el = queue.removeFirst()
            seen += 1
            let role = AX.string(el, "AXRole") ?? ""
            if match(el, role) { return el }
            if role == "AXSheet" { continue }
            // A file list can hold thousands of rows: nothing to find in there.
            if role == "AXOutline" || role == "AXTable" || role == "AXList" || role == "AXBrowser" { continue }
            queue.append(contentsOf: AX.children(el))
        }
        return nil
    }

    /// A save panel's file name field: the panel's first settable text
    /// field with no label of its own ("tag editor" has one).
    static func nameField(_ panel: AXUIElement) -> AXUIElement? {
        find(panel) { el, role in
            role == "AXTextField" && AX.string(el, "AXSubrole") != "AXSearchField"
                && (AX.string(el, "AXDescription") ?? "").isEmpty && AX.isSettable(el, "AXValue")
        }
    }

    /// The button that answers the panel (Open, Save, Choose, Upload).
    static func defaultButton(_ panel: AXUIElement) -> AXUIElement? {
        if let b = AX.element(panel, "AXDefaultButton") { return b }
        let cancel = AX.element(panel, "AXCancelButton")
        let buttons = collect(panel) { _, role in role == "AXButton" }
            .filter { b in cancel.map { !CFEqual($0, b) } ?? true }
        let names = ["open", "save", "choose", "upload", "select", "ok", "attach", "insert", "import"]
        return buttons.last { b in names.contains((AX.string(b, "AXTitle") ?? "").lowercased()) }
    }

    static func collect(_ root: AXUIElement, limit: Int = 1500, _ match: (AXUIElement, String) -> Bool) -> [AXUIElement] {
        collect(root, axReader, limit: limit, match)
    }

    /// How `selectedNames` reads the panel: through accessibility in the
    /// app, a stand-in tree in tests.
    struct Reader<E> {
        let role: (E) -> String
        let children: (E) -> [E]
        let elements: (E, String) -> [E]
        let value: (E) -> String?
    }

    static let axReader = Reader<AXUIElement>(role: { AX.string($0, "AXRole") ?? "" }, children: { AX.children($0) },
                                              elements: { AX.elements($0, $1) }, value: { AX.string($0, "AXValue") })

    static func collect<E>(_ root: E, _ r: Reader<E>, limit: Int = 1500, _ match: (E, String) -> Bool) -> [E] {
        var out: [E] = []
        var queue = r.children(root)
        var seen = 0
        while !queue.isEmpty && seen < limit {
            let el = queue.removeFirst()
            seen += 1
            let role = r.role(el)
            if match(el, role) { out.append(el) }
            if role == "AXSheet" || role == "AXOutline" || role == "AXTable" || role == "AXList" || role == "AXBrowser" { continue }
            queue.append(contentsOf: r.children(el))
        }
        return out
    }

    /// The names of the files selected in the panel's file list.
    static func selectedNames(_ panel: AXUIElement) -> [String] {
        selectedNames(panel, axReader)
    }

    static func selectedNames<E>(_ panel: E, _ r: Reader<E>) -> [String] {
        let lists = collect(panel, r) { _, role in role == "AXOutline" || role == "AXTable" || role == "AXList" || role == "AXBrowser" }
        var names: [String] = []
        for list in lists {
            for row in r.elements(list, "AXSelectedRows") + r.elements(list, "AXSelectedChildren") {
                if let n = firstText(row, r) { names.append(n) }
            }
        }
        return names
    }

    private static func firstText<E>(_ el: E, _ r: Reader<E>) -> String? {
        var queue = [el]
        var seen = 0
        while !queue.isEmpty && seen < 30 {
            let e = queue.removeFirst()
            seen += 1
            let role = r.role(e)
            if role == "AXTextField" || role == "AXStaticText", let v = r.value(e), !v.isEmpty { return v }
            queue.append(contentsOf: r.children(e))
        }
        return nil
    }

    /// Whether the panel saves rather than opens: only a save panel has a
    /// file name field. (Its labels are in the user's language.)
    static func isSavePanel(_ panel: AXUIElement) -> Bool {
        nameField(panel) != nil
    }

    /// `path` with `~` expanded and `.` and `..` resolved.
    public static func resolve(_ path: String) -> String {
        (NSString(string: path).expandingTildeInPath as NSString).standardizingPath
    }
}
