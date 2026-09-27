//
//  FaceLogicTests.swift
//  LockedInTests
//
//  Unit tests for the pure face logic: embedding math and the two-sided
//  match threshold, the presence state machine's timing, the liveness
//  evaluator's deny/confirm rules, and away-time persistence.
//

import XCTest

final class FaceMatchingTests: XCTestCase {
    private func unit(_ values: [Float]) -> [Float] { FaceEmbedding.l2Normalized(values) }

    func testL2NormalizationProducesUnitLength() {
        let v = FaceEmbedding.l2Normalized([3, 4])
        XCTAssertEqual(v[0], 0.6, accuracy: 1e-6)
        XCTAssertEqual(v[1], 0.8, accuracy: 1e-6)
        // Zero vector is returned untouched rather than producing NaNs.
        XCTAssertEqual(FaceEmbedding.l2Normalized([0, 0]), [0, 0])
    }

    func testCosineSimilarityBounds() {
        XCTAssertEqual(FaceEmbedding.cosineSimilarity([1, 0], [1, 0]), 1, accuracy: 1e-6)
        XCTAssertEqual(FaceEmbedding.cosineSimilarity([1, 0], [0, 1]), 0, accuracy: 1e-6)
        XCTAssertEqual(FaceEmbedding.cosineSimilarity([1, 0], [-1, 0]), -1, accuracy: 1e-6)
        // Mismatched or empty vectors never match.
        XCTAssertEqual(FaceEmbedding.cosineSimilarity([1, 0], [1]), 0)
        XCTAssertEqual(FaceEmbedding.cosineSimilarity([], []), 0)
    }

    func testAverageRenormalizesSoMagnitudeCannotDominate() {
        // A huge-magnitude sample pointing along x and a unit sample along y must
        // average to the diagonal, not be swallowed by the big one.
        let mean = FaceEmbedding.average([[100, 0], [0, 1]])!
        XCTAssertEqual(mean[0], mean[1], accuracy: 1e-6)
        XCTAssertEqual(mean[0] * mean[0] + mean[1] * mean[1], 1, accuracy: 1e-6)
        XCTAssertNil(FaceEmbedding.average([]))
    }

    private func identity(name: String, samples: [[Float]], model: String = "m1") -> FaceIdentity {
        FaceIdentity(
            id: UUID(), name: name,
            samples: samples.map { FaceSample(embedding: $0, pose: nil, capturedAt: Date(), quality: 0.8) },
            modelIdentifier: model, embeddingDimension: samples.first?.count ?? 0, createdAt: Date()
        )
    }

    func testBestMatchRequiresBothCentroidAndClosestSample() {
        // Two samples 90° apart: the centroid sits on the diagonal.
        let me = identity(name: "me", samples: [[1, 0], [0, 1]])
        let probe = unit([1, 0.2])
        let scored = FaceMatcher.score(probe, against: [me])
        XCTAssertEqual(scored.count, 1)
        XCTAssertGreaterThan(scored[0].maxSampleSimilarity, scored[0].centroidSimilarity)

        // Centroid similarity is ~0.83 here, max-sample ~0.98.
        XCTAssertNotNil(FaceMatcher.bestMatch(in: scored, threshold: 0.8, modelIdentifier: "m1"))
        XCTAssertNil(FaceMatcher.bestMatch(in: scored, threshold: 0.9, modelIdentifier: "m1"),
                     "centroid below threshold must fail even though one sample clears it")
    }

    func testStaleIdentityNeverMatches() {
        let me = identity(name: "me", samples: [[1, 0]], model: "old-model")
        let scored = FaceMatcher.score([1, 0], against: [me])
        XCTAssertEqual(scored[0].centroidSimilarity, 1, accuracy: 1e-6)
        XCTAssertNil(FaceMatcher.bestMatch(in: scored, threshold: 0.5, modelIdentifier: "new-model"))
    }

    func testScoringSortsByCentroidAndSkipsEmptyIdentities() {
        let near = identity(name: "near", samples: [[1, 0]])
        let far = identity(name: "far", samples: [[0, 1]])
        let empty = identity(name: "empty", samples: [])
        let scored = FaceMatcher.score(unit([1, 0.1]), against: [far, empty, near])
        XCTAssertEqual(scored.map(\.identity.name), ["near", "far"])
    }

