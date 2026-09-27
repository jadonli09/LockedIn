//
//  LivenessCues.swift
//  LockedIn
//
//  Liveness decision model: five independent cues, no combined score. DENY
//  cues override CONFIRM cues unconditionally; a confirm cue's absence is
//  never a failure. Pure — the evaluator is driven frame by frame in tests.
//
//  Ported from Glance (github.com/jonnyoo/glance, MIT).
//

import CoreGraphics
import Foundation

/// One cue's latest reading. `confidence` 0 is always an abstention, never a
/// reading of zero — a cue that can't see anything must not convict or acquit.
struct CueReading: Equatable {
    /// 0...1 strength of this cue's own evidence, in the direction that cue
    /// argues for (spoof-ness for deny cues, liveness for confirm cues).
    let level: Float
    let confidence: Float

    static let none = CueReading(level: 0, confidence: 0)
}

enum LivenessCueRole: Equatable {
    /// Evidence of a spoof. Firing fails the scan and overrides confirmation.
    case deny
    /// Evidence of a real face. Firing passes the liveness half of the scan.
    case confirm
}

enum LivenessCue: String, CaseIterable, Hashable, Identifiable {
    case glossGlare
    case deviceDetected
    case flatVs3D
    case depthPose
    case blink

    var id: String { rawValue }

    var title: String {
        switch self {
        case .glossGlare: "Gloss/glare"
        case .deviceDetected: "Device detected"
        case .flatVs3D: "Flat vs 3D"
        case .depthPose: "Depth/pose"
        case .blink: "Blink"
        }
    }

    var role: LivenessCueRole {
        switch self {
        case .glossGlare, .deviceDetected: .deny
        case .flatVs3D, .depthPose, .blink: .confirm
        }
    }
}

/// How much liveness checking runs. Both `light` and `heavy` always run the
/// deny cues — the difference is whether a *positive* proof of life is also
/// required before unlocking. `off` skips liveness entirely.
enum LivenessLevel: String, CaseIterable, Identifiable, Codable {
    case off
    /// Deny-only: "live unless proven otherwise." Never blocks a user who sits still.
    case light
    /// Deny cues plus at least one confirm cue must fire. Can block a user who
    /// holds perfectly still and never blinks for the whole scan.
    case heavy

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: "Off"
        case .light: "Light"
        case .heavy: "Heavy"
        }
    }

    var summary: String {
        switch self {
        case .off: "Face match alone unlocks — a photo of you would pass."
        case .light: "Rejects obvious spoofs (screens, phones held up)."
        case .heavy: "Also requires proof of a real face: a blink or head turn."
        }
    }
}

/// Fire thresholds per cue: a cue counts a frame when its reading is confident
/// and at/above `level`, and fires once it has counted `frames` of them.
struct LivenessTuning: Equatable {
    var glossLevel: Float = 0.04
    var glossFrames: Int = 3
    var deviceLevel: Float = 0.15
    var deviceFrames: Int = 3
    var flatVs3DLevel: Float = 0.25
    var flatVs3DFrames: Int = 2
    /// A remapped correlation `(r + 1) / 2`, so 0.8 requires r >= 0.6.
    var depthPoseLevel: Float = 0.8
    var depthPoseFrames: Int = 2
    var blinkFrames: Int = 1
    /// Frames Light mode waits before auto-confirming, so deny cues get a fair
    /// chance to fire first.
    var lightModeMinimumFrames: Int = 3

    static let `default` = LivenessTuning()

    func level(for cue: LivenessCue) -> Float {
        switch cue {
        case .glossGlare: glossLevel
        case .deviceDetected: deviceLevel
        case .flatVs3D: flatVs3DLevel
        case .depthPose: depthPoseLevel
        case .blink: 0.5
        }
    }

    func frames(for cue: LivenessCue) -> Int {
        switch cue {
        case .glossGlare: glossFrames
        case .deviceDetected: deviceFrames
        case .flatVs3D: flatVs3DFrames
        case .depthPose: depthPoseFrames
        case .blink: blinkFrames
        }
    }
}

enum LivenessDecision: Equatable {
    /// Nothing decided yet. Not a failure — the scan should keep going.
    case pending
    /// Cue is nil when Light mode auto-confirmed rather than any cue firing.
    case confirmed(by: LivenessCue?)
    case denied(by: LivenessCue)

    var isConfirmed: Bool { if case .confirmed = self { return true }; return false }
    var isDenied: Bool { if case .denied = self { return true }; return false }

