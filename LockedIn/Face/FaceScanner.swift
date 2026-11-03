//
//  FaceScanner.swift
//  LockedIn
//
//  One scan cycle: lease the camera, look for the enrolled face for up to
//  `seconds`, run liveness alongside, and resolve. Shared by the lock-screen
//  unlock and the identity gate so both make the same decision the same way.
//
//  Recognition and liveness run concurrently and each latches when it
//  succeeds; the scan resolves the moment the second one lands. Liveness never
//  fails a scan by staying undecided — only a deny cue can.
//
//  Adapted from Glance's FaceUnlockCoordinator.observeScanWindow (MIT).
//

import CoreGraphics
import Defaults
import Foundation
import os

enum FaceScanOutcome: Equatable {
    case matched(name: String, similarity: Float)
    /// Several consecutive frames with a face that isn't the enrolled one.
    case wrongFace
    /// A deny cue fired — rejected regardless of match.
    case spoofSuspected(String)
    /// The window closed without a face ever resolving either way.
    case noFace
    case cancelled
    case unavailable(String)
}

enum FaceScanner {
    private static let log = Logger(subsystem: "com.jadonli.lockedin", category: "FaceUnlock")

    /// Consecutive below-threshold frames before "not you" is called.
    static let wrongFaceStreakThreshold = 6

    @MainActor
    static func scan(
        client: String,
        seconds: TimeInterval,
        livenessLevel: LivenessLevel,
        threshold: Float,
        shouldContinue: @escaping @MainActor () -> Bool = { true }
    ) async -> FaceScanOutcome {
        let store = FaceEnrollmentStore.shared
        guard store.hasEnrollment, !store.isStale else {
            return .unavailable("No usable face enrollment.")
        }
        let started = ContinuousClock.now
        func mark(_ stage: String) {
            let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
            log.info("[\(client, privacy: .public)] \(stage, privacy: .public) +\(ms, privacy: .public) ms")
        }
        let camera = CameraManager.shared
        guard let lease = await camera.acquire(client: client, maxFPS: 30) else {
            return .unavailable(camera.errorMessage ?? "Camera unavailable.")
        }
        defer { camera.release(lease) }
        mark("camera ready")

        let pipeline = FaceRecognitionPipeline.shared
        let liveness = LivenessAnalyzer(level: livenessLevel)
        let identities = store.identities
        let deadline = Date().addingTimeInterval(seconds)

        var consecutiveWrongFace = 0
        var readyMatch: ScoredIdentity?
        var livenessConfirmed = livenessLevel == .off
        var lastFaceBox: CGRect?
        var lastFrameID: UInt64?
        var sawFace = false

        while Date() < deadline, !Task.isCancelled, shouldContinue() {
            guard let frame = camera.currentFrame, frame.id != lastFrameID else {
                try? await Task.sleep(for: .milliseconds(20))
                continue
            }
            lastFrameID = frame.id

            let previousBox = lastFaceBox
            let candidates = await Task.detached(priority: .userInitiated) {
                (try? pipeline.recognizeCandidates(in: frame.image, preferNear: previousBox)) ?? []
            }.value

            guard !candidates.isEmpty else {
                consecutiveWrongFace = 0
                lastFaceBox = nil
                try? await Task.sleep(for: .milliseconds(20))
                continue
            }
            if !sawFace { sawFace = true; mark("first face") }

            // Follow whichever face is the enrolled user — someone else being in
            // frame (or in front) must not hide them. Otherwise the tracked face.
            var chosen = candidates[0]
            var match: ScoredIdentity?
            for candidate in candidates {
                let scored = pipeline.score(candidate.embedding, against: identities)
                if let hit = pipeline.bestMatch(in: scored, threshold: threshold) {
                    chosen = candidate
                    match = hit
                    break
                }
            }

            // A different person: their liveness history isn't this one's.
            if let previousBox, !Self.isSameFace(previousBox, chosen.face.normalizedBoundingBox) {
                liveness.reset()
                livenessConfirmed = livenessLevel == .off
                consecutiveWrongFace = 0
            }
            lastFaceBox = chosen.face.normalizedBoundingBox

            if livenessLevel != .off {
                let result = chosen
                let livenessFrame = await Task.detached(priority: .userInitiated) {
                    let crop = CameraManager.renderCrop(from: frame, imageRect: result.face.boundingBox)
                    return LivenessFeatureExtractor.extract(from: result, frame: frame.image, faceCrop: crop)
                }.value
                let snapshot = liveness.observe(livenessFrame)
                switch snapshot.decision {
                case .denied:
                    return .spoofSuspected(snapshot.decision.denialReason ?? "Liveness check failed.")
                case .confirmed:
                    if !livenessConfirmed { mark("liveness confirmed") }
                    livenessConfirmed = true
                case .pending:
                    break
                }
            }

            if let match {
                consecutiveWrongFace = 0
                readyMatch = match
            } else {
                readyMatch = nil
                consecutiveWrongFace += 1
                if consecutiveWrongFace >= wrongFaceStreakThreshold {
                    return .wrongFace
                }
            }

            if let readyMatch, livenessConfirmed {
                mark("matched")
                return .matched(name: readyMatch.identity.name, similarity: readyMatch.centroidSimilarity)
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return Task.isCancelled || !shouldContinue() ? .cancelled : .noFace
    }

    /// Same tolerance the pipeline uses for frame-to-frame continuity.
    private static func isSameFace(_ a: CGRect, _ b: CGRect) -> Bool {
        hypot(a.midX - b.midX, a.midY - b.midY) < 0.3
    }

    /// The threshold from Settings.
    static var configuredThreshold: Float {
        Defaults[.faceMatchStrictness].threshold
    }
}
