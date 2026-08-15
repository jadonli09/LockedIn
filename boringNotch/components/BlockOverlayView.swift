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

                Button(action: onPass) {
                    Text("2-min pass")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .buttonStyle(.plain)
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
