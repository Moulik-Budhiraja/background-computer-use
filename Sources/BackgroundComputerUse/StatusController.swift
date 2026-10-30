import AppKit
import SwiftUI
import BCUCore

/// The menu bar icon and its popover.
final class StatusController: NSObject, NSPopoverDelegate {
    private enum Icon: Equatable { case idle, working, waiting, paused }

    private let hub: Hub
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let model: MenuModel
    private var icon: Icon?
    private var clickMonitor: Any?
    var onRefresh: (() -> Void)?

    /// `openViewer(engine, takeOver)` expands one session's display.
    init(hub: Hub, openSettings: @escaping () -> Void, openViewer: @escaping (Engine, Bool) -> Void) {
        self.hub = hub
        self.model = MenuModel(hub: hub, openSettings: openSettings, openViewer: openViewer)
        super.init()
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let hosting = NSHostingController(rootView: PopoverView(menu: model))
        // The popover grows with the number of agent displays.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        hub.onChange = { [weak self] in self?.refresh() }
        refresh()
    }


    private func refresh() {
        if popover.isShown { model.refresh() }
        onRefresh?()
        let next: Icon
        switch hub.status {
        case .paused, .userInControl: next = .paused
        case .waiting: next = .waiting
        default: next = hub.isActive ? .working : .idle
        }
        if next != icon {
            icon = next
            switch next {
            case .idle: item.button?.image = MenuBarGlyph.image(.idle, "Background Computer Use: idle")
            case .working: item.button?.image = MenuBarGlyph.image(.working, "Agent working")
            case .waiting: item.button?.image = MenuBarGlyph.image(.waiting, "Agent is waiting on you")
            case .paused: item.button?.image = MenuBarGlyph.image(.paused, "Agent paused")
            }
        }
        item.button?.toolTip = model.statusText
    }

    @objc private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.refresh()
            model.startPreviews()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // The app never activates, so .transient alone doesn't close the
            // popover on outside clicks. Watch for them instead.
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                self?.close()
            }
        }
    }

    func close() {
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        model.stopPreviews()
        if let m = clickMonitor {
            NSEvent.removeMonitor(m)
            clickMonitor = nil
        }
    }
}

/// One display shape with a mark for each state, drawn as 18pt template
/// images so they follow the menu bar's light and dark appearance.
enum MenuBarGlyph {
    enum Kind { case idle, working, waiting, paused }

    static func image(_ kind: Kind, _ description: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            let display = NSBezierPath(roundedRect: NSRect(x: 1.75, y: 3.25, width: 14.5, height: 10), xRadius: 2.25, yRadius: 2.25)
            display.lineWidth = 1.5
            switch kind {
            case .idle:
                display.stroke()
            case .working:
                display.stroke()
                let cursor = NSBezierPath()
                cursor.move(to: NSPoint(x: 9.6, y: 7.2))
                for p in [(9.6, 14.8), (11.5, 13.0), (12.8, 16.0), (14.1, 15.45), (12.8, 12.5), (15.4, 12.4)] {
                    cursor.line(to: NSPoint(x: p.0, y: p.1))
                }
                cursor.close()
                cursor.lineJoinStyle = .round
                cursor.fill()
                // Cut a gap around the cursor where it crosses the display outline.
                NSGraphicsContext.current?.compositingOperation = .clear
                cursor.lineWidth = 1.1
                cursor.stroke()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            case .waiting:
                let r: CGFloat = 2.25
                let outline = NSBezierPath()
                outline.move(to: NSPoint(x: 11.2, y: 3.25))
                outline.appendArc(from: NSPoint(x: 1.75, y: 3.25), to: NSPoint(x: 1.75, y: 13.25), radius: r)
                outline.appendArc(from: NSPoint(x: 1.75, y: 13.25), to: NSPoint(x: 16.25, y: 13.25), radius: r)
                outline.appendArc(from: NSPoint(x: 16.25, y: 13.25), to: NSPoint(x: 16.25, y: 3.25), radius: r)
                outline.line(to: NSPoint(x: 16.25, y: 8.6))
                outline.lineWidth = 1.5
                outline.lineCapStyle = .round
                outline.stroke()
                NSBezierPath(ovalIn: NSRect(x: 14.6 - 2.6, y: 3.9 - 2.6, width: 5.2, height: 5.2)).fill()
            case .paused:
                display.stroke()
                NSBezierPath(roundedRect: NSRect(x: 6.4, y: 5.9, width: 1.8, height: 4.7), xRadius: 0.6, yRadius: 0.6).fill()
                NSBezierPath(roundedRect: NSRect(x: 9.8, y: 5.9, width: 1.8, height: 4.7), xRadius: 0.6, yRadius: 0.6).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }
}
