//
//  PresenceStateMachine.swift
//  LockedIn
//
//  Pure timing logic for "is the enrolled user at the desk". Every transition
//  takes `now` explicitly, like FocusSessionState, so it is fully testable
//  without a camera. The monitor feeds it one observation per camera check.
//

import Foundation

enum PresenceObservation: Equatable {
    /// The enrolled face was recognized.
    case enrolledFace
    /// A face was seen but it didn't match the enrollment (or scored too low).
    case otherFace
    /// Nobody in frame.
    case noFace
}

enum PresenceState: Equatable {
    case present
    /// Haven't seen the enrolled face since `since`; the session keeps running
    /// until the away threshold passes.
    case unsure(since: Date)
    /// Away past the threshold — the session should be paused (backdated to `since`).
    case away(since: Date)

    var isAway: Bool {
        if case .away = self { return true }
        return false
    }
}

enum PresenceEvent: Equatable {
    /// Crossed the away threshold. `awaySince` is when the enrolled face was last seen,
    /// so callers can backdate the pause and exclude the whole absence.
    case becameAway(awaySince: Date)
    /// Enrolled face is back after a real absence; `awayDuration` is the total time away.
    case returned(awayDuration: TimeInterval)
}

struct PresenceStateMachine: Equatable {
    var state: PresenceState = .present
    /// Seconds without the enrolled face before the session pauses.
    var awayThreshold: TimeInterval
    /// Consecutive enrolled-face sightings needed to come back from `.away`;
    /// one lucky frame on a stranger's face shouldn't resume a session.
    var returnStreakRequired: Int = 2

    private var returnStreak = 0

    init(awayThreshold: TimeInterval, returnStreakRequired: Int = 2) {
        self.awayThreshold = awayThreshold
        self.returnStreakRequired = returnStreakRequired
    }

    /// Feed one observation; returns an event when the presence state crosses
    /// a boundary the session manager cares about.
    mutating func observe(_ observation: PresenceObservation, at now: Date) -> PresenceEvent? {
        switch (state, observation) {
        case (.present, .enrolledFace):
            return nil

        case (.present, .otherFace), (.present, .noFace):
            state = .unsure(since: now)
            return nil

        case (.unsure, .enrolledFace):
            state = .present
            return nil

        case (.unsure(let since), .otherFace), (.unsure(let since), .noFace):
            if now.timeIntervalSince(since) >= awayThreshold {
                state = .away(since: since)
                returnStreak = 0
                return .becameAway(awaySince: since)
            }
            return nil

        case (.away(let since), .enrolledFace):
            returnStreak += 1
            guard returnStreak >= returnStreakRequired else { return nil }
            state = .present
            returnStreak = 0
            return .returned(awayDuration: now.timeIntervalSince(since))

        case (.away, .otherFace), (.away, .noFace):
            returnStreak = 0
            return nil
        }
    }

    /// Forget everything — used when the session ends or the monitor stops.
    mutating func reset() {
        state = .present
        returnStreak = 0
    }
}
