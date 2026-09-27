//
//  FocusModels.swift
//  LockedIn
//
//  Pure model layer for LockedIn focus sessions. All timing is wall-clock
//  timestamp arithmetic — never accumulated timer ticks — so state survives
//  app relaunch and system sleep. Every function takes `now` explicitly,
//  which keeps the state machine fully unit-testable.
//

import Foundation

struct FocusPreset: Codable, Hashable, Identifiable {
    var focusMinutes: Int
    var breakMinutes: Int

    var id: String { "\(focusMinutes)/\(breakMinutes)" }

    var focusDuration: TimeInterval { TimeInterval(focusMinutes * 60) }
    var breakDuration: TimeInterval { TimeInterval(breakMinutes * 60) }
    // Long break every 4th cycle; 3× the short break is the classic ratio (25/5 → 15).
    var longBreakDuration: TimeInterval { TimeInterval(breakMinutes * 3 * 60) }

    static let classic = FocusPreset(focusMinutes: 25, breakMinutes: 5)
    static let deep = FocusPreset(focusMinutes: 50, breakMinutes: 10)
    static let marathon = FocusPreset(focusMinutes: 90, breakMinutes: 15)
    static let islandPresets: [FocusPreset] = [.classic, .deep, .marathon]
}

enum FocusPhaseKind: String, Codable {
    case focus
    case shortBreak
    case longBreak

    var isBreak: Bool { self != .focus }

    var label: String {
        switch self {
        case .focus: "Focus"
        case .shortBreak, .longBreak: "Break"
        }
    }
}

/// One in-flight session phase. `phaseStart` is shifted forward on resume so
/// that (now - phaseStart) is always *attended* elapsed time: paused and idle
/// time never count toward the session.
struct FocusSessionState: Codable {
    var preset: FocusPreset
    var phase: FocusPhaseKind
    var phaseStart: Date
    var phaseDuration: TimeInterval
    var pausedAt: Date?
    /// Completed focus phases in this session, drives the every-4th long break.
    var completedFocusCount: Int = 0
    /// Seconds the presence monitor saw the user away from the desk this session.
    /// Informational only — away time is already excluded by the backdated pause.
    var awayTotal: TimeInterval = 0

    var isPaused: Bool { pausedAt != nil }

    init(preset: FocusPreset, phase: FocusPhaseKind, phaseStart: Date, phaseDuration: TimeInterval,
         pausedAt: Date?, completedFocusCount: Int = 0, awayTotal: TimeInterval = 0) {
        self.preset = preset
        self.phase = phase
        self.phaseStart = phaseStart
        self.phaseDuration = phaseDuration
        self.pausedAt = pausedAt
        self.completedFocusCount = completedFocusCount
        self.awayTotal = awayTotal
    }

    /// Hand-written so sessions persisted before `awayTotal` existed still decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preset = try c.decode(FocusPreset.self, forKey: .preset)
        phase = try c.decode(FocusPhaseKind.self, forKey: .phase)
        phaseStart = try c.decode(Date.self, forKey: .phaseStart)
        phaseDuration = try c.decode(TimeInterval.self, forKey: .phaseDuration)
        pausedAt = try c.decodeIfPresent(Date.self, forKey: .pausedAt)
        completedFocusCount = try c.decodeIfPresent(Int.self, forKey: .completedFocusCount) ?? 0
        awayTotal = try c.decodeIfPresent(TimeInterval.self, forKey: .awayTotal) ?? 0
    }

    // MARK: - Timestamp arithmetic

    func elapsed(at now: Date) -> TimeInterval {
        let reference = pausedAt ?? now
        return max(0, reference.timeIntervalSince(phaseStart))
    }

    func remaining(at now: Date) -> TimeInterval {
        max(0, phaseDuration - elapsed(at: now))
    }

    func progress(at now: Date) -> Double {
        guard phaseDuration > 0 else { return 1 }
        return min(1, elapsed(at: now) / phaseDuration)
    }

    func isExpired(at now: Date) -> Bool {
        remaining(at: now) <= 0
    }

    // MARK: - Transitions

    mutating func pause(at now: Date) {
        guard pausedAt == nil else { return }
        pausedAt = now
    }

    mutating func resume(at now: Date) {
        guard let pausedAt else { return }
        // Shift the start forward by the paused interval so it doesn't count.
        phaseStart = phaseStart.addingTimeInterval(now.timeIntervalSince(pausedAt))
        self.pausedAt = nil
    }

    /// The state for the phase that follows this one, per the cycle
    /// focus → break → focus, with a long break after every 4th focus.
    func advanced(at now: Date, longBreaksEnabled: Bool) -> FocusSessionState {
        var next = self
        next.phaseStart = now
        next.pausedAt = nil

        switch phase {
        case .focus:
            next.completedFocusCount = completedFocusCount + 1
            if longBreaksEnabled && next.completedFocusCount.isMultiple(of: 4) {
                next.phase = .longBreak
                next.phaseDuration = preset.longBreakDuration
            } else {
                next.phase = .shortBreak
                next.phaseDuration = preset.breakDuration
            }
        case .shortBreak, .longBreak:
            next.phase = .focus
            next.phaseDuration = preset.focusDuration
        }
        return next
    }

    static func startingFocus(preset: FocusPreset, at now: Date) -> FocusSessionState {
        FocusSessionState(
            preset: preset,
            phase: .focus,
            phaseStart: now,
            phaseDuration: preset.focusDuration,
            pausedAt: nil,
            completedFocusCount: 0
        )
    }
}
