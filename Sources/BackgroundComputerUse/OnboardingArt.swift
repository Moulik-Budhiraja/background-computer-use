import SwiftUI
import BCUShared

/// The pictures at the top of each setup step. They're drawn at a fixed
/// 592 × 280 on the navy of the app icon.
enum Art {
    static let size = CGSize(width: 592, height: 280)
    static let navy = LinearGradient(colors: [Color(hex: 0x22355C), Color(hex: 0x0E1729)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)
    static let agentGreen = LinearGradient(colors: [Color(hex: 0x4BD67A), Color(hex: 0x1E9447)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
    static let bar = Color(hex: 0xE9EDF3)
    static let barStrong = Color(hex: 0xDDE3EC)
    static let dot = Color(hex: 0xCBD3E1)
    static let blue = Color(hex: 0x007AFF)
}

struct ArtStage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            Art.navy
            content
        }
        .frame(width: Art.size.width, height: Art.size.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// The arrow pointer, in a 54 × 86 box.
struct PointerShape: Shape {
    func path(in rect: CGRect) -> Path {
        let pts: [(CGFloat, CGFloat)] = [(2, 2), (2, 74), (19, 58), (31, 86), (43, 81), (31, 54), (54, 54)]
        var p = Path()
        for (i, pt) in pts.enumerated() {
            let point = CGPoint(x: rect.minX + pt.0 / 54 * rect.width, y: rect.minY + pt.1 / 86 * rect.height)
            if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
        }
        p.closeSubpath()
        return p
    }
}

struct Pointer: View {
    var fill: Color = Color(hex: 0x1D1D1F)
    var stroke: Color = .white
    var width: CGFloat = 20

    var body: some View {
        let h = width * 86 / 54
        ZStack {
            PointerShape().stroke(stroke, style: StrokeStyle(lineWidth: width / 9, lineJoin: .round))
            PointerShape().fill(fill)
        }
        .frame(width: width, height: h)
    }
}

/// Window chrome dots and placeholder text lines.
private struct WindowSketch: View {
    var dot: CGFloat = 8
    var widths: [CGFloat] = [124, 184, 152]
    var barHeight: CGFloat = 9

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: dot * 0.75) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(Art.dot).frame(width: dot, height: dot) }
            }
            ForEach(Array(widths.enumerated()), id: \.offset) { i, w in
                Capsule().fill(i == 0 ? Art.barStrong : Art.bar).frame(width: w, height: barHeight)
            }
        }
    }
}

// MARK: Welcome

/// Your window in front, the agent's display behind it, marked hidden.
struct WelcomeArt: View {
    var body: some View {
        ArtStage {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Art.agentGreen)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Theme.live.opacity(0.2)).padding(-6))
                    .shadow(color: Theme.live.opacity(0.25), radius: 22, y: 14)
                    .frame(width: 260, height: 164)
                    .offset(x: 191, y: 40)
                Pointer(fill: .white, stroke: Color(hex: 0x17733A), width: 14)
                    .offset(x: 413, y: 50)
                WindowSketch()
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
                    .frame(width: 260, height: 164, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.white))
                    .compositingGroup()
            .shadow(color: .black.opacity(0.35), radius: 18, y: 14)
                    .offset(x: 141, y: 70)
                ZStack {
                    Circle().fill(Color(hex: 0x0E1729))
                    Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1)
                    Image(systemName: "eye.slash").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                }
                .frame(width: 30, height: 30)
                .offset(x: 435, y: 26)
            }
        }
    }
}

// MARK: System Settings

/// A small System Settings window showing the switch to turn on.
struct PrivacyPaneArt: View {
    enum Pane { case accessibility, screenRecording }
    let pane: Pane
    let isOn: Bool

    private var title: String { pane == .accessibility ? "Accessibility" : "Screen & System Audio Recording" }
    private var caption: String {
        pane == .accessibility
            ? "Allow the applications below to control your computer."
            : "Allow the applications below to record the content of your screen and audio."
    }
    private var others: [(String, Color)] {
        pane == .accessibility
            ? [("Terminal", Color(hex: 0x3A3A3C)), ("Raycast", Color(hex: 0xFF6363))]
            : [("Zoom", Color(hex: 0x2D8CFF)), ("CleanShot X", Color(hex: 0x1F2A44))]
    }

