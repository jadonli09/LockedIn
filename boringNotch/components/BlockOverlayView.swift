//
//  BlockOverlayView.swift
//  boringNotch
//
//  The block screen, aurora edition: covers the blocked app's own windows
//  with a blur + violet-ink tint, drifting aurora orbs, and a session ring
//  that fills with an aurora gradient as the session elapses — staying is
//  the rewarding path. One gradient action closes the app; one quiet action
//  grants the 2-minute pass. No shame, no red.
//

import SwiftUI

enum Aurora {
    static let ink = Color(red: 0x0A / 255, green: 0x08 / 255, blue: 0x12 / 255)
    static let violet = Color(red: 0x7C / 255, green: 0x6C / 255, blue: 0xFF / 255)
    static let teal = Color(red: 0x4E / 255, green: 0xD8 / 255, blue: 0xC3 / 255)
    static let peach = Color(red: 0xFF / 255, green: 0xB3 / 255, blue: 0x8A / 255)
    static let rose = Color(red: 0xE8 / 255, green: 0x8C / 255, blue: 0xC4 / 255)
    static let text = Color(red: 0xF4 / 255, green: 0xF1 / 255, blue: 0xFF / 255)

    static let ring = AngularGradient(
        colors: [violet, teal, peach, rose],
        center: .center,
        startAngle: .degrees(-90),
        endAngle: .degrees(270)
    )
}

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .fullScreenUI

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// Two soft drifting color washes behind the content.
private struct AuroraOrbs: View {
    @State private var drift = false

    var body: some View {
        GeometryReader { geo in
            let base = max(geo.size.width, geo.size.height)
            ZStack {
                Circle()
                    .fill(RadialGradient(
                        colors: [Aurora.violet.opacity(0.5), .clear],
                        center: .center, startRadius: 0, endRadius: base * 0.42
                    ))
                    .frame(width: base * 0.85, height: base * 0.85)
                    .position(x: geo.size.width * 0.18, y: geo.size.height * 0.05)
                    .offset(x: drift ? base * 0.04 : 0, y: drift ? base * 0.03 : 0)

                Circle()
                    .fill(RadialGradient(
                        colors: [Aurora.teal.opacity(0.4), .clear],
                        center: .center, startRadius: 0, endRadius: base * 0.4
                    ))
                    .frame(width: base * 0.8, height: base * 0.8)
                    .position(x: geo.size.width * 0.85, y: geo.size.height * 0.95)
                    .offset(x: drift ? -base * 0.04 : 0, y: drift ? -base * 0.03 : 0)

                Circle()
                    .fill(RadialGradient(
                        colors: [Aurora.peach.opacity(0.25), .clear],
                        center: .center, startRadius: 0, endRadius: base * 0.25
                    ))
                    .frame(width: base * 0.5, height: base * 0.5)
                    .position(x: geo.size.width * 0.9, y: geo.size.height * 0.25)
                    .offset(y: drift ? base * 0.03 : 0)
            }
            .blur(radius: 46)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 14).repeatForever(autoreverses: true)) {
                drift = true
            }
        }
        .allowsHitTesting(false)
    }
}

/// The signature: an aurora ring that fills as the session elapses, with the
/// live countdown inside.
private struct SessionRing: View {
    @ObservedObject var focus = FocusSessionManager.shared
    let diameter: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(Aurora.text.opacity(0.08), lineWidth: 7)

            Circle()
                .trim(from: 0, to: max(0.003, focus.progress))
                .stroke(Aurora.ring, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.45, dampingFraction: 1.0), value: focus.progress)

            VStack(spacing: 4) {
                Text(focus.remainingTimeText)
                    .font(.system(size: diameter * 0.21, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Aurora.text)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.spring(response: 0.42, dampingFraction: 0.8), value: focus.remainingTimeText)

                Text("LEFT")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .kerning(2.2)
                    .foregroundStyle(Aurora.text.opacity(0.4))
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

struct BlockOverlayView: View {
    let appName: String
    /// Compact layout for small windows.
    let compact: Bool
    let onCloseApp: () -> Void
    let onPass: () -> Void

    var body: some View {
        ZStack {
            VisualEffectBlur()
            Aurora.ink.opacity(0.72)
            AuroraOrbs()

            VStack(spacing: compact ? 16 : 26) {
                Text(appName.uppercased())
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .kerning(1.9)
                    .foregroundStyle(Aurora.text.opacity(0.45))

                SessionRing(diameter: compact ? 120 : 190)

                Button(action: onCloseApp) {
                    Text("Stay locked in")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Aurora.ink.opacity(0.92))
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(
                            Capsule().fill(LinearGradient(
                                colors: [Aurora.violet, Aurora.teal],
                                startPoint: .leading, endPoint: .trailing
                            ))
                        )
                        .shadow(color: Aurora.violet.opacity(0.45), radius: 16, y: 5)
                }
                .buttonStyle(.plain)
                .help("Closes \(appName)")

                Button(action: onPass) {
                    Text("2-min pass")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Aurora.text.opacity(0.32))
                }
                .buttonStyle(.plain)
            }
            .padding(24)
        }
        .ignoresSafeArea()
    }
}

/// Borderless panels that sit exactly over the blocked app's windows.
@MainActor
final class BlockOverlayController {
    private var panels: [NSPanel] = []

    var isVisible: Bool { panels.contains { $0.isVisible } }

    func show(
        covering rects: [CGRect],
        appName: String,
        fadeIn: TimeInterval = 0,
        onCloseApp: @escaping () -> Void,
        onPass: @escaping () -> Void
    ) {
        hide()

        // No window bounds (e.g. everything minimized): cover the main screen.
        let targets = rects.isEmpty ? [NSScreen.main?.frame].compactMap { $0 } : rects

        for rect in targets {
            let panel = NSPanel(
                contentRect: rect,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(
                rootView: BlockOverlayView(
                    appName: appName,
                    compact: rect.height < 420,
                    onCloseApp: onCloseApp,
                    onPass: onPass
                )
            )

            if fadeIn > 0 {
                // The slow fade back in *is* the relock warning.
                panel.alphaValue = 0
                panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = fadeIn
                    panel.animator().alphaValue = 1
                }
            } else {
                panel.alphaValue = 1
                panel.orderFrontRegardless()
            }
            panels.append(panel)
        }
    }

    /// Follow the app's windows as they move or resize.
    func reposition(to rects: [CGRect]) {
        guard !rects.isEmpty, rects.count == panels.count else { return }
        for (panel, rect) in zip(panels, rects) where panel.frame != rect {
            panel.setFrame(rect, display: true)
        }
    }

    func hide() {
        for panel in panels {
            panel.orderOut(nil)
            panel.close()
        }
        panels = []
    }
}
