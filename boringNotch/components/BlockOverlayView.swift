//
//  BlockOverlayView.swift
//  boringNotch
//
//  The block screen: covers the blocked app's own windows (not the whole
//  screen) with a blur + dark tint. One primary action closes the app, one
//  visually quiet action grants the 2-minute pass. No shame, no red.
//

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
            Color.black.opacity(0.55)

            VStack(spacing: compact ? 14 : 22) {
                Text(appName.uppercased())
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .kerning(1.4)
                    .foregroundStyle(.white.opacity(0.4))

                Text("Locked in — \(focus.remainingTimeText) left")
                    .font(.system(size: compact ? 20 : 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.spring(response: 0.42, dampingFraction: 0.8), value: focus.remainingTimeText)

                Button(action: onCloseApp) {
                    Text("Stay locked in")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.black.opacity(0.85))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(.white.opacity(0.92)))
                }
                .buttonStyle(.plain)
                .help("Closes \(appName)")

                Button(action: onPass) {
                    Text("2-min pass")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .buttonStyle(.plain)
                .padding(.top, compact ? 0 : 6)
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
