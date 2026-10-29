import AppKit
import SwiftUI
import ServiceManagement

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(nsColor: NSColor(hex: hex, alpha: alpha))
    }
}

/// Colors with one meaning each: green is working, amber needs you,
/// gray is paused or idle, and the accent color is for controls.
enum Theme {
    static let live = Color(hex: 0x2FB457)
    static let needs = Color(hex: 0xF09A0A)
    static let needsInk = Color(nsColor: .dynamic(light: 0xC77700, dark: 0xF5A623))
    static let quiet = Color(hex: 0x8E8E93)
    /// Same gray the capture compositor paints behind the agent's windows.
    static let monitor = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let hud = Color(hex: 0x1C1C1E)
    static let ground = NSColor.dynamic(light: 0xF5F5F7, dark: 0x1E1E20)
    static let card = Color(nsColor: .dynamic(light: 0xFFFFFF, dark: 0x2A2A2C))
    static let hairline = Color.primary.opacity(0.1)
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("[bcu] launch at login: \(error)")
        }
    }
}