    func testStrictnessLevelsAreOrdered() {
        XCTAssertLessThan(FaceMatchStrictness.relaxed.threshold, FaceMatchStrictness.standard.threshold)
        XCTAssertLessThan(FaceMatchStrictness.standard.threshold, FaceMatchStrictness.strict.threshold)
    }
}

final class PresenceStateMachineTests: XCTestCase {
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testStaysPresentWhileEnrolledFaceIsSeen() {
        var m = PresenceStateMachine(awayThreshold: 60)
        XCTAssertNil(m.observe(.enrolledFace, at: t0))
        XCTAssertNil(m.observe(.enrolledFace, at: t0.addingTimeInterval(300)))
        XCTAssertEqual(m.state, .present)
    }

    func testBriefAbsenceBelowThresholdIsForgiven() {
        var m = PresenceStateMachine(awayThreshold: 60)
        XCTAssertNil(m.observe(.noFace, at: t0))
        XCTAssertNil(m.observe(.noFace, at: t0.addingTimeInterval(30)))
        XCTAssertNil(m.observe(.enrolledFace, at: t0.addingTimeInterval(45)))
        XCTAssertEqual(m.state, .present)
    }

    func testAwayFiresOnceAtThresholdAndBackdatesToLastSighting() {
        var m = PresenceStateMachine(awayThreshold: 60)
        XCTAssertNil(m.observe(.enrolledFace, at: t0))
        XCTAssertNil(m.observe(.noFace, at: t0.addingTimeInterval(3)))     // unsure since t0+3
        XCTAssertNil(m.observe(.otherFace, at: t0.addingTimeInterval(40)))
        let event = m.observe(.noFace, at: t0.addingTimeInterval(63))
        XCTAssertEqual(event, .becameAway(awaySince: t0.addingTimeInterval(3)))
        XCTAssertTrue(m.state.isAway)
        // Still away: no repeated event.
        XCTAssertNil(m.observe(.noFace, at: t0.addingTimeInterval(120)))
    }

    func testAStrangerAtTheDeskCountsAsAway() {
        var m = PresenceStateMachine(awayThreshold: 30)
        XCTAssertNil(m.observe(.otherFace, at: t0))
        XCTAssertEqual(m.observe(.otherFace, at: t0.addingTimeInterval(30)), .becameAway(awaySince: t0))
    }

    func testReturnNeedsAStreakAndReportsTotalAbsence() {
        var m = PresenceStateMachine(awayThreshold: 60, returnStreakRequired: 2)
        _ = m.observe(.noFace, at: t0)
        _ = m.observe(.noFace, at: t0.addingTimeInterval(60))
        XCTAssertTrue(m.state.isAway)
        // One lucky sighting isn't enough…
        XCTAssertNil(m.observe(.enrolledFace, at: t0.addingTimeInterval(200)))
        // …and a miss resets the streak.
        XCTAssertNil(m.observe(.noFace, at: t0.addingTimeInterval(203)))
        XCTAssertNil(m.observe(.enrolledFace, at: t0.addingTimeInterval(206)))
        XCTAssertEqual(m.observe(.enrolledFace, at: t0.addingTimeInterval(209)), .returned(awayDuration: 209))
        XCTAssertEqual(m.state, .present)
    }

    func testResetForgetsAbsence() {
        var m = PresenceStateMachine(awayThreshold: 10)
        _ = m.observe(.noFace, at: t0)
        _ = m.observe(.noFace, at: t0.addingTimeInterval(10))
        XCTAssertTrue(m.state.isAway)
        m.reset()
        XCTAssertEqual(m.state, .present)
        XCTAssertNil(m.observe(.enrolledFace, at: t0.addingTimeInterval(20)))
    }
}

final class LivenessEvaluatorTests: XCTestCase {
    private func readings(
        gloss: CueReading = .none, device: CueReading = .none,
        planar: CueReading = .none, depth: CueReading = .none, blink: CueReading = .none
    ) -> [LivenessCue: CueReading] {
        [.glossGlare: gloss, .deviceDetected: device, .flatVs3D: planar, .depthPose: depth, .blink: blink]
    }

