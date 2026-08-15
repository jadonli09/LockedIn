//
//  FocusIdleView.swift
//  boringNotch
//
//  Collapsed island content while a session is running (or a state chip is
//  showing). At rest the island is pure black — no glow, no line. During a
//  session: the remaining-minutes numeral sits right of the notch (swapped
//  for the 2-min pass countdown while one is active), and a transient chip
//  on the left confirms ⌥⌘L state changes.
//

import Defaults
import SwiftUI

/// The center black spacer covers the hardware notch with a generous margin
/// so the side elements can never slip underneath it; both sides stay the
/// same width so the island remains centered on the physical notch.
struct FocusClosedContent: View {
    @ObservedObject var focus = FocusSessionManager.shared
    @ObservedObject var passCenter = PassCenter.shared

    let notchWidth: CGFloat
    let notchHeight: CGFloat

    private var sideWidth: CGFloat {
        focus.transientEvent != nil ? 80 : 44
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left: transient state chip (⌥⌘L feedback), else empty balance.
            Group {
                if let event = focus.transientEvent {
                    HStack(spacing: 5) {
                        Image(systemName: event.symbol)
                            .font(.system(size: 9, weight: .semibold))
                        Text(event.label)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(.white.opacity(0.75))
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .frame(width: sideWidth, alignment: .center)

            // Center: cover the hardware notch with margin to spare.
            Rectangle()
                .fill(.black)
                .frame(width: notchWidth + 24)

            // Right: pass countdown while one is active, else session minutes.
            Group {
                if let pass = passCenter.soonest {
                    Text(passCountdownText(pass))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.75))
                        .contentTransition(.numericText(countsDown: true))
                } else if focus.hasSession {
                    Text(focus.remainingMinutesText)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.6))
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: focus.remainingMinutesText)
                }
            }
            .frame(width: sideWidth, alignment: .center)
        }
        .frame(height: notchHeight, alignment: .center)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: focus.transientEvent != nil)
    }

    private func passCountdownText(_ pass: ActivePass) -> String {
        let total = Int(pass.remaining(at: passCenter.now).rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
