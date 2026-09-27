//
//  EnrollmentRingView.swift
//  LockedIn
//
//  80 ticks around the preview, tiled into 45° sectors that light up in the
//  accent once their pose is captured. Center has no sector and pulses the
//  whole ring instead. A short band tracks where the head is currently turned,
//  and the target sector breathes so the direction reads without an arrow.
//
//  Ported from Glance (github.com/jonnyoo/glance, MIT), restyled.
//

import SwiftUI

struct EnrollmentRingView: View {
    @ObservedObject var controller: FaceEnrollmentController
    let diameter: CGFloat
    let accent: Color

    @State private var pulseActive = false
    @State private var breathe = false

    private static let tickCount = 80
    private static let ticksPerSector = 10
    private static let tickWidth: CGFloat = 2
    private static let tickLengthUnlit: CGFloat = 6
    private static let tickLengthLit: CGFloat = 13
    private static let turnBoost: CGFloat = 7
    private static let turnSpan = 12.0

    private var radius: CGFloat { diameter / 2 }
    private var isComplete: Bool { controller.stage == .done || controller.stage == .saving }

    var body: some View {
        let turn = controller.headTurn
        let target = controller.currentPose?.compassAngle
        ZStack {
            ForEach(0..<Self.tickCount, id: \.self) { index in
                let intensity = turnIntensity(for: index, turn: turn)
                let targetGlow = targetIntensity(for: index, target: target)
                let length = length(for: index, intensity: intensity, targetGlow: targetGlow)
                Capsule()
                    .fill(color(for: index, intensity: intensity, targetGlow: targetGlow))
                    .frame(width: Self.tickWidth, height: length)
                    .offset(y: -(radius + length / 2))
                    .rotationEffect(.degrees(angle(for: index)))
                    .animation(
                        .easeOut(duration: 0.3).delay(Double(index % Self.ticksPerSector) * 0.012),
                        value: isLit(index)
                    )
                    .animation(.easeOut(duration: 0.22), value: pulseActive)
                    .animation(.easeOut(duration: 0.15), value: intensity)
                    .animation(.easeInOut(duration: 0.9), value: breathe)
            }
        }
        .frame(width: diameter, height: diameter)
        .onChange(of: controller.centerPulseTick) { _, _ in triggerPulse() }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }

    private func angle(for index: Int) -> Double {
        Double(index) * (360.0 / Double(Self.tickCount))
    }

    private func sectorPose(for index: Int) -> EnrollmentPose? {
        let raw = Int((angle(for: index) / 45.0).rounded()) % 8
        let sectorAngle = Double(raw) * 45
        return EnrollmentPose.allCases.first { $0.compassAngle == sectorAngle }
    }

    private func isLit(_ index: Int) -> Bool {
        if isComplete { return true }
        guard let pose = sectorPose(for: index) else { return false }
        return controller.capturedPoses.contains(pose)
    }

    private func length(for index: Int, intensity: Double, targetGlow: Double) -> CGFloat {
        if isLit(index) || pulseActive { return Self.tickLengthLit }
        let breatheBoost = breathe ? 1.0 : 0.35
        return Self.tickLengthUnlit
            + Self.turnBoost * intensity
            + Self.turnBoost * 0.6 * targetGlow * breatheBoost
    }

    private func color(for index: Int, intensity: Double, targetGlow: Double) -> Color {
        if isLit(index) || isComplete { return accent }
        let mix = max(intensity, targetGlow * (breathe ? 0.75 : 0.35))
        return mix > 0.01 ? accent.opacity(0.25 + 0.75 * mix) : .white.opacity(0.22)
    }

    /// Peaks where the turn points, fading out half a span to either side.
    private func turnIntensity(for index: Int, turn: FaceEnrollmentController.HeadTurn?) -> Double {
        guard let turn, !isComplete, !isLit(index) else { return 0 }
        return turn.progress * falloff(from: angle(for: index), to: turn.angle)
    }

    /// The sector the user should turn toward, lit softly as the cue.
    private func targetIntensity(for index: Int, target: Double?) -> Double {
        guard let target, !isComplete, !isLit(index) else { return 0 }
        return falloff(from: angle(for: index), to: target)
    }

    private func falloff(from tickAngle: Double, to center: Double) -> Double {
        var delta = abs(tickAngle - center)
        if delta > 180 { delta = 360 - delta }
        let degreesPerTick = 360.0 / Double(Self.tickCount)
        let halfSpan = Self.turnSpan / 2
        return max(0, 1 - (delta / degreesPerTick) / halfSpan)
    }

    private func triggerPulse() {
        Task {
            pulseActive = true
            try? await Task.sleep(for: .milliseconds(220))
            pulseActive = false
        }
    }
}
