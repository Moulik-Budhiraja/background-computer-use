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
    override func resignKey() { super.resignKey(); log("window[\(title)] resignKey") }
}

final class Delegate: NSObject, NSApplicationDelegate {
    var windows: [LabWindow] = []
    func applicationDidFinishLaunching(_ n: Notification) {
        let screen = NSScreen.screens.first { $0.localizedName == "Agent Display" } ?? NSScreen.main!
        for (i, name) in ["A", "B"].enumerated() {
            let frame = NSRect(x: screen.frame.minX + 40 + CGFloat(i) * 520, y: screen.frame.minY + 200, width: 480, height: 300)
            let w = LabWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = name
            let scroll = NSTextView.scrollableTextView()
            (scroll.documentView as! NSTextView).string = ""
            w.contentView = scroll
            w.makeFirstResponder(scroll.documentView)
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
app.setActivationPolicy(.accessory)
app.run()
