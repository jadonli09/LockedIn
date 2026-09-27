//
//  LivenessAnalyzer.swift
//  LockedIn
//
//  Rolling-window driver for the liveness cues. The window is time-pruned
//  (~2 s) but the evaluator's fire counts are not — they accumulate across
//  the whole scan, so a spoof tell can't be waited out.
//
//  Ported from Glance (github.com/jonnyoo/glance, MIT).
//

import Foundation

@MainActor
final class LivenessAnalyzer {
    private let windowDuration: TimeInterval
    private var frames: [LivenessFrame] = []
    private var evaluator: LivenessEvaluator
    private(set) var lastSnapshot = LivenessSnapshot.empty

    init(level: LivenessLevel, windowDuration: TimeInterval = 2.0) {
        self.windowDuration = windowDuration
        evaluator = LivenessEvaluator(level: level)
    }

    func reset() {
        frames.removeAll()
        evaluator.reset()
        lastSnapshot = .empty
    }

    /// Call once per frame with a detected face, regardless of whether it
    /// matched an identity, so liveness stays an independent gate.
    @discardableResult
    func observe(_ frame: LivenessFrame) -> LivenessSnapshot {
        frames.append(frame)
        frames.removeAll { frame.timestamp.timeIntervalSince($0.timestamp) > windowDuration }

        let geometry = GeometryLiveness.evaluate(frames)
        let readings = LivenessCues.readings(window: frames, planar: geometry.planarReading)
        let snapshot = evaluator.observe(readings)
        lastSnapshot = snapshot
        return snapshot
    }
}
