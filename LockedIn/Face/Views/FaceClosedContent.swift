//
//  FaceClosedContent.swift
//  LockedIn
//
//  The face presentation in the island, modeled on the iPhone Dynamic Island's
//  Face ID moment: the island springs open below the notch around a Face ID
//  glyph ringed by a sweeping dot "scan"; on a match the ring closes and the
//  glyph turns into an opening padlock (lock screen) or a drawn checkmark
//  (identity gate); on a miss the glyph shakes its head. Then the island
//  springs shut. Plus the small green dot that says the camera is on.
//

import AppKit
import Defaults
import SwiftUI

/// The island's expanded geometry while a face presentation is up. ContentView
/// uses the corner radius so the black shape rounds out as it grows.
enum FaceIsland {
    static let bottomCornerRadius: CGFloat = 30
    static let glyphSize: CGFloat = 44
    static let sidePadding: CGFloat = 36
    /// Deliberately bouncier than the panel open — the island "breathes" out.
    static let spring = Animation.spring(response: 0.5, dampingFraction: 0.72)
}

struct FaceClosedContent: View {
    @ObservedObject var unlock = FaceUnlockCoordinator.shared
    @ObservedObject var gate = IdentityGate.shared

    let notchWidth: CGFloat
    let notchHeight: CGFloat

    private var isUnlock: Bool { unlock.phase.isPresenting }

    private var glyph: FaceIDGlyphState {
        if isUnlock {
            switch unlock.phase {
            case .scanning: return .scanning
            case .success: return .unlocked
            case .failure, .idle: return .failed
            }
        }
        switch gate.phase {
        case .verifying: return .scanning
        case .verified: return .verified
        case .failed, .idle: return .failed
        }
    }

    private var title: String {
        if isUnlock {
            switch unlock.phase {
            case .scanning: return "Face ID"
            case .success: return "Unlocked"
            case .failure(let reason): return reason
            case .idle: return ""
            }
        }
        switch gate.phase {
        case .verifying: return "Confirm it's you"
        case .verified: return "It's you"
        case .failed: return "Not Recognized"
        case .idle: return ""
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // The hardware notch row: kept black; the camera dot rides on the
            // right shoulder like the iPhone's privacy indicator.
            HStack(spacing: 0) {
                Color.clear.frame(width: FaceIsland.sidePadding)
                Rectangle().fill(.black).frame(width: notchWidth)
                CameraActiveDot()
                    .frame(width: FaceIsland.sidePadding)
            }
            .frame(height: notchHeight)

            FaceIDGlyph(state: glyph)
                .frame(width: FaceIsland.glyphSize, height: FaceIsland.glyphSize)
                .padding(.top, 8)

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(glyph == .failed ? 0.7 : 0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: notchWidth + FaceIsland.sidePadding)
                .contentTransition(.interpolate)
                .padding(.top, 7)
                .padding(.bottom, 14)
        }
        .frame(width: notchWidth + FaceIsland.sidePadding * 2)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: title)
        .transition(.asymmetric(insertion: .materialize(scale: 0.6), removal: .materialize(scale: 0.85)))
        .onChange(of: glyph) { _, new in
            switch new {
            case .unlocked, .verified:
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            case .failed:
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            case .scanning:
                break
            }
        }
    }
}

enum FaceIDGlyphState: Equatable {
    case scanning, unlocked, verified, failed

    var isSuccess: Bool { self == .unlocked || self == .verified }
}

/// Face ID mark inside a ring of dots. Scanning: a bright comet sweeps the
/// dots while the face gently pulses. Success: the dots dissolve into a solid
/// green ring that draws itself closed, and the face gives way to an opening
/// padlock or a checkmark stroked on. Failure: a quick damped head-shake.
struct FaceIDGlyph: View {
    let state: FaceIDGlyphState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ringProgress: CGFloat = 0
    @State private var checkProgress: CGFloat = 0
    @State private var shakes = 0

