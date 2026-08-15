//
//  FocusIdleView.swift
//  boringNotch
//
//  The two collapsed island states. At rest: a faint 1px ambient glow along
//  the bottom edge. During a session: the glow becomes a thin arc that drains
//  left-to-right as the phase elapses, plus an optional remaining-minutes
//  numeral tucked at the right edge. Max two elements, per spec.
//

import Defaults
import SwiftUI

/// Bottom-edge accent line, overlaid on the collapsed island shape.
struct FocusIdleUnderlay: View {
    @ObservedObject var focus = FocusSessionManager.shared
    @Default(.focusAccent) var accent

    let notchWidth: CGFloat

    // Keep the line between the island's bottom corner curves.
    private var lineSpan: CGFloat { max(0, notchWidth - 2 * cornerRadiusInsets.closed.bottom) }

    var body: some View {
        Group {
            if focus.hasSession {
                // Remaining time, anchored at the trailing edge: the line
                // visibly drains from left to right as the phase elapses.
                Capsule()
                    .fill(accent.color)
                    .frame(width: max(0, lineSpan * (1 - focus.progress)), height: 2)
                    .frame(width: lineSpan, alignment: .trailing)
                    .opacity(focus.isPaused ? 0.35 : 0.9)
                    .animation(.spring(response: 0.45, dampingFraction: 1.0), value: focus.progress)
            } else {
                Capsule()
                    .fill(accent.color.opacity(0.15))
                    .frame(width: lineSpan, height: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Collapsed island content while a session is running: black spacer matching
/// the hardware notch, remaining minutes at the right, balancing space at the
/// left so the island stays centered on the physical notch.
struct FocusClosedContent: View {
    @ObservedObject var focus = FocusSessionManager.shared

    let notchWidth: CGFloat
    let notchHeight: CGFloat

    static let sideWidth: CGFloat = 26

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(.clear)
                .frame(width: Self.sideWidth)

            Rectangle()
                .fill(.black)
                .frame(width: notchWidth - 20)

            Text(focus.remainingMinutesText)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: Self.sideWidth, alignment: .center)
                .contentTransition(.numericText(countsDown: true))
                .animation(.spring(response: 0.42, dampingFraction: 0.8), value: focus.remainingMinutesText)
        }
        .frame(height: notchHeight, alignment: .center)
    }
}
