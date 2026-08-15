//
//  BlockOverlayView.swift
//  boringNotch
//
//  The full-screen block screen: black, remaining time, one quiet way back
//  to work and one visually quieter 2-minute pass. No shame, no red.
//

import SwiftUI

struct BlockOverlayView: View {
    @ObservedObject var focus = FocusSessionManager.shared

    let appName: String
    let onBackToWork: () -> Void
    let onPass: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 28) {
                Text("Locked in — \(focus.remainingTimeText) left")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.spring(response: 0.42, dampingFraction: 0.8), value: focus.remainingTimeText)

                Button(action: onBackToWork) {
                    Text("Back to work")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.black.opacity(0.85))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(.white.opacity(0.9)))
                }
                .buttonStyle(.plain)

                Button(action: onPass) {
                    Text("2-min pass")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
            }
        }
    }
}

/// Borderless full-screen window that hosts the block screen.
@MainActor
final class BlockOverlayController {
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    func show(appName: String, fadeIn: TimeInterval = 0, onBackToWork: @escaping () -> Void, onPass: @escaping () -> Void) {
        hide()

        guard let screen = NSScreen.main else { return }
        let window = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.isOpaque = true
        window.backgroundColor = .black
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(
            rootView: BlockOverlayView(appName: appName, onBackToWork: onBackToWork, onPass: onPass)
        )
        window.isReleasedWhenClosed = false

        if fadeIn > 0 {
            // The 3s fade back in *is* the relock warning.
            window.alphaValue = 0
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = fadeIn
                window.animator().alphaValue = 1
            }
        } else {
            window.alphaValue = 1
            window.orderFrontRegardless()
        }

        self.window = window
    }

    func hide() {
        window?.orderOut(nil)
        window?.close()
        window = nil
    }
}
