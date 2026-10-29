import AppKit
import SwiftUI
import BCUCore

/// The menu bar icon and its popover.
final class StatusController: NSObject, NSPopoverDelegate {
    private enum Icon: Equatable { case idle, working, waiting, paused }

    private let engine: Engine
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let model: PopoverModel
    private var icon: Icon?
    private var clickMonitor: Any?
    var onRefresh: (() -> Void)?

    init(engine: Engine, openSettings: @escaping () -> Void, openViewer: @escaping () -> Void) {
        self.engine = engine
        self.model = PopoverModel(engine: engine, openSettings: openSettings, openViewer: openViewer)
        super.init()
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PopoverView(model: model))
        engine.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    private func symbol(_ name: String, _ description: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)?.withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    private func refresh() {
        if popover.isShown { model.refresh() }
        onRefresh?()
        let next: Icon
        switch engine.status {
        case .paused: next = .paused
        case .waiting: next = .waiting
        default: next = engine.isActive ? .working : .idle
        }
        if next != icon {
            icon = next
            switch next {
            case .idle: item.button?.image = symbol("rectangle.dashed", "Background Computer Use: idle")
            case .working: item.button?.image = symbol("cursorarrow.motionlines", "Agent working")
            case .waiting: item.button?.image = symbol("hand.raised.fill", "Agent is waiting on you")
            case .paused: item.button?.image = symbol("pause.circle", "Agent paused")
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
            model.startPreview()
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
        model.stopPreview()
        if let m = clickMonitor {
            NSEvent.removeMonitor(m)
            clickMonitor = nil
        }
    }
}