    var body: some View {
        ArtStage {
            HStack(spacing: 0) {
                sidebar
                Rectangle().fill(Color.black.opacity(0.1)).frame(width: 0.5)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text("‹").font(.system(size: 13)).foregroundStyle(Color(hex: 0xAEAEB2))
                        Text(title).font(.system(size: 12, weight: .bold)).foregroundStyle(Color(hex: 0x1D1D1F))
                    }
                    Text(caption).font(.system(size: 9.5)).foregroundStyle(Color(hex: 0x6E6E73))
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 0) {
                        row(others[0].0, icon: AnyView(RoundedRectangle(cornerRadius: 4).fill(others[0].1)), on: true)
                        ours
                        row(others[1].0, icon: AnyView(RoundedRectangle(cornerRadius: 4).fill(others[1].1)), on: true)
                    }
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color(hex: 0xF5F5F7)))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 420, height: 268)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
            .compositingGroup()
            .shadow(color: .black.opacity(0.35), radius: 20, y: 14)
            .offset(x: 86, y: 56)

            if !isOn {
                Pointer().offset(x: 459, y: 174)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(Color(hex: 0xFF5F57)).frame(width: 8, height: 8)
                Circle().fill(Color(hex: 0xFEBC2E)).frame(width: 8, height: 8)
                Circle().fill(Color(hex: 0x28C840)).frame(width: 8, height: 8)
            }
            .padding(.leading, 4)
            .padding(.bottom, 10)
            sideItem("General", Color(hex: 0x8E8E93))
            sideItem("Accessibility", Color(hex: 0x0A84FF))
            sideItem("Privacy & Security", .white, selected: true)
            sideItem("Desktop & Dock", Color(hex: 0x34C759))
            sideItem("Displays", Color(hex: 0x5E5CE6))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .frame(width: 140, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(Color(hex: 0xEDEDF0))
    }

    private func sideItem(_ name: String, _ color: Color, selected: Bool = false) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 12, height: 12)
            Text(name)
                .font(.system(size: 10, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Color.white : Color(hex: 0x1D1D1F))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Art.blue : .clear))
    }

    private var ours: some View {
        let ring = isOn ? Theme.live : Art.blue
        return row("Background Computer Use", icon: AnyView(MiniAppIcon()), on: isOn, bold: true)
            .background(RoundedRectangle(cornerRadius: 6).fill(ring.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ring, lineWidth: 1.5))
    }

    private func row(_ name: String, icon: AnyView, on: Bool, bold: Bool = false) -> some View {
        HStack(spacing: 8) {
            icon.frame(width: 16, height: 16)
            Text(name)
                .font(.system(size: 10.5, weight: bold ? .medium : .regular))
                .foregroundStyle(Color(hex: 0x1D1D1F))
            Spacer(minLength: 0)
            MiniSwitch(on: on)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
    }
}

private struct MiniSwitch: View {
    let on: Bool
    var body: some View {
        Capsule()
            .fill(on ? Art.blue : Color.black.opacity(0.12))
            .frame(width: 26, height: 15)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(.white).frame(width: 12, height: 12)
                    .compositingGroup()
            .shadow(color: .black.opacity(0.25), radius: 0.75, y: 0.5)
                    .padding(1.5)
            }
    }
}

/// The app icon at 16 pt: your window and the agent's screen behind it.
private struct MiniAppIcon: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(Art.navy)
            RoundedRectangle(cornerRadius: 1.5).fill(Theme.live).frame(width: 8, height: 7).offset(x: 6, y: 6)
            RoundedRectangle(cornerRadius: 1.5).fill(.white).frame(width: 8, height: 7).offset(x: 2.5, y: 3)
        }
        .frame(width: 16, height: 16)
    }
}

// MARK: Connect

struct AgentLogo: View {
    let agent: AgentKind

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(agent == .claude ? Color(hex: 0xD97757) : Color(hex: 0x111111))
            switch agent {
            case .claude:
                Path { p in
                    let c = CGPoint(x: 16, y: 16), r: CGFloat = 7
                    for angle in stride(from: 0.0, to: 180.0, by: 45.0) {
                        let a = angle * .pi / 180
                        p.move(to: CGPoint(x: c.x - r * cos(a), y: c.y - r * sin(a)))
                        p.addLine(to: CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a)))
                    }
                }
                .stroke(.white, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            case .codex:
                Path { p in
                    p.move(to: CGPoint(x: 10, y: 11)); p.addLine(to: CGPoint(x: 14.5, y: 15.5)); p.addLine(to: CGPoint(x: 10, y: 20))
                    p.move(to: CGPoint(x: 17, y: 20)); p.addLine(to: CGPoint(x: 22.5, y: 20))
                }
                .stroke(.white, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: 32, height: 32)
    }
}

