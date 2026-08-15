//
//  FocusIdleView.swift
//  boringNotch
//
//  The collapsed island states. At rest: a faint ambient glow along the
//  bottom edge. During a session: the glow becomes a thin arc that drains
//  left-to-right, plus an optional remaining-minutes numeral tucked at the
//  right edge — swapped for the 2-min pass countdown while one is active.
//  A transient chip on the left confirms ⌥⌘L state changes.
//

import Defaults
import SwiftUI

/// Bottom-edge accent line, overlaid on the collapsed island shape. Spans the
/// island's *actual* rendered width — which is wider than the notch while the
/// numeral or a chip is showing — so the line always reaches edge to edge.
struct FocusIdleUnderlay: View {
    @ObservedObject var focus = FocusSessionManager.shared
    @Default(.focusAccent) var accent

    var body: some View {
        GeometryReader { geo in
            // Stop just short of the bottom corner curves.
            let span = max(0, geo.size.width - 10)
            ZStack(alignment: .bottom) {
                Color.clear
                if focus.hasSession {
                    // Remaining time, anchored at the trailing edge: the line
                    // visibly drains from left to right as the phase elapses.
                    Capsule()
                        .fill(accent.color)
                        .frame(width: max(0, span * (1 - focus.progress)), height: 2)
                        .background(alignment: .trailing) {
                            Capsule()
                                .fill(accent.color)
                                .frame(width: max(0, span * (1 - focus.progress)), height: 3)
                                .blur(radius: 3)
                        }
                        .frame(width: span, alignment: .trailing)
                        .opacity(focus.isPaused ? 0.35 : 0.9)
                        .animation(.spring(response: 0.45, dampingFraction: 1.0), value: focus.progress)
                } else {
                    // Rest state: 1px line with a soft bloom beneath so it
                    // reads as a glow rather than a hairline.
                    Capsule()
                        .fill(accent.color.opacity(0.15))
                        .frame(width: span, height: 1)
                        .background {
                            Capsule()
                                .fill(accent.color.opacity(0.12))
                                .frame(width: span, height: 2.5)
                                .blur(radius: 2.5)
                        }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
    }
}

/// Collapsed island content while a session is running (or a state chip is
/// showing): the center black spacer covers slightly more than the hardware
/// notch so the side elements are never clipped by it; both sides stay the
/// same width so the island remains centered on the physical notch.
struct FocusClosedContent: View {
    @ObservedObject var focus = FocusSessionManager.shared
    @ObservedObject var passCenter = PassCenter.shared

    let notchWidth: CGFloat
    let notchHeight: CGFloat

    private var sideWidth: CGFloat {
        focus.transientEvent != nil ? 74 : 38
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

            // Center: cover the hardware notch with a small margin so side
            // content never slips underneath it.
            Rectangle()
                .fill(.black)
                .frame(width: notchWidth + 8)

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
