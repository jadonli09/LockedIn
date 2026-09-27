//
//  LockInAnimation.swift
//  LockedIn
//
//  The launch greeting: "lock in" written in a single monoline cursive
//  stroke, drawn by a glowing snake across the open island. Snake and glow
//  by Harsh Vardhan Goswami (boringNotch); letterforms are LockedIn's own.
//

import SwiftUI

/// "lock in" in cursive. Authored in a 420×100 design box (baseline y=80,
/// x-height y=52, ascenders y≈8), scaled uniformly and centered in `rect`
/// so the script never stretches. Two words are two subpaths plus the
/// i-dot; `trim` runs across all of them, so the snake writes the phrase
/// in reading order.
struct LockInShape: Shape {
    func path(in rect: CGRect) -> Path {
        let designWidth = 420.0, designHeight = 100.0
        let s = min(rect.width / designWidth, rect.height / designHeight)
        let ox = rect.minX + (rect.width - designWidth * s) / 2
        let oy = rect.minY + (rect.height - designHeight * s) / 2
        func P(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }

        var p = Path()

        // l
        p.move(to: P(0, 86))
        p.addCurve(to: P(46, 8),  control1: P(16, 66), control2: P(38, 24))
        p.addCurve(to: P(26, 80), control1: P(52, -4), control2: P(28, 36))
        p.addCurve(to: P(62, 62), control1: P(24, 96), control2: P(48, 88))
        // o
        p.addCurve(to: P(90, 52),  control1: P(72, 54),   control2: P(82, 52))
        p.addCurve(to: P(75, 66),  control1: P(81.7, 52), control2: P(75, 58.3))
        p.addCurve(to: P(90, 80),  control1: P(75, 73.7), control2: P(81.7, 80))
        p.addCurve(to: P(105, 66), control1: P(98.3, 80), control2: P(105, 73.7))
        p.addCurve(to: P(94, 53),  control1: P(105, 58),  control2: P(100, 53))
        p.addCurve(to: P(118, 62), control1: P(104, 52),  control2: P(112, 60))
        // c — the connector rises to become the top of the bowl, a small hook
        // at the upper right, then the open counter-clockwise sweep.
        p.addCurve(to: P(148, 50), control1: P(126, 64), control2: P(138, 50))
        p.addCurve(to: P(126, 68), control1: P(156, 50), control2: P(126, 52))
        p.addCurve(to: P(141, 81), control1: P(126, 78), control2: P(132, 81))
        p.addCurve(to: P(170, 64), control1: P(151, 81), control2: P(162, 74))
        // k
        p.addCurve(to: P(206, 8),  control1: P(180, 50), control2: P(198, 22))
        p.addCurve(to: P(188, 80), control1: P(212, -4), control2: P(190, 38))
        p.addCurve(to: P(192, 52), control1: P(187, 72), control2: P(189, 58))
        p.addCurve(to: P(218, 56), control1: P(198, 42), control2: P(214, 44))
        p.addCurve(to: P(204, 64), control1: P(222, 64), control2: P(212, 68))
        p.addCurve(to: P(228, 80), control1: P(212, 66), control2: P(222, 80))
        p.addCurve(to: P(246, 60), control1: P(236, 80), control2: P(242, 70))

        // i
        p.move(to: P(272, 74))
        p.addCurve(to: P(296, 52), control1: P(278, 66), control2: P(290, 54))
        p.addCurve(to: P(292, 80), control1: P(295, 62), control2: P(292, 74))
        p.addCurve(to: P(312, 60), control1: P(292, 88), control2: P(304, 76))
        // n
        p.addCurve(to: P(326, 52), control1: P(318, 54), control2: P(322, 52))
        p.addCurve(to: P(322, 80), control1: P(328, 60), control2: P(324, 74))
        p.addCurve(to: P(340, 52), control1: P(324, 64), control2: P(330, 52))
        p.addCurve(to: P(352, 80), control1: P(350, 52), control2: P(352, 70))
        p.addCurve(to: P(376, 56), control1: P(352, 88), control2: P(366, 76))

        // i-dot
        p.move(to: P(293, 37))
        p.addLine(to: P(296, 34))

        return p
    }
}

extension ShapeStyle where Self == AngularGradient {
    static var lockIn: some ShapeStyle {
        LinearGradient(
            stops: [
                .init(color: .blue, location: 0.0),
                .init(color: .purple, location: 0.2),
                .init(color: .red, location: 0.4),
                .init(color: .mint, location: 0.5),
                .init(color: .indigo, location: 0.7),
                .init(color: .pink, location: 0.9),
                .init(color: .blue, location: 1.0)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

struct GlowingSnake<
    Content: Shape,
    Fill: ShapeStyle
>: View, Animatable {

    var progress: Double
    var delay: Double = 1.0
    var fill: Fill
    var lineWidth = 4.0
    var blurRadius = 8.0

    @ViewBuilder var shape: Content

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        shape
            .trim(
                from: {
                    if progress > 1 - delay {
                        2 * progress - 1.0
                    } else if progress > delay {
                        progress - delay
                    } else {
                        .zero
                    }
                }(),
                to: progress
            )
            .glow(
                fill: fill,
                lineWidth: lineWidth,
                blurRadius: blurRadius
            )
    }
}

struct LockInAnimation: View {
    @State private var progress: Double = 0.0

    var onFinish: () -> Void

    var body: some View {
        GlowingSnake(
            progress: progress,
            fill: .lockIn,
            lineWidth: 8,
            blurRadius: 8.0,
            shape: { LockInShape() }
        )
        .task {
            // Wait for the "opening" animation (notch expansion) to complete before starting the snake
            try? await Task.sleep(for: .seconds(0.6))

            withAnimation(
                .easeInOut(duration: 4.0)
            ) {
                progress = 1.0
            }

            // Wait for the animation to complete
            try? await Task.sleep(for: .seconds(4.0))

            onFinish()
        }
    }
}

extension View where Self: Shape {
    func glow(
        fill: some ShapeStyle,
        lineWidth: Double,
        blurRadius: Double = 8.0,
        lineCap: CGLineCap = .round
    ) -> some View {
        self
            .stroke(style: StrokeStyle(lineWidth: lineWidth / 2, lineCap: lineCap))
            .fill(fill)
            .overlay {
                self
                    .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: lineCap))
                    .fill(fill)
                    .blur(radius: blurRadius)
            }
            .overlay {
                self
                    .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: lineCap))
                    .fill(fill)
                    .blur(radius: blurRadius / 2)
            }
    }
}

#Preview {
    LockInAnimation(onFinish: {})
        .frame(width: 424, height: 96)
        .background(.black)
}
