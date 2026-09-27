//
//  FaceEnrollmentController.swift
//  LockedIn
//
//  Guided multi-direction capture: center plus the 8 compass directions,
//  two samples each, so the template covers the angles a webcam actually
//  sees you from. A pose captures once the head has held inside its yaw/pitch
//  band for half a second with a 5-point alignment and acceptable quality.
//
//  Ported from Glance's OnboardingController enroll step (MIT).
//

import Combine
import CoreGraphics
import Foundation

enum EnrollmentPose: Int, CaseIterable {
    case center, left, topLeft, top, topRight, right, bottomRight, bottom, bottomLeft

    enum YawBand { case left, none, right }
    enum PitchBand { case up, none, down }

    var yawBand: YawBand {
        switch self {
        case .left, .topLeft, .bottomLeft: .left
        case .right, .topRight, .bottomRight: .right
        case .center, .top, .bottom: .none
        }
    }

    var pitchBand: PitchBand {
        switch self {
        case .top, .topLeft, .topRight: .up
        case .bottom, .bottomLeft, .bottomRight: .down
        case .center, .left, .right: .none
        }
    }

    /// Compass angle (0 = up, clockwise) of this pose's ring sector; nil for center.
    var compassAngle: Double? {
        switch self {
        case .center: nil
        case .left: 270
        case .topLeft: 315
        case .top: 0
        case .topRight: 45
        case .right: 90
        case .bottomRight: 135
        case .bottom: 180
        case .bottomLeft: 225
        }
    }

    var instruction: String {
        switch self {
        case .center: "Look straight at the camera"
        case .left: "Turn your head slightly left"
        case .topLeft: "Turn your head to the top left"
        case .top: "Turn your head slightly up"
        case .topRight: "Turn your head to the top right"
        case .right: "Turn your head slightly right"
        case .bottomRight: "Turn your head to the bottom right"
        case .bottom: "Turn your head slightly down"
        case .bottomLeft: "Turn your head to the bottom left"
        }
    }

    /// Relaxes this pose's bands; >1 is easier. The downward poses are hard to hit on a laptop.
    var matchLeniency: Float {
        switch self {
        case .bottomLeft, .bottomRight: 1.5
        case .bottom: 1.2
        default: 1
        }
    }

    var name: String {
        switch self {
        case .center: "center"
        case .left: "left"
        case .topLeft: "top_left"
        case .top: "top"
        case .topRight: "top_right"
        case .right: "right"
        case .bottomRight: "bottom_right"
        case .bottom: "bottom"
        case .bottomLeft: "bottom_left"
        }
    }
}

@MainActor
final class FaceEnrollmentController: ObservableObject {
    struct HeadTurn: Equatable {
        /// Compass angle the head is currently turned toward.
        let angle: Double
        /// 0...1 how far toward the target band the turn has come.
        let progress: Double
    }

    enum Stage: Equatable {
        case starting
        case capturing
        case saving
        case done
        case failed(String)
    }

    @Published private(set) var stage: Stage = .starting
    @Published private(set) var currentPoseIndex = 0
    @Published private(set) var capturedForCurrentPose = 0
    @Published private(set) var capturedPoses: Set<EnrollmentPose> = []
    @Published private(set) var centerPulseTick = 0
    @Published private(set) var faceDetected = false
    @Published private(set) var isTooFar = false
    @Published private(set) var headTurn: HeadTurn?

    static let samplesPerPose = 2
    private let requiredMatchStreak = 3
    private let poseHoldDuration: Duration = .milliseconds(500)
    private let qualityFloor: Float = 0.2
    private let initialCaptureDelay: Duration = .seconds(1.5)
    /// Enrollment wants a closer face than unlock's bystander cutoff.
    private let enrollmentMinimumFaceWidth: Float = max(FaceRecognitionPipeline.minimumProminentFaceWidth, 0.2)

