import AppKit
import CPrivate

/// A still copy of the user's window and of the menu bar, shown over them
/// while the agent's window of the same app briefly holds key focus.
///
/// Keys and pixel clicks only reach an app's key window, so the agent's
/// window has to take key focus from the user's for a moment. The app then
/// draws the user's window as inactive (grey traffic lights, no focus ring,
/// a lighter shadow) and the menu bar's app menus dim, until key comes back
/// 100–300 ms later. With the copies on top, the user sees neither.
///
/// The copies are what the screen showed just before, shadow and rim
/// included, in borderless click-through panels: the window's right above
/// it, so windows above it stay above (and are cut out of it), and the menu
/// bar's (status items included, they dim too) in front of the status items.
/// They come off once the window and the menu bar look as they did before.
final class ScreenFreeze {
    private struct Cover {
        let panel: NSPanel
        let windowID: CGWindowID
        /// The window's own pixels before.
        let own: CGImage
        /// The same, small, to tell when it's back.
        var before: [UInt8] = []
    }

    private var covers: [Cover] = []
    private var captureMs = 0.0, shownMs = 0.0
    private static var pool: [NSPanel] = []

    /// Room around the window for its shadow, which is larger while it's key.
    private static let shadowMargin: CGFloat = 64

    /// Long enough for WindowServer to put the copies on screen (one frame at
    /// 60 Hz is 16.7 ms) before anything under them changes.
    private static let showMs: Double = 30

    /// Cover `userWindow` (the app's key window, on the user's display) and
    /// the menu bar above it. Nil when neither is on screen.
    static func begin(userWindow: CGWindowID) -> ScreenFreeze? {
        let t0 = nowMs()
        guard let info = WindowList.info(userWindow), info.onScreen, info.alpha > 0,
              !AgentDisplay.running.contains(where: { $0.liveBounds.intersects(info.bounds) }) else { return nil }
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(CGPoint(x: info.bounds.midX, y: info.bounds.midY), 1, &display, &count)
        guard count == 1 else { return nil }
        let screen = CGDisplayBounds(display)
        let bars = menuBars()
        var shots: [(image: CGImage, own: CGImage, rect: CGRect, id: CGWindowID, level: NSWindow.Level)] = []

        // The window as the screen shows it, with its shadow and rim (which
        // change too, and aren't in the window's own pixels), but not the
        // menu bar strip: that's covered separately. Windows in front of the
        // user's window are cut out, so translucent ones (the Dock, a
        // notification) keep showing what's really behind them.
        if let own = BCUCaptureWindow(userWindow) {
            var area = info.bounds.insetBy(dx: -shadowMargin, dy: -shadowMargin).intersection(screen)
            if let bar = bars.first(where: { $0.bar.bounds.intersects(area) }), area.minY < bar.bar.bounds.maxY {
                area = CGRect(x: area.minX, y: bar.bar.bounds.maxY, width: area.width, height: max(0, area.maxY - bar.bar.bounds.maxY))
            }
            let infront = WindowList.above(userWindow).filter { $0.alpha > 0 && $0.bounds.intersects(area) }
            // A window covering the whole display (Notification Center's) is
            // mostly empty: cut out only the notifications it shows.
            // With room for their shadows and blur, which reach past their frames.
            let holes = (infront.filter { !$0.bounds.contains(screen) }.map(\.bounds)
                + notifications(in: infront.filter { $0.bounds.contains(screen) })).map { $0.insetBy(dx: -40, dy: -40) }
            if let around = capture(display, screen: screen, area), let image = cutOut(holes, from: around, area: area, window: own, frame: info.bounds) {
                shots.append((image, own, area, userWindow, .normal))
            } else if let inner = crop(own, from: info.bounds, to: info.bounds.insetBy(dx: 1, dy: 1)) {
                // No screen copy: the window's own pixels, inside its rim.
                shots.append((inner, own, info.bounds.insetBy(dx: 1, dy: 1), userWindow, .normal))
            }
        }
        // Every menu bar on the user's displays (which one dims depends on the
        // Spaces setup), status items included: they dim with it.
        for (bar, barDisplay) in bars {
            guard let own = BCUCaptureWindow(bar.id) else { continue }
            if let image = capture(barDisplay, screen: CGDisplayBounds(barDisplay), bar.bounds) {
                shots.append((image, own, bar.bounds, bar.id, .statusBar))
            } else if let menus = appMenus(of: bar), let image = crop(own, from: bar.bounds, to: menus) {
                // No screen copy: the menu bar's own pixels hold the app
                // menus but not the status items, which are windows of their own.
                shots.append((image, own, menus, bar.id, .statusBar))
            }
        }
        guard !shots.isEmpty else { return nil }
        let t1 = nowMs()
        let freeze = ScreenFreeze()
        onMain {
            for (image, own, rect, id, level) in shots {
                let panel = pool.popLast() ?? makePanel()
                panel.level = level
                panel.setFrame(cocoaRect(rect), display: false)
                panel.contentView?.layer?.contents = image
                // Right above the window it copies: windows above that stay
                // above. The menu bar's copy goes in front of the status items.
                if level == .normal { panel.order(.above, relativeTo: Int(id)) } else { panel.orderFrontRegardless() }
                freeze.covers.append(Cover(panel: panel, windowID: id, own: own))
            }
            CATransaction.flush()
        }
        freeze.shownMs = nowMs() - t0
        freeze.captureMs = t1 - t0
        // While WindowServer puts them on screen.
        let shown = nowMs()
        for i in freeze.covers.indices { freeze.covers[i].before = thumbnail(freeze.covers[i].own) }
        sleepMs(showMs - (nowMs() - shown))
        return freeze
    }

