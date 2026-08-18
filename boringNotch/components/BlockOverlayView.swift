//
//  BlockOverlayView.swift
//  boringNotch
//
//  The block screen, in the island's own language: near-black over the
//  blurred app, SF Pro Rounded, one amber accent. Progress is a row of
//  attended-minute dots — one per minute of the phase, amber once attended —
//  because 25 minutes means 25 attended minutes. Flat, no gradients.
//

import Defaults
import SwiftUI

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

/// One dot per minute of the phase; attended minutes fill in accent.
struct AttendedMinuteDots: View {
    @ObservedObject var focus = FocusSessionManager.shared
    @Default(.focusAccent) var accent

    private static let perRow = 30

    var body: some View {
        let totalMinutes = max(1, Int((focus.state?.phaseDuration ?? 60) / 60))
        let attended = min(totalMinutes, Int(focus.progress * Double(totalMinutes)))

        VStack(spacing: 8) {
            ForEach(Array(stride(from: 0, to: totalMinutes, by: Self.perRow)), id: \.self) { start in
                HStack(spacing: 7) {
                    ForEach(start..<min(start + Self.perRow, totalMinutes), id: \.self) { minute in
                        Circle()
                            .fill(minute < attended ? accent.color : .white.opacity(0.14))
                            .frame(width: 5, height: 5)
                    }
                }
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 1.0), value: attended)
    }
}

struct BlockOverlayView: View {
    @ObservedObject var focus = FocusSessionManager.shared

    let appName: String
    /// Compact layout for small windows.
    let compact: Bool
    let onCloseApp: () -> Void
    let onPass: () -> Void

    var body: some View {
        ZStack {
            VisualEffectBlur()
            Color.black.opacity(0.82)

            VStack(spacing: compact ? 14 : 22) {
                Text(appName.uppercased())
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .kerning(1.8)
                    .foregroundStyle(.white.opacity(0.4))

                Text(focus.remainingTimeText)
                    .font(.system(size: compact ? 44 : 64, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.spring(response: 0.42, dampingFraction: 0.8), value: focus.remainingTimeText)

                VStack(spacing: 12) {
                    AttendedMinuteDots()
                    Text(attendedLine)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .kerning(1.2)
                        .foregroundStyle(.white.opacity(0.35))
                }

                Button(action: onCloseApp) {
                    Text("Stay locked in")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.black.opacity(0.85))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(.white.opacity(0.92)))
                }
                .buttonStyle(.plain)
                .help("Closes \(appName)")
                .padding(.top, compact ? 2 : 8)

                RunawayPassButton(action: onPass)
                    .frame(height: 44)
            }
            .padding(24)
        }
        .ignoresSafeArea()
    }

    private var attendedLine: String {
        let totalMinutes = max(1, Int((focus.state?.phaseDuration ?? 60) / 60))
        let attended = min(totalMinutes, Int(focus.progress * Double(totalMinutes)))
        return "\(attended) OF \(totalMinutes) MINUTES ATTENDED"
    }
}

/// The 2-minute pass, made impossible: a liquid-glass capsule that runs from
/// the cursor. As the pointer approaches it springs away along the
/// pointer→button vector; when the pointer backs off it eases home. Fast,
/// slightly bouncy, and never catchable.
struct RunawayPassButton: View {
    let action: () -> Void

    @State private var offset: CGSize = .zero

    /// Pointer closer than this (from the button's *current* center) triggers a hop.
    private let triggerRadius: CGFloat = 140
    /// How far each hop moves it.
    private let hop: CGFloat = 190
    /// Cap so it never leaves the visible area of even a small window.
    private let maxExcursion: CGFloat = 220

    var body: some View {
        GeometryReader { geo in
            let home = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let center = CGPoint(x: home.x + offset.width, y: home.y + offset.height)

            Button(action: action) {
                Text("2-min pass")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(GlassCapsule())
            }
            .buttonStyle(.plain)
            .position(center)
            .animation(.spring(response: 0.2, dampingFraction: 0.65), value: offset)
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let p):
                    flee(from: p, center: center, home: home)
                case .ended:
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                        offset = .zero
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
        }
        // The arena is the overlay's full width; the button roams inside it.
        .frame(maxWidth: .infinity)
    }

    private func flee(from p: CGPoint, center: CGPoint, home: CGPoint) {
        let dx = center.x - p.x
        let dy = center.y - p.y
        let dist = max(1, sqrt(dx * dx + dy * dy))
        if dist < triggerRadius {
            // Move directly away from the pointer, with a little sideways
            // jitter so it doesn't just slide along one axis.
            let ux = dx / dist, uy = dy / dist
            let jitter = CGFloat.random(in: -0.35...0.35)
            var nx = offset.width + (ux - uy * jitter) * hop
            var ny = offset.height + (uy + ux * jitter) * hop * 0.6
            // If it would leave the arena, bounce back toward home instead.
            let bound = min(maxExcursion, home.x - 60)
            if abs(nx) > bound { nx = -nx * 0.5 }
            if abs(ny) > 60 { ny = -ny * 0.5 }
            offset = CGSize(width: nx, height: ny)
        } else if dist > triggerRadius * 2.2, offset != .zero {
            // Pointer wandered off: come home.
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                offset = .zero
            }
        }
    }
}

/// Liquid-glass capsule: frosted fill, luminous rim, soft inner highlight.
private struct GlassCapsule: View {
    var body: some View {
        ZStack {
            Capsule()
                .fill(.ultraThinMaterial)
            Capsule()
                .fill(LinearGradient(
                    colors: [.white.opacity(0.22), .white.opacity(0.04)],
                    startPoint: .top, endPoint: .bottom
                ))
            Capsule()
                .strokeBorder(LinearGradient(
                    colors: [.white.opacity(0.7), .white.opacity(0.15), .white.opacity(0.5)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ), lineWidth: 1)
            // Specular streak along the top edge.
            Capsule()
                .trim(from: 0.05, to: 0.45)
                .stroke(.white.opacity(0.55), lineWidth: 1.2)
                .blur(radius: 0.6)
                .padding(1)
        }
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }
}

/// Borderless panels that sit exactly over the blocked app's windows.
@MainActor
final class BlockOverlayController {
    private var panels: [NSPanel] = []

    var isVisible: Bool { panels.contains { $0.isVisible } }
    var panelCount: Int { panels.count }

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
            panel.acceptsMouseMovedEvents = true
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