/// One pickable agent on the Connect step.
struct AgentCard: View {
    let agent: AgentKind
    let installed: Bool
    let connected: Bool
    let selected: Bool
    let busy: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                AgentLogo(agent: agent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.displayName).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(hex: 0x1D1D1F))
                    if !installed {
                        Text("Not on this Mac").font(.system(size: 11)).foregroundStyle(Color(hex: 0x6E6E73))
                    }
                }
                Spacer(minLength: 0)
                trailing
            }
            .padding(18)
            .frame(width: 220)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Art.blue, lineWidth: selected && !connected ? 2 : 0))
            .compositingGroup()
            .shadow(color: .black.opacity(0.35), radius: 16, y: 12)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .opacity(installed ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        // Not `.disabled`, which would also dim a connected card.
        .allowsHitTesting(installed && !connected && !busy)
    }

    @ViewBuilder private var trailing: some View {
        if connected {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(Theme.live)
        } else if busy && selected {
            ProgressView().controlSize(.small)
        } else {
            Checkbox(on: selected)
        }
    }
}

struct Checkbox: View {
    let on: Bool
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28)
                .fill(on ? Art.blue : Color.white)
            RoundedRectangle(cornerRadius: size * 0.28)
                .strokeBorder(on ? Color.clear : Color.black.opacity(0.25), lineWidth: 1)
            if on {
                Image(systemName: "checkmark").font(.system(size: size * 0.55, weight: .bold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: Done

/// The menu bar with the working icon and its popover open.
struct MenuBarArt: View {
    let agentName: String

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE MMM d h:mm a")
        return f
    }()

    var body: some View {
        ArtStage {
            HStack(spacing: 14) {
                Spacer()
                Image(nsImage: MenuBarGlyph.image(.working, "Agent working"))
                    .renderingMode(.template)
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 20)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.2)))
                Image(systemName: "wifi").font(.system(size: 12, weight: .semibold))
                Image(systemName: "battery.100").font(.system(size: 14))
                Text(Self.clock.string(from: Date()))
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(width: Art.size.width, height: 26)
            .background(Color.white.opacity(0.12))

            popover.offset(x: 215, y: 36)
        }
    }

    private var popover: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Circle().fill(Theme.live).frame(width: 8, height: 8)
                (Text(agentName).fontWeight(.medium).foregroundColor(Color(hex: 0x1D1D1F))
                 + Text(" · Working").foregroundColor(Color(hex: 0x6E6E73)))
                    .font(.system(size: 12))
                Spacer()
                Image(systemName: "pause.fill").font(.system(size: 9))
                Image(systemName: "stop.fill").font(.system(size: 9))
            }
            .foregroundStyle(Color(hex: 0xAEAEB2))
            .padding(.horizontal, 4)
            .frame(height: 22)

            ZStack(alignment: .topLeading) {
                Theme.hud
                VStack(spacing: 0) {
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { _ in Circle().fill(Art.dot).frame(width: 5, height: 5) }
                        RoundedRectangle(cornerRadius: 3).fill(.white).frame(height: 9).padding(.leading, 10)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(Color(hex: 0xF0F0F2))
                    VStack(alignment: .leading, spacing: 7) {
                        Capsule().fill(Art.barStrong).frame(width: 90, height: 7)
                        Capsule().fill(Art.bar).frame(width: 160, height: 7)
                        Capsule().fill(Art.bar).frame(width: 130, height: 7)
                        RoundedRectangle(cornerRadius: 4).fill(Theme.live).frame(width: 64, height: 16).padding(.top, 4)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                }
                .frame(width: 232, height: 150)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .offset(x: 34, y: 22)
                Pointer(width: 13).offset(x: 92, y: 108)
            }
            .frame(height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(10)
        .frame(width: 320)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white))
        .compositingGroup()
            .shadow(color: .black.opacity(0.4), radius: 20, y: 16)
    }
}