    // Pose-matching bands, radians. Vision: left turn is positive yaw; looking up is negative pitch.
    private let yawInnerThreshold: Float = 0.25
    private let yawCenterTolerance: Float = 0.18
    private let yawOuterCap: Float = 1.2
    private let pitchInnerThreshold: Float = 0.20
    private let pitchCenterTolerance: Float = 0.15
    private let pitchOuterCap: Float = 0.9
    /// If a pose takes longer than this, bands widen so an odd camera angle can't strand the user.
    private let stallTimeout: Duration = .seconds(12)
    private let stallWidenFactor: Float = 1.25
    private let headTurnDeadzone = 0.15

    private var samples: [FaceSample] = []
    private var matchStreak = 0
    private var isProcessingFrame = false
    private var poseStartedAt: ContinuousClock.Instant = .now
    private var captureReadyAt: ContinuousClock.Instant = .now
    private var poseHoldStartedAt: ContinuousClock.Instant?
    private var currentYaw: Float?
    private var currentPitch: Float?
    private var lease: UUID?
    private var frameSubscription: AnyCancellable?

    var currentPose: EnrollmentPose? {
        EnrollmentPose.allCases.indices.contains(currentPoseIndex) ? EnrollmentPose.allCases[currentPoseIndex] : nil
    }

    var instruction: String {
        switch stage {
        case .starting: return "Starting camera…"
        case .saving: return "Saving…"
        case .done: return "Enrolled"
        case .failed(let message): return message
        case .capturing:
            if isTooFar { return "Move a little closer" }
            if !faceDetected { return "Center your face in the circle" }
            return currentPose?.instruction ?? ""
        }
    }

    var overallProgress: Double {
        let total = Double(EnrollmentPose.allCases.count * Self.samplesPerPose)
        let done = Double(currentPoseIndex * Self.samplesPerPose + capturedForCurrentPose)
        return min(1, done / total)
    }

    var totalSamples: Int { EnrollmentPose.allCases.count * Self.samplesPerPose }
    var capturedSamples: Int { samples.count }

    func start() {
        Task { [weak self] in
            guard let self else { return }
            self.lease = await CameraManager.shared.acquire(client: "Enrollment", maxFPS: 30)
            guard self.lease != nil else {
                self.stage = .failed(CameraManager.shared.errorMessage ?? "Camera unavailable.")
                return
            }
            self.stage = .capturing
            self.poseStartedAt = .now
            self.captureReadyAt = .now + self.initialCaptureDelay
            self.frameSubscription = CameraManager.shared.$currentFrame
                .compactMap { $0 }
                .sink { [weak self] frame in
                    Task { @MainActor [weak self] in await self?.process(frame) }
                }
        }
    }

    func cancel() {
        frameSubscription = nil
        CameraManager.shared.release(lease)
        lease = nil
    }

    private enum FrameOutcome {
        case noFace
        case tooFar
        case ready(FaceRecognitionResult)
    }

    private func process(_ frame: CameraFrame) async {
        guard stage == .capturing, !isProcessingFrame, let pose = currentPose else { return }
        isProcessingFrame = true
        defer { isProcessingFrame = false }

        let pipeline = FaceRecognitionPipeline.shared
        let minimumWidth = enrollmentMinimumFaceWidth
        let image = frame.image
        let outcome = await Task.detached(priority: .userInitiated) { () -> FrameOutcome in
            do {
                let faces = try FaceDetector.detectFaces(in: image)
                guard let face = FaceRecognitionPipeline.largestFace(in: faces) else { return .noFace }
                if Float(face.normalizedBoundingBox.width) < minimumWidth { return .tooFar }
                return .ready(try pipeline.recognize(face, in: image))
            } catch {
                return .noFace
            }
        }.value
        guard stage == .capturing else { return }

        switch outcome {
        case .noFace:
            faceDetected = false
            isTooFar = false
            resetHold()
        case .tooFar:
            faceDetected = true
            isTooFar = true
            resetHold()
        case .ready(let result):
            faceDetected = true
            isTooFar = false
            guard let yaw = result.face.yaw, let pitch = result.face.pitch else {
                resetHold()
                return
            }
            currentYaw = yaw
            currentPitch = pitch
            updateHeadTurn(pose: pose)
            await processMatched(result, yaw: yaw, pitch: pitch, pose: pose)
        }
    }

    private func resetHold() {
        currentYaw = nil
        currentPitch = nil
        headTurn = nil
        matchStreak = 0
        poseHoldStartedAt = nil
    }