    /// Take the copies off once the windows under them look as they did, or
    /// after `timeoutMs` (the window may have changed for its own reasons).
    func end(timeoutMs: Double = 500) {
        guard !covers.isEmpty else { return }
        let start = nowMs()
        let deadline = start + timeoutMs
        var waiting = covers
        var worst: [CGWindowID: Int] = [:]
        while !waiting.isEmpty && nowMs() < deadline {
            waiting.removeAll { cover in
                guard let now = BCUCaptureWindow(cover.windowID) else { return true }
                let d = Self.difference(Self.thumbnail(now), cover.before)
                worst[cover.windowID] = d
                return d <= Self.allowedDifference
            }
            if !waiting.isEmpty { sleepMs(8) }
        }
        Log.info("freeze: copies up after \(Int(shownMs)) ms (\(Int(captureMs)) ms capturing), windows back \(Int(nowMs() - start)) ms after the swap\(waiting.isEmpty ? "" : ", gave up waiting on \(waiting.map { "\($0.windowID) (\(worst[$0.windowID] ?? -1) px differ)" }.joined(separator: ", "))")")
        // One more frame so the window's restored pixels are on screen, not just in its buffer.
        sleepMs(17)
        let panels = covers.map(\.panel)
        covers.removeAll()
        Self.onMain {
            for p in panels {
                p.orderOut(nil)
                p.contentView?.layer?.contents = nil
                Self.pool.append(p)
            }
            CATransaction.flush()
        }
    }

    // MARK: Helpers

    private static func onMain(_ work: () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSView()
        view.wantsLayer = true
        view.layer?.contentsGravity = .resize
        p.contentView = view
        return p
    }

