// KeyLab: a test app for background-input experiments. Opens two text windows
// ("A" and "B") on the agent display and logs every key event: the window
// AppKit delivered it to, the event's window number, and the key window.
import AppKit

let logPath = ProcessInfo.processInfo.environment["KEYLAB_LOG"] ?? "/tmp/keylab.log"
FileManager.default.createFile(atPath: logPath, contents: nil)
let logHandle = FileHandle(forWritingAtPath: logPath)!
func log(_ s: String) { logHandle.write(Data((s + "\n").utf8)) }

final class LabApp: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let cg = event.cgEvent
            let f51 = cg?.getIntegerValueField(CGEventField(rawValue: 51)!) ?? -1
            log("app.sendEvent keyDown chars=\(event.characters ?? "") event.windowNumber=\(event.windowNumber) event.window=\(event.window?.title ?? "nil") keyWindow=\(keyWindow?.title ?? "nil") f51=\(f51)")
        }
        super.sendEvent(event)
    }
}

final class LabWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            log("  window[\(title)].sendEvent chars=\(event.characters ?? "") isKey=\(isKeyWindow)")
            if ProcessInfo.processInfo.environment["KEYLAB_STACK"] != nil {
                for f in Thread.callStackSymbols.prefix(8) { log("    " + f) }
            }
        }
        super.sendEvent(event)
    }
    override func becomeKey() { super.becomeKey(); log("window[\(title)] becomeKey") }
    // AppKit beeps from here when nothing handles a key press (keyDown only).
    override func noResponder(for eventSelector: Selector) {
        log("  window[\(title)] noResponder(\(eventSelector))" + (eventSelector == #selector(NSResponder.keyDown(with:)) ? " -> BEEP" : ""))
        super.noResponder(for: eventSelector)
    }
    override func resignKey() { super.resignKey(); log("window[\(title)] resignKey") }
}

final class LabMenu: NSMenu {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let r = super.performKeyEquivalent(with: event)
        if supermenu == nil { log("  mainMenu.performKeyEquivalent \(event.charactersIgnoringModifiers ?? "") -> \(r) keyWindow=\(NSApp.keyWindow?.title ?? "nil") mainWindow=\(NSApp.mainWindow?.title ?? "nil") active=\(NSApp.isActive)") }
        return r
    }
}

final class LabTextView: NSTextView {
    @objc func labBold(_ sender: Any?) { log("  textView[\(window?.title ?? "")] labBold") }
    override func selectAll(_ sender: Any?) { log("  textView[\(window?.title ?? "")] selectAll"); super.selectAll(sender) }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        let r = super.validateUserInterfaceItem(item)
        log("  textView[\(window?.title ?? "")] validate \(item.action.map(NSStringFromSelector) ?? "") -> \(r)")
        return r
    }
}

func buildMenu() {
    let main = LabMenu()
    func add(_ title: String, _ items: [(String, Selector, String)]) {
        let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: title)
        for (t, sel, key) in items { sub.addItem(NSMenuItem(title: t, action: sel, keyEquivalent: key)) }
        top.submenu = sub
        main.addItem(top)
    }
    add("App", [("Quit", #selector(NSApplication.terminate(_:)), "q")])
    add("Edit", [("Select All", #selector(NSText.selectAll(_:)), "a")])
    add("Format", [("Bold", #selector(LabTextView.labBold(_:)), "b")])
    NSApp.mainMenu = main
}

final class Delegate: NSObject, NSApplicationDelegate {
    var windows: [LabWindow] = []
    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        let screen = NSScreen.screens.first { $0.localizedName == "Agent Display" } ?? NSScreen.main!
        for (i, name) in ["A", "B"].enumerated() {
            let frame = NSRect(x: screen.frame.minX + 40 + CGFloat(i) * 520, y: screen.frame.minY + 200, width: 480, height: 300)
            let w = LabWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = name
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
            let tv = LabTextView(frame: scroll.bounds)
            tv.autoresizingMask = [.width]
            tv.string = "some text in \(name)"
            scroll.documentView = tv
            scroll.hasVerticalScroller = true
            w.contentView = scroll
            w.makeFirstResponder(tv)
            windows.append(w)
            w.orderFront(nil)
        }
        windows[0].makeKey()
        log("ready A=\(windows[0].windowNumber) B=\(windows[1].windowNumber)")
    }
}

let app = LabApp.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(ProcessInfo.processInfo.environment["KEYLAB_REGULAR"] != nil ? .regular : .accessory)
app.run()
