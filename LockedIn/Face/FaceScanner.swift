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
            let wantsLiveness = livenessLevel != .off
            let outcome = await Task.detached(priority: .userInitiated) { () -> (FaceRecognitionResult, LivenessFrame?)? in
                guard let result = try? pipeline.recognize(in: frame.image, preferNear: previousBox) else { return nil }
                guard wantsLiveness else { return (result, nil) }
                let crop = CameraManager.renderCrop(from: frame, imageRect: result.face.boundingBox)
                return (result, LivenessFeatureExtractor.extract(from: result, frame: frame.image, faceCrop: crop))
            }.value

            guard let (result, livenessFrame) = outcome else {
                consecutiveWrongFace = 0
                lastFaceBox = nil
                try? await Task.sleep(for: .milliseconds(20))
                continue
            }
            lastFaceBox = result.face.normalizedBoundingBox
            if !sawFace { sawFace = true; mark("first face") }

            if let livenessFrame {
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

            let scored = pipeline.score(result.embedding, against: identities)
            if let match = pipeline.bestMatch(in: scored, threshold: threshold) {
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

    /// The threshold from Settings.
    static var configuredThreshold: Float {
        Defaults[.faceMatchStrictness].threshold
    }
}