    private static let dotCount = 30
    private static let success = Color(red: 0.2, green: 0.84, blue: 0.42)

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            ZStack {
                dotRing(size: size)
                    .opacity(state.isSuccess ? 0 : 1)
                    .scaleEffect(state.isSuccess ? 0.92 : 1)

                Circle()
                    .trim(from: 0, to: ringProgress)
                    .stroke(Self.success, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(1.2)

                center(size: size)
            }
            .frame(width: size, height: size)
        }
        .keyframeAnimator(initialValue: CGFloat(0), trigger: shakes) { content, x in
            content.offset(x: x)
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(-9, duration: 0.06)
                LinearKeyframe(8, duration: 0.08)
                LinearKeyframe(-6, duration: 0.08)
                LinearKeyframe(4, duration: 0.07)
                LinearKeyframe(-2, duration: 0.06)
                SpringKeyframe(0, duration: 0.2)
            }
        }
        .onAppear { apply(state, animated: false) }
        .onChange(of: state) { _, new in apply(new, animated: true) }
    }

    // MARK: - Pieces

    /// The scanning ring. A cosine lobe raised to a high power makes a short,
    /// bright comet with a soft tail; dots under it also swell slightly.
    private func dotRing(size: CGFloat) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: state != .scanning || reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, canvasSize in
                let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                let radius = size / 2 - 2
                let head = reduceMotion ? 0 : t * 4.2
                // A miss settles the ring to an even dim instead of freezing the comet.
                let sweeping = state == .scanning
                for i in 0..<Self.dotCount {
                    let angle = Double(i) / Double(Self.dotCount) * 2 * .pi - .pi / 2
                    let lobe = sweeping ? pow(max(0, cos(angle - head.truncatingRemainder(dividingBy: 2 * .pi))), 6) : 0
                    let dot = 1.6 + 1.0 * lobe
                    let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
                    context.fill(
                        Path(ellipseIn: CGRect(x: point.x - dot / 2, y: point.y - dot / 2, width: dot, height: dot)),
                        with: .color(.white.opacity(0.22 + 0.78 * lobe))
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func center(size: CGFloat) -> some View {
        switch state {
        case .scanning, .failed:
            Image(systemName: "faceid")
                .font(.system(size: size * 0.5, weight: .regular))
                .foregroundStyle(.white.opacity(state == .failed ? 0.6 : 0.95))
                .symbolEffect(.pulse, options: .repeating, isActive: state == .scanning && !reduceMotion)
                .transition(.materialize(scale: 0.9, anchor: .center))
        case .unlocked:
            Image(systemName: "lock.open.fill")
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.bounce, value: state)
                .transition(.materialize(scale: 0.6, anchor: .center))
        case .verified:
            CheckmarkShape()
                .trim(from: 0, to: checkProgress)
                .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.42, height: size * 0.42)
                .transition(.opacity)
        }
    }

    // MARK: - State changes

    private func apply(_ state: FaceIDGlyphState, animated: Bool) {
        let go = animated && !reduceMotion
        switch state {
        case .scanning:
            ringProgress = 0
            checkProgress = 0
        case .unlocked, .verified:
            if go {
                withAnimation(.easeOut(duration: 0.38)) { ringProgress = 1 }
                withAnimation(.easeOut(duration: 0.3).delay(0.22)) { checkProgress = 1 }
            } else {
                ringProgress = 1
                checkProgress = 1
            }
        case .failed:
            ringProgress = 0
            if go { shakes += 1 }
        }
    }
}

/// Blur + scale + fade: content condenses out of (or dissolves back into)
/// the black island rather than simply cross-fading.
private struct Materialize: ViewModifier {
    let progress: CGFloat
    let scale: CGFloat
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .blur(radius: 8 * progress)
            .scaleEffect(1 - (1 - scale) * progress, anchor: anchor)
            .opacity(1 - progress)
    }
}

extension AnyTransition {
    static func materialize(scale: CGFloat, anchor: UnitPoint = .top) -> AnyTransition {
        .modifier(
            active: Materialize(progress: 1, scale: scale, anchor: anchor),
            identity: Materialize(progress: 0, scale: scale, anchor: anchor)
        )
    }
}

private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.minY + rect.height * 0.54))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.minY + rect.height * 0.82))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.94, y: rect.minY + rect.height * 0.18))
        return path
    }
}

/// The camera-is-on indicator: a 5 pt green dot with a soft halo, shown
/// wherever the island renders while any feature holds a camera lease.
struct CameraActiveDot: View {
    @ObservedObject private var camera = CameraManager.shared

    var body: some View {
        if camera.isRunning {
            Circle()
                .fill(Color.green)
                .frame(width: 5, height: 5)
                .shadow(color: .green.opacity(0.7), radius: 3)
                .help("Camera on: \(camera.activeClients.joined(separator: ", "))")
                .transition(.opacity.combined(with: .scale(scale: 0.5)))
        }
    }
}
