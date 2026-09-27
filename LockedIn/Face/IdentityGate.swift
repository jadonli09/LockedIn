//
//  IdentityGate.swift
//  LockedIn
//
//  Identity-gated exits: with "Require my face to end sessions early" on,
//  ending a running session or removing a blocked app/site mid-session
//  first has to see the enrolled face. Someone else at the keyboard can't
//  bail you out; you can't bail yourself out with a photo either (liveness
//  runs in Light mode here).
//
//  Fallback, by design: this is a focus tool, not a security product. If the
//  camera is unavailable or nothing is enrolled the gate is skipped; if the
//  face simply isn't recognized the panel offers a long 15-second override
//  hold, so a bad angle can never strand a session.
//

import Combine
import Defaults
import Foundation

enum IdentityGateResult: Equatable {
    case verified
    case notRecognized
    /// Gate skipped — no enrollment, camera denied, or the feature is off.
    case unavailable
}

enum IdentityGatePhase: Equatable {
    case idle
    case verifying
    case verified
    case failed
}

@MainActor
final class IdentityGate: ObservableObject {
    static let shared = IdentityGate()

    @Published private(set) var phase: IdentityGatePhase = .idle
    private var task: Task<IdentityGateResult, Never>?

    private init() {}

    /// Whether an exit currently needs a face check at all.
    var isRequired: Bool {
        Defaults[.requireFaceToEndSession]
            && FaceEnrollmentStore.shared.hasEnrollment
            && !FaceEnrollmentStore.shared.isStale
            && FocusSessionManager.shared.hasSession
    }

    /// Fire-and-forget form for list buttons: runs `action` immediately when no
    /// gate applies, otherwise after the face is verified. Removing a blocklist
    /// entry is a soft exit, so there is no override hold here — the 2-minute
    /// pass remains the sanctioned escape hatch.
    func performGated(_ action: @escaping @MainActor () -> Void) {
        guard isRequired else {
            action()
            return
        }
        Task { @MainActor in
            if await verify() != .notRecognized {
                action()
            }
        }
    }

    /// Runs one short scan (~4 s). Concurrent callers share the in-flight scan.
    /// `force` runs it even when no gate applies (Settings' "Try Face ID").
    func verify(force: Bool = false) async -> IdentityGateResult {
        let store = FaceEnrollmentStore.shared
        guard force ? (store.hasEnrollment && !store.isStale) : isRequired else { return .unavailable }
        if let task { return await task.value }

        phase = .verifying
        let job = Task { () -> IdentityGateResult in
            let outcome = await FaceScanner.scan(
                client: "Identity check",
                seconds: 4,
                livenessLevel: Defaults[.faceLivenessLevel] == .off ? .off : .light,
                threshold: FaceScanner.configuredThreshold
            )
            switch outcome {
            case .matched: return .verified
            case .wrongFace, .spoofSuspected, .noFace, .cancelled: return .notRecognized
            case .unavailable: return .unavailable
            }
        }
        task = job
        let result = await job.value
        task = nil

        switch result {
        case .verified: phase = .verified
        case .notRecognized: phase = .failed
        case .unavailable: phase = .idle
        }
        if phase != .idle {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.6))
                guard let self, self.task == nil else { return }
                self.phase = .idle
            }
        }
        return result
    }
}
