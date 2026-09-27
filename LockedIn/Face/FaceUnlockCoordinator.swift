//
//  FaceUnlockCoordinator.swift
//  LockedIn
//
//  Lock-screen face unlock. On lock or wake (per Settings) the island — which
//  the AppDelegate has already lifted onto the lock screen via SkyLight —
//  shows a scan state; if the enrolled face matches and liveness passes, the
//  sandboxed app asks the unsandboxed helper to type the stored Mac password.
//  The password itself never enters this process.
//
//  Known limitation (inherited from Glance): liveness defeats a photo and a
//  phone held up, but not reliably a replayed video.
//

import AppKit
import Combine
import Defaults
import Foundation
import os

enum FaceUnlockPhase: Equatable {
    case idle
    case scanning
    case success
    case failure(String)

    var isPresenting: Bool { self != .idle }
}

@MainActor
final class FaceUnlockCoordinator: ObservableObject {
    static let shared = FaceUnlockCoordinator()

    @Published private(set) var phase: FaceUnlockPhase = .idle
    @Published private(set) var statusMessage = "Idle" {
        didSet { Self.log.info("\(self.statusMessage, privacy: .public)") }
    }
    private static let log = Logger(subsystem: "com.jadonli.lockedin", category: "FaceUnlock")
    /// Cached so the lock-screen gate doesn't hit the Keychain on every event.
    @Published private(set) var helperHasPassword = false
    @Published private(set) var isScreenLocked = false

    let lockMonitor = LockMonitor()
    private var cancellables: Set<AnyCancellable> = []
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = 0
    private var hasArmedForCurrentLock = false
    private var lastArmedAt: ContinuousClock.Instant?
    private let rearmDebounce: Duration = .seconds(2)

    private init() {
        lockMonitor.events
            .sink { [weak self] event in
                Task { @MainActor [weak self] in
                    if event == .screenLocked || event == .willSleep { self?.prewarm() }
                    // CGSession's reported state can lag the notification right after
                    // wake — poll briefly instead of always waiting out the worst case.
                    if event == .wake || event == .screenLocked {
                        for _ in 0..<10 where !LockMonitor.isScreenActuallyLocked() {
                            try? await Task.sleep(for: .milliseconds(30))
                        }
                    }
                    self?.handle(event)
                }
            }
            .store(in: &cancellables)
    }

    /// Called once at launch and whenever the password/enrollment changes.
    func start() {
        isScreenLocked = LockMonitor.isScreenActuallyLocked()
        refreshHelperStatus()
        prewarm()
        surfaceKeychainPrompt()
    }

    /// The legacy Keychain ties each item to the exact binary (cdhash) allowed to
    /// read it, so every dev rebuild re-asks "Always Allow". Read the password once
    /// at launch — while the user is at the desktop — so that prompt never first
    /// appears hidden behind the lock screen at unlock time. Off the main thread,
    /// and the bytes are zeroed immediately.
    private func surfaceKeychainPrompt() {
        guard Defaults[.faceUnlockEnabled], helperHasPassword else { return }
        Task.detached(priority: .utility) {
            guard var bytes = try? UnlockCredentialStore.read() else { return }
            bytes.resetBytes(in: 0..<bytes.count)
        }
    }

    /// Gets the slow cold starts out of the way before a face is in front of the
    /// camera: the helper process (an on-demand XPC launch can take seconds while
    /// locked) and the recognition models.
    func prewarm() {
        guard Defaults[.faceUnlockEnabled], FaceEnrollmentStore.shared.hasEnrollment else {
            Self.log.info("prewarm skipped (enabled: \(Defaults[.faceUnlockEnabled]), enrolled: \(FaceEnrollmentStore.shared.hasEnrollment))")
            return
        }
        Self.log.info("prewarm: helper + models")
        Task.detached(priority: .utility) {
            _ = await XPCHelperClient.shared.isAccessibilityAuthorized()
        }
        Task.detached(priority: .utility) {
            FaceRecognitionPipeline.shared.warmUp()
        }
    }

    func refreshHelperStatus() {
        helperHasPassword = UnlockCredentialStore.exists()
    }

    /// Whether the island needs to stay alive on the lock screen for this feature.
    var wantsLockScreenPresence: Bool {
        Defaults[.faceUnlockEnabled] && FaceEnrollmentStore.shared.hasEnrollment
    }

    // MARK: - Triggers