    /// Global (top-left origin) rect to AppKit's bottom-left origin.
    private static func cocoaRect(_ r: CGRect) -> NSRect {
        let primary = CGDisplayBounds(CGMainDisplayID())
        return NSRect(x: r.minX, y: primary.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// The part of a window image (covering `from`) that shows `to`.
    private static func crop(_ image: CGImage, from: CGRect, to: CGRect) -> CGImage? {
        guard from.width > 0, from.height > 0 else { return nil }
        let sx = CGFloat(image.width) / from.width, sy = CGFloat(image.height) / from.height
        let r = CGRect(x: (to.minX - from.minX) * sx, y: (to.minY - from.minY) * sy, width: to.width * sx, height: to.height * sy).integral
        return image.cropping(to: r)
    }

    /// What the screen shows in `rect` (global points).
    private static func capture(_ display: CGDirectDisplayID, screen: CGRect, _ rect: CGRect) -> CGImage? {
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        return BCUCaptureDisplayRect(display, rect.offsetBy(dx: -screen.minX, dy: -screen.minY))
    }

    /// The screen copy `image` (of `area`) with `holes` (global rects) cut
    /// out, and filled with the user's window as it was (its own pixels,
    /// inside its rim) where the window is behind them: what translucent
    /// windows in front blurred before the swap.
    private static func cutOut(_ holes: [CGRect], from image: CGImage, area: CGRect, window: CGImage, frame: CGRect) -> CGImage? {
        guard !holes.isEmpty else { return image }
        let scale = CGFloat(image.width) / area.width
        guard let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        func local(_ r: CGRect) -> CGRect {
            CGRect(x: (r.minX - area.minX) * scale, y: (area.maxY - r.maxY) * scale, width: r.width * scale, height: r.height * scale)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        for r in holes { ctx.clear(local(r)) }
        let inner = frame.insetBy(dx: 1, dy: 1)
        let behind = holes.map { $0.intersection(inner) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        if !behind.isEmpty {
            ctx.clip(to: behind.map(local))
            ctx.draw(window, in: local(frame))
        }
        return ctx.makeImage()
    }

    /// Notifications on screen in these windows: Notification Center draws
    /// them in a window as big as the display, so they're found through
    /// accessibility.
    private static func notifications(in windows: [WindowInfo]) -> [CGRect] {
        var frames: [CGRect] = []
        for pid in Set(windows.map(\.pid)) {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.1)
            func walk(_ el: AXUIElement, _ depth: Int) {
                if (AX.string(el, "AXSubrole") ?? "").hasPrefix("AXNotificationCenter"), let f = AX.frame(el) {
                    frames.append(f)
                    return
                }
                guard depth < 6 else { return }
                for child in AX.children(el) { walk(child, depth + 1) }
            }
            for w in AX.elements(app, "AXWindows") { walk(w, 0) }
        }
        return frames
    }

    /// The part of a menu bar left of its status items.
    private static func appMenus(of bar: WindowInfo) -> CGRect? {
        let items = WindowList.all(onScreenOnly: true).filter {
            $0.layer == Int(CGWindowLevelForKey(.statusWindow)) && $0.bounds.intersects(bar.bounds) && $0.bounds.minX > bar.bounds.minX
        }
        let right = items.map(\.bounds.minX).min() ?? bar.bounds.midX
        return right > bar.bounds.minX ? CGRect(x: bar.bounds.minX, y: bar.bounds.minY, width: right - bar.bounds.minX, height: bar.bounds.height) : nil
    }

    /// The menu bars on the user's displays that are showing, with their display.
    private static func menuBars() -> [(bar: WindowInfo, display: CGDirectDisplayID)] {
        let onScreen = WindowList.all(onScreenOnly: true)
        return AgentDisplay.userDisplayIDs().compactMap { id in
            let screen = CGDisplayBounds(id)
            guard let bar = onScreen.first(where: { w in
                w.owner == "Window Server" && w.title == "Menubar" && w.bounds.height < 60
                    && w.bounds.minY == screen.minY && w.bounds.midX > screen.minX && w.bounds.midX < screen.maxX
            }) else { return nil }
            return (bar, id)
        }
    }

    /// A copy at about half size, for comparing: fine enough that a 2 px
    /// focus ring or the traffic lights changing shows.
    private static func thumbnail(_ image: CGImage) -> [UInt8] {
        let w = max(1, min(1024, image.width / 2)), h = max(1, image.height * w / max(1, image.width))
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return buf
    }

    /// How many thumbnail pixels may differ for it to be the same picture: a
    /// blinking caret can differ, a window drawn inactive can't.
    private static let allowedDifference = 24

    private static func difference(_ a: [UInt8], _ b: [UInt8]) -> Int {
        guard a.count == b.count else { return Int.max }
        var differing = 0
        var i = 0
        while i < a.count {
            if abs(Int(a[i]) - Int(b[i])) > 24 || abs(Int(a[i + 1]) - Int(b[i + 1])) > 24 || abs(Int(a[i + 2]) - Int(b[i + 2])) > 24 {
                differing += 1
            }
            i += 4
        }
        return differing
    }
}
