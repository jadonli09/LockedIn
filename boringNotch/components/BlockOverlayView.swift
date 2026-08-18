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
                    .frame(height: 76)
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
/// the cursor with continuous physics — a damped particle pushed by an
/// inverse-distance field around the pointer (harder the closer you get, so
/// its speed adapts to the chase), pulled home by a soft spring, integrated
/// every frame. Smooth, never a hop, never catchable.
struct RunawayPassButton: View {
    let action: () -> Void

    @State private var position: CGSize = .zero
    @State private var velocity: CGSize = .zero
    @State private var pointer: CGPoint? = nil
    @State private var lastTick: Date = .init()

    private let fieldRadius: CGFloat = 240
    private let push: CGFloat = 16000
    private let spring: CGFloat = 5.5
    private let damping: CGFloat = 0.90
    private let maxSpeed: CGFloat = 1800

    private let ticker = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            let home = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let center = CGPoint(x: home.x + position.width, y: home.y + position.height)

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
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let p): pointer = p
                case .ended: pointer = nil
                }
            }
            .onReceive(ticker) { now in
                integrate(now: now, center: center, arenaWidth: geo.size.width)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity)
    }

    private func integrate(now: Date, center: CGPoint, arenaWidth: CGFloat) {
        let dt = CGFloat(min(0.05, now.timeIntervalSince(lastTick)))
        lastTick = now
        guard dt > 0 else { return }

        // Spring home.
        var ax = -spring * position.width * 6
        var ay = -spring * position.height * 6

        // Inverse-distance repulsion, ramping to zero at the field edge.
        if let p = pointer {
            let dx = center.x - p.x, dy = center.y - p.y
            let d = sqrt(dx * dx + dy * dy)
            if d < fieldRadius, d > 0.5 {
                let falloff = 1 - d / fieldRadius
                let f = push * (falloff + 0.35 * falloff * falloff) / max(d, 26)
                var ux = dx / d, uy = dy / d
                // Curve around the cursor near a side wall — tangential
                // component pointing home — so it circles back to the open
                // center instead of getting pinned.
                let bxNow = arenaWidth / 2 - 60
                let nearWall = max(0, min(1, (abs(position.width) - (bxNow - 200)) / 200))
                if nearWall > 0 {
                    var tx = -uy, ty = ux
                    if tx * (-position.width) + ty * (-position.height) < 0 { tx = -tx; ty = -ty }
                    let k = nearWall * 2.2
                    ux += tx * k; uy += ty * k
                    let n = max(0.001, sqrt(ux * ux + uy * uy)); ux /= n; uy /= n
                }
                ax += ux * f * 60
                ay += uy * f * 60 * 0.75
            }
        }

        var vx = (velocity.width + ax * dt) * damping
        var vy = (velocity.height + ay * dt) * damping
        let speed = sqrt(vx * vx + vy * vy)
        if speed > maxSpeed { vx *= maxSpeed / speed; vy *= maxSpeed / speed }

        var x = position.width + vx * dt
        var y = position.height + vy * dt

        // Soft walls inside the arena.
        let bx = arenaWidth / 2 - 60, by: CGFloat = 26
        if x > bx { x = bx; vx = -abs(vx) * 0.4 }
        if x < -bx { x = -bx; vx = abs(vx) * 0.4 }
        if y > by { y = by; vy = -abs(vy) * 0.4 }
        if y < -by { y = -by; vy = abs(vy) * 0.4 }

        velocity = CGSize(width: vx, height: vy)
        position = CGSize(width: x, height: y)
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