    var denialReason: String? {
        guard case .denied(let cue) = self else { return nil }
        switch cue {
        case .glossGlare: return "Screen glare detected — this looks like a photo on a display."
        case .deviceDetected: return "A device-shaped rectangle overlaps the face — this looks like a phone or screen."
        default: return "Liveness check failed."
        }
    }
}

struct LivenessCueState: Equatable {
    var reading: CueReading = .none
    /// Cumulative, not consecutive — forgiving of one-frame dropouts.
    var framesCounted: Int = 0
    var hasFired: Bool = false
}

struct LivenessSnapshot: Equatable {
    let decision: LivenessDecision
    let level: LivenessLevel
    let cueStates: [LivenessCue: LivenessCueState]
    let frameCount: Int

    static let empty = LivenessSnapshot(decision: .pending, level: .light, cueStates: [:], frameCount: 0)
}

/// The stateful decision core: firing is latched, so a cue that has fired stays
/// fired for the rest of the scan — a spoof tell can't be waited out.
struct LivenessEvaluator {
    var level: LivenessLevel
    var tuning: LivenessTuning

    private(set) var states: [LivenessCue: LivenessCueState] = [:]
    private(set) var framesObserved: Int = 0

    init(level: LivenessLevel = .light, tuning: LivenessTuning = .default) {
        self.level = level
        self.tuning = tuning
    }

    mutating func reset() {
        states = [:]
        framesObserved = 0
    }

    mutating func observe(_ readings: [LivenessCue: CueReading]) -> LivenessSnapshot {
        framesObserved += 1

        for cue in LivenessCue.allCases {
            var state = states[cue] ?? LivenessCueState()
            let reading = readings[cue] ?? .none
            state.reading = reading
            if reading.confidence > 0, reading.level >= tuning.level(for: cue) {
                state.framesCounted += 1
                if state.framesCounted >= tuning.frames(for: cue) {
                    state.hasFired = true
                }
            }
            states[cue] = state
        }

        return LivenessSnapshot(decision: currentDecision(), level: level, cueStates: states, frameCount: framesObserved)
    }

    /// Deny is evaluated first and is unconditional.
    private func currentDecision() -> LivenessDecision {
        if level == .off { return .confirmed(by: nil) }

        for cue in LivenessCue.allCases where cue.role == .deny && (states[cue]?.hasFired ?? false) {
            return .denied(by: cue)
        }

        if level == .light {
            return framesObserved >= tuning.lightModeMinimumFrames ? .confirmed(by: nil) : .pending
        }

        for cue in LivenessCue.allCases where cue.role == .confirm && (states[cue]?.hasFired ?? false) {
            return .confirmed(by: cue)
        }
        return .pending
    }
}

/// Turns a rolling window into this frame's reading for every cue. Deny cues
/// read only the latest frame; confirm cues read the whole window.
enum LivenessCues {
    static func readings(window: [LivenessFrame], planar: CueReading) -> [LivenessCue: CueReading] {
        [
            .glossGlare: glossGlare(window.last),
            .deviceDetected: deviceDetected(window.last),
            .flatVs3D: planar,
            .depthPose: LivenessScoring.poseDepthConsistency(window),
            .blink: LivenessScoring.blinkDynamics(window),
        ]
    }

    /// Skin gives many small scattered specular points; glass gives one big flat
    /// blob. `specularFraction` alone would fire on a bright forehead, so it's
    /// gated by how concentrated the glare is.
    static func glossGlare(_ frame: LivenessFrame?) -> CueReading {
        guard let glare = frame?.glare else { return .none }
        let fractionScore = ramp(glare.specularFraction, floor: 0.01, ceiling: 0.08)
        let clusterFactor = ramp(glare.specularClusterRatio, floor: 0.3, ceiling: 1.0)
        let level = fractionScore * (0.3 + 0.7 * clusterFactor)
        // Below ~50 native px of face there isn't enough detail; full trust by ~130px.
        let confidence = ramp(Float(glare.cropPixelWidth), floor: 50, ceiling: 130)
        return CueReading(level: level, confidence: confidence)
    }

    static func deviceDetected(_ frame: LivenessFrame?) -> CueReading {
        guard let overlap = frame?.deviceOverlapFraction else { return .none }
        return CueReading(level: Float(min(max(overlap, 0), 1)), confidence: 1)
    }

    static func ramp(_ value: Float, floor: Float, ceiling: Float) -> Float {
        min(max((value - floor) / max(ceiling - floor, 0.0001), 0), 1)
    }
}