    func testOffModeConfirmsImmediately() {
        var e = LivenessEvaluator(level: .off)
        XCTAssertTrue(e.observe(readings()).decision.isConfirmed)
    }

    func testLightModeAutoConfirmsAfterMinimumFrames() {
        var e = LivenessEvaluator(level: .light)
        XCTAssertEqual(e.observe(readings()).decision, .pending)
        XCTAssertEqual(e.observe(readings()).decision, .pending)
        XCTAssertEqual(e.observe(readings()).decision, .confirmed(by: nil))
    }

    func testDenyCueNeedsItsFrameCountAndThenLatches() {
        var e = LivenessEvaluator(level: .light)
        let phone = readings(device: CueReading(level: 0.9, confidence: 1))
        XCTAssertEqual(e.observe(phone).decision, .pending)
        XCTAssertEqual(e.observe(phone).decision, .pending)
        XCTAssertEqual(e.observe(phone).decision, .denied(by: .deviceDetected))
        // Latched: clean frames afterwards don't un-deny, and it beats Light's auto-confirm.
        XCTAssertEqual(e.observe(readings()).decision, .denied(by: .deviceDetected))
        XCTAssertEqual(e.observe(readings()).decision.denialReason?.isEmpty, false)
    }

    func testAbstentionsNeverCount() {
        var e = LivenessEvaluator(level: .light)
        // Level would fire, but confidence 0 is an abstention.
        let unsure = readings(gloss: CueReading(level: 1, confidence: 0))
        for _ in 0..<5 { _ = e.observe(unsure) }
        XCTAssertFalse(e.observe(unsure).decision.isDenied)
    }

    func testHeavyModeWaitsForAConfirmCue() {
        var e = LivenessEvaluator(level: .heavy)
        for _ in 0..<5 {
            XCTAssertEqual(e.observe(readings()).decision, .pending, "heavy must not auto-confirm")
        }
        XCTAssertEqual(e.observe(readings(blink: CueReading(level: 1, confidence: 1))).decision, .confirmed(by: .blink))
    }

    func testDenyOverridesAnEarlierConfirmation() {
        var e = LivenessEvaluator(level: .heavy)
        XCTAssertEqual(e.observe(readings(blink: CueReading(level: 1, confidence: 1))).decision, .confirmed(by: .blink))
        let glare = readings(gloss: CueReading(level: 0.5, confidence: 1))
        _ = e.observe(glare); _ = e.observe(glare)
        XCTAssertEqual(e.observe(glare).decision, .denied(by: .glossGlare))
    }

    func testCueFramesAccumulateAcrossDropouts() {
        var e = LivenessEvaluator(level: .heavy)
        let depth = readings(depth: CueReading(level: 0.9, confidence: 1))
        _ = e.observe(depth)
        _ = e.observe(readings()) // a Vision dropout frame in between
        XCTAssertEqual(e.observe(depth).decision, .confirmed(by: .depthPose))
    }
}

final class LivenessScoringTests: XCTestCase {
    private func frame(at seconds: TimeInterval, ear: CGFloat? = nil, yaw: Float? = nil, noseOffset: CGFloat? = nil) -> LivenessFrame {
        LivenessFrame(
            timestamp: Date(timeIntervalSinceReferenceDate: seconds),
            landmarks: [],
            interocularDistance: 60,
            yaw: yaw,
            leftEyeAspectRatio: ear, rightEyeAspectRatio: ear,
            noseOffsetRatio: noseOffset,
            hasReliableLandmarks: true,
            deviceOverlapFraction: nil
        )
    }

    func testBlinkIsADipWithRecoveryOnBothSides() {
        let blink = [0.30, 0.30, 0.12, 0.29, 0.30].enumerated().map { frame(at: Double($0.offset) * 0.05, ear: $0.element) }
        XCTAssertEqual(LivenessScoring.blinkDynamics(blink), CueReading(level: 1, confidence: 1))

        // Eyes simply closing at the end (no recovery) is not a blink.
        let closing = [0.30, 0.30, 0.30, 0.20, 0.12].enumerated().map { frame(at: Double($0.offset) * 0.05, ear: $0.element) }
        XCTAssertEqual(LivenessScoring.blinkDynamics(closing), .none)
        XCTAssertEqual(LivenessScoring.blinkDynamics(Array(blink.prefix(3))), .none, "too few frames abstains")
    }