    private func handle(_ event: LockEventKind) {
        isScreenLocked = LockMonitor.isScreenActuallyLocked()
        guard isScreenLocked else {
            hasArmedForCurrentLock = false
            cancelScan()
            return
        }
        guard !lockMonitor.isSleeping else { return }

        // A wake is an explicit "let me back in", so it clears the one-shot guard —
        // unless it's one of several wake signals from the same lid-open.
        if event == .wake, !isWithinRecentArmBurst {
            hasArmedForCurrentLock = false
        }
        guard !hasArmedForCurrentLock else { return }

        let shouldScan: Bool
        switch event {
        case .wake: shouldScan = Defaults[.faceUnlockOnWake]
        case .screenLocked: shouldScan = Defaults[.faceUnlockOnLock]
        case .screenUnlocked, .willSleep: shouldScan = false
        }
        guard shouldScan, Defaults[.faceUnlockEnabled] else { return }
        guard FaceEnrollmentStore.shared.hasEnrollment else {
            statusMessage = "Face unlock is on, but no face is enrolled."
            return
        }
        guard helperHasPassword else {
            statusMessage = "Face unlock is on, but no Mac password is stored."
            refreshHelperStatus()
            return
        }

        hasArmedForCurrentLock = true
        lastArmedAt = .now
        startScan(allowRetry: true)
    }

    private var isWithinRecentArmBurst: Bool {
        guard let lastArmedAt else { return false }
        return ContinuousClock.now - lastArmedAt < rearmDebounce
    }

    /// Manual retry (Settings "Test now" while locked is impossible, so this is
    /// only reachable through a fresh trigger); kept for symmetry with the gate.
    func startScan(allowRetry: Bool) {
        scanTask?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration
        scanTask = Task { [weak self] in
            await self?.runScan(generation: generation, allowRetry: allowRetry)
        }
    }

    private func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        scanGeneration &+= 1
        if phase != .idle {
            phase = .idle
        }
    }

    private func runScan(generation: Int, allowRetry: Bool) async {
        guard LockMonitor.isScreenActuallyLocked() else { return }
        phase = .scanning
        statusMessage = "Looking for your face…"

        let outcome = await FaceScanner.scan(
            client: "Face unlock",
            seconds: TimeInterval(Defaults[.faceScanSeconds]),
            livenessLevel: Defaults[.faceLivenessLevel],
            threshold: FaceScanner.configuredThreshold,
            shouldContinue: { LockMonitor.isScreenActuallyLocked() }
        )
        guard generation == scanGeneration else { return }

        switch outcome {
        case .matched(let name, let similarity):
            statusMessage = "Recognized \(name) (\(String(format: "%.2f", similarity))) — unlocking…"
            let (ok, message) = await typeStoredPassword()
            guard generation == scanGeneration else { return }
            if ok {
                phase = .success
                statusMessage = "Unlocked \(name)."
                await hold(.milliseconds(1500), generation: generation)
            } else {
                phase = .failure(message ?? "Couldn't type the password.")
                statusMessage = message ?? "Couldn't type the password."
                await hold(.seconds(3), generation: generation)
            }
        case .wrongFace:
            phase = .failure("Not recognized")
            statusMessage = "Face not recognized."
            await hold(.seconds(3), generation: generation)
        case .spoofSuspected(let reason):
            phase = .failure("Not a live face")
            statusMessage = reason
            await hold(.seconds(3), generation: generation)
        case .noFace:
            statusMessage = "No face detected."
            if allowRetry, LockMonitor.isScreenActuallyLocked() {
                // One quiet retry: a lid-open often catches the user still settling in.
                try? await Task.sleep(for: .milliseconds(800))
                guard generation == scanGeneration else { return }
                await runScan(generation: generation, allowRetry: false)
                return
            }
            phase = .idle
        case .cancelled:
            phase = .idle
        case .unavailable(let reason):
            statusMessage = reason
            phase = .failure("Camera unavailable")
            await hold(.seconds(2), generation: generation)
        }
    }

    /// Reads the password only now, after a match, hands it to the helper to
    /// type, and zeroes the local copy.
    private func typeStoredPassword() async -> (Bool, String?) {
        var bytes: Data
        do {
            // Off the main actor: a Keychain prompt must never freeze the island.
            bytes = try await Task.detached(priority: .userInitiated) { try UnlockCredentialStore.read() }.value
        } catch {
            return (false, error.localizedDescription)
        }
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        return await XPCHelperClient.shared.typeUnlockPassword(bytes)
    }

    private func hold(_ duration: Duration, generation: Int) async {
        try? await Task.sleep(for: duration)
        guard generation == scanGeneration else { return }
        phase = .idle
    }
}