    private func updateHeadTurn(pose: EnrollmentPose) {
        guard pose != .center, let yaw = currentYaw, let pitch = currentPitch else {
            headTurn = nil
            return
        }
        // Screen-space direction of the turn, normalized so 1 = the band's inner edge.
        let x = Double(-yaw / (yawInnerThreshold / pose.matchLeniency))
        let y = Double(-pitch / (pitchInnerThreshold / pose.matchLeniency))
        let magnitude = (x * x + y * y).squareRoot()
        guard magnitude > headTurnDeadzone else {
            headTurn = nil
            return
        }
        var degrees = atan2(x, y) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        headTurn = HeadTurn(angle: degrees, progress: min(1, magnitude))
    }

    private func processMatched(_ result: FaceRecognitionResult, yaw: Float, pitch: Float, pose: EnrollmentPose) async {
        guard ContinuousClock.now >= captureReadyAt else {
            matchStreak = 0
            poseHoldStartedAt = nil
            return
        }

        let qualityOK = result.quality.map { $0 >= qualityFloor } ?? true
        // Only a 5-point alignment is reliably canonical.
        let alignmentOK = result.alignmentTier == .fivePoint
        let widened = ContinuousClock.now - poseStartedAt > stallTimeout
        let poseOK = poseMatches(yaw: yaw, pitch: pitch, pose: pose, widened: widened)
        guard qualityOK, alignmentOK, poseOK else {
            matchStreak = 0
            poseHoldStartedAt = nil
            return
        }

        if poseHoldStartedAt == nil {
            poseHoldStartedAt = .now
        }
        guard let holdStart = poseHoldStartedAt, ContinuousClock.now - holdStart >= poseHoldDuration else { return }

        matchStreak += 1
        guard matchStreak >= requiredMatchStreak else { return }
        matchStreak = 0

        samples.append(FaceSample(embedding: result.embedding, pose: pose.name, capturedAt: Date(), quality: result.quality))
        capturedForCurrentPose += 1

        if capturedForCurrentPose >= Self.samplesPerPose {
            if pose == .center {
                centerPulseTick += 1
            } else {
                capturedPoses.insert(pose)
            }
            currentPoseIndex += 1
            capturedForCurrentPose = 0
            poseStartedAt = .now
            poseHoldStartedAt = nil
            headTurn = nil
            if currentPoseIndex >= EnrollmentPose.allCases.count {
                finish()
            }
        }
    }

    private func poseMatches(yaw: Float, pitch: Float, pose: EnrollmentPose, widened: Bool) -> Bool {
        let factor = (widened ? stallWidenFactor : 1.0) * pose.matchLeniency
        return yawMatches(yaw, band: pose.yawBand, factor: factor)
            && pitchMatches(pitch, band: pose.pitchBand, factor: factor)
    }

    private func yawMatches(_ yaw: Float, band: EnrollmentPose.YawBand, factor: Float) -> Bool {
        switch band {
        case .none: abs(yaw) < yawCenterTolerance * factor
        case .left: yaw > yawInnerThreshold / factor && yaw < yawOuterCap
        case .right: yaw < -yawInnerThreshold / factor && yaw > -yawOuterCap
        }
    }

    /// Vision reports negative pitch for "looking up" and positive for "looking down".
    private func pitchMatches(_ pitch: Float, band: EnrollmentPose.PitchBand, factor: Float) -> Bool {
        switch band {
        case .none: abs(pitch) < pitchCenterTolerance * factor
        case .up: pitch < -pitchInnerThreshold / factor && pitch > -pitchOuterCap
        case .down: pitch > pitchInnerThreshold / factor && pitch < pitchOuterCap
        }
    }

    private func finish() {
        stage = .saving
        frameSubscription = nil
        do {
            try FaceEnrollmentStore.shared.commitEnrollment(
                name: NSFullUserName(),
                samples: samples,
                embedder: FaceRecognitionPipeline.shared.embedder
            )
            stage = .done
        } catch {
            stage = .failed(error.localizedDescription)
        }
        CameraManager.shared.release(lease)
        lease = nil
        FaceUnlockCoordinator.shared.refreshHelperStatus()
    }
}