    func testDepthPoseTracksYawOnARealFaceAndAbstainsOnAPhoto() {
        // Real face: nose offset follows tan(yaw) across a 30° sweep.
        let yaws: [Float] = [-0.26, -0.13, 0, 0.13, 0.26]
        let real = yaws.enumerated().map { frame(at: Double($0.offset) * 0.1, yaw: $0.element, noseOffset: CGFloat(tan($0.element)) * 0.4) }
        let reading = LivenessScoring.poseDepthConsistency(real)
        XCTAssertGreaterThan(reading.confidence, 0)
        XCTAssertGreaterThan(reading.level, 0.95)

        // Flat print rotated in front of the camera: Vision still reports yaw, but the
        // nose never moves relative to the eyes.
        let flat = yaws.enumerated().map { frame(at: Double($0.offset) * 0.1, yaw: $0.element, noseOffset: 0.05) }
        XCTAssertEqual(LivenessScoring.poseDepthConsistency(flat), .none, "constant offset has no variance → abstain")

        // Too little head rotation to measure anything.
        let still = [0.0, 0.01, 0.02, 0.03].enumerated().map { frame(at: Double($0.offset) * 0.1, yaw: Float($0.element), noseOffset: CGFloat($0.element)) }
        XCTAssertEqual(LivenessScoring.poseDepthConsistency(still), .none)
    }

    func testGlossGlareGatesOnConcentrationAndCropDetail() {
        func sample(fraction: Float, cluster: Float, width: CGFloat) -> LivenessFrame {
            LivenessFrame(
                timestamp: Date(), landmarks: [], interocularDistance: nil, yaw: nil,
                leftEyeAspectRatio: nil, rightEyeAspectRatio: nil, noseOffsetRatio: nil,
                hasReliableLandmarks: false, deviceOverlapFraction: nil,
                glare: GlareSample(cropPixelWidth: width, specularFraction: fraction, specularClusterRatio: cluster)
            )
        }
        let screen = LivenessCues.glossGlare(sample(fraction: 0.08, cluster: 1.0, width: 200))
        let forehead = LivenessCues.glossGlare(sample(fraction: 0.08, cluster: 0.2, width: 200))
        XCTAssertGreaterThan(screen.level, forehead.level)
        XCTAssertEqual(screen.confidence, 1)
        XCTAssertEqual(LivenessCues.glossGlare(sample(fraction: 0.08, cluster: 1.0, width: 40)).confidence, 0, "tiny crop abstains")
        XCTAssertEqual(LivenessCues.glossGlare(nil), .none)
    }
}

final class FocusAwayAccountingTests: XCTestCase {
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testAwayTotalRoundTripsAndDefaultsForOldSessions() throws {
        var s = FocusSessionState.startingFocus(preset: .classic, at: t0)
        s.awayTotal = 95
        let restored = try JSONDecoder().decode(FocusSessionState.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(restored.awayTotal, 95)

        // A session persisted before awayTotal existed still decodes.
        let legacy = """
        {"preset":{"focusMinutes":25,"breakMinutes":5},"phase":"focus","phaseStart":0,"phaseDuration":1500,"completedFocusCount":2}
        """
        let old = try JSONDecoder().decode(FocusSessionState.self, from: Data(legacy.utf8))
        XCTAssertEqual(old.awayTotal, 0)
        XCTAssertEqual(old.completedFocusCount, 2)
        XCTAssertFalse(old.isPaused)
    }

    func testPresencePauseBackdatesLikeIdlePause() {
        // The monitor notices at +75s that the user has been gone since +15s and
        // pauses backdated: only 15 attended seconds count.
        var s = FocusSessionState.startingFocus(preset: .classic, at: t0)
        let noticed = t0.addingTimeInterval(75)
        s.pause(at: noticed.addingTimeInterval(-60))
        XCTAssertEqual(s.elapsed(at: noticed), 15)
    }
}
