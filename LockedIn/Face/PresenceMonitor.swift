//
//  PresenceMonitor.swift
//  LockedIn
//
//  "Is the enrolled user at the desk?" during focus phases. Leases the camera
//  at ~2 fps (the sensor itself is throttled, not just the frames) and checks
//  one frame every few seconds: a cheap face-rectangle pass first, the full
//  recognition only when a face is actually there. Past the away threshold
//  the session auto-pauses — backdated, like idle auto-pause, so away time
//  never counts — and focus sounds fade out; the enrolled face coming back
//  resumes both with a "Welcome back" chip.
//
//  Camera use is opt-in (Settings) and the island shows a green dot whenever
//  the camera is on.
//

import Combine
import CoreGraphics
import Defaults
import Foundation

@MainActor
final class PresenceMonitor: ObservableObject {
    static let shared = PresenceMonitor()

    @Published private(set) var state: PresenceState = .present
    @Published private(set) var isWatching = false
    /// Last observation, for the Settings status row.
    @Published private(set) var lastObservation: PresenceObservation?

    var isAway: Bool { state.isAway }

    /// Seconds between camera checks. Frames still arrive at ~2 fps, but each
    /// check runs Vision once, so this bounds CPU use.
    static let checkInterval: TimeInterval = 3
    /// Presence is a convenience, not a security gate — a little more lenient
    /// than unlock so a glance down at the keyboard doesn't read as a stranger.
    static let thresholdSlack: Float = 0.08

    private var machine = PresenceStateMachine(awayThreshold: 60)
    private var lease: UUID?
    private var loop: Task<Void, Never>?
    private var observers: [Any] = []
    private var cancellables: Set<AnyCancellable> = []
    /// Set while the session is paused by *this* monitor, for the away accounting.
    private var pausedAwaySince: Date?

    private init() {}

    func start() {
        for name in [Notification.Name.focusPhaseDidChange, .focusSessionDidEnd] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in PresenceMonitor.shared.sessionStateChanged() }
            })
        }
        Defaults.publisher(.presenceDetectionEnabled)
            .sink { _ in
                Task { @MainActor in PresenceMonitor.shared.sessionStateChanged() }
            }
            .store(in: &cancellables)
        sessionStateChanged()
    }

    private var shouldWatch: Bool {
        guard Defaults[.presenceDetectionEnabled], FaceEnrollmentStore.shared.hasEnrollment,
              !FaceEnrollmentStore.shared.isStale else { return false }
        let focus = FocusSessionManager.shared
        // Watch during running focus phases, and keep watching while *we* paused
        // the session so the user's return can resume it.
        let running = focus.isRunning && focus.isFocusPhase
        let awayPaused = focus.pausedAutomatically && focus.autoPauseReason == .presence
        return running || awayPaused
    }

    private func sessionStateChanged() {
        let focus = FocusSessionManager.shared

        // Any resume (input, ⌥⌘L, our own) while we hold an absence closes the books on it.
        if let since = pausedAwaySince, focus.isRunning {
            focus.recordAway(seconds: Date().timeIntervalSince(since))
            pausedAwaySince = nil
            machine.reset()
            state = .present
            FocusSoundManager.shared.resumeFromAbsence()
            focus.announce(.back)
        }
        if !focus.hasSession || (focus.isPaused && focus.autoPauseReason != .presence) {
            pausedAwaySince = nil
            machine.reset()
            state = .present
        }

        if shouldWatch {
            startWatching()
        } else {
            stopWatching()
        }
    }

    private func startWatching() {
        guard loop == nil else { return }
        machine.awayThreshold = TimeInterval(Defaults[.presenceAwayThresholdSeconds])
        isWatching = true
        loop = Task { [weak self] in
            guard let self else { return }
            self.lease = await CameraManager.shared.acquire(client: "Presence", maxFPS: 2)
            guard self.lease != nil else {
                self.isWatching = false
                self.loop = nil
                return
            }
            var lastFrameID: UInt64?
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.checkInterval))
                guard !Task.isCancelled else { break }
                guard let frame = CameraManager.shared.currentFrame, frame.id != lastFrameID else { continue }
                lastFrameID = frame.id
                let observation = await Self.observe(frame)
                guard !Task.isCancelled else { break }
                self.apply(observation, at: Date())
            }
        }
    }

    private func stopWatching() {
        loop?.cancel()
        loop = nil
        CameraManager.shared.release(lease)
        lease = nil
        isWatching = false
    }

    /// Cheap rectangle pass first; the embedding only runs when someone is in frame.
    private static func observe(_ frame: CameraFrame) async -> PresenceObservation {
        let identities = FaceEnrollmentStore.shared.identities
        let threshold = max(0.45, FaceScanner.configuredThreshold - thresholdSlack)
        let pipeline = FaceRecognitionPipeline.shared
        return await Task.detached(priority: .utility) { () -> PresenceObservation in
            guard let rects = try? FaceDetector.detectFaceRectangles(in: frame.image),
                  rects.contains(where: { $0.width >= CGFloat(FaceRecognitionPipeline.minimumProminentFaceWidth) })
            else { return .noFace }
            guard let result = try? pipeline.recognize(in: frame.image) else { return .noFace }
            let scored = pipeline.score(result.embedding, against: identities)
            return pipeline.bestMatch(in: scored, threshold: threshold) != nil ? .enrolledFace : .otherFace
        }.value
    }

    private func apply(_ observation: PresenceObservation, at now: Date) {
        lastObservation = observation
        let event = machine.observe(observation, at: now)
        state = machine.state

        switch event {
        case .becameAway(let awaySince):
            let focus = FocusSessionManager.shared
            guard focus.isRunning, focus.isFocusPhase else { return }
            pausedAwaySince = awaySince
            focus.autoPause(idleFor: now.timeIntervalSince(awaySince), reason: .presence)
            FocusSoundManager.shared.suspendForAbsence()
            focus.announce(.away)
        case .returned:
            let focus = FocusSessionManager.shared
            if focus.pausedAutomatically, focus.autoPauseReason == .presence {
                focus.resume() // sessionStateChanged() then records the absence and greets.
            }
        case nil:
            break
        }
    }
}
