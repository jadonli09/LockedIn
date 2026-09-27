//
//  FocusSessionManager.swift
//  LockedIn
//
//  Runtime driver for the focus state machine: owns the tick timer, the
//  3-second grace window between phases, persistence, and the end-of-phase
//  pulse + chime. The timer only refreshes the UI — truth lives in the
//  timestamps inside FocusSessionState.
//

import AppKit
import Combine
import Defaults
import SwiftUI

extension Notification.Name {
    static let focusPhaseDidChange = Notification.Name("FocusPhaseDidChange")
    static let focusSessionDidEnd = Notification.Name("FocusSessionDidEnd")
}

@MainActor
final class FocusSessionManager: ObservableObject {
    static let shared = FocusSessionManager()

    @Published private(set) var state: FocusSessionState?
    @Published private(set) var now: Date = .init()
    /// Increments once per phase end; views observe it to run the pulse animation.
    @Published private(set) var endPulse: Int = 0
    /// True during the 3s grace animation between phases.
    @Published private(set) var inGrace: Bool = false
    /// Set when the pause came from the idle or presence monitor, so input can auto-resume.
    private(set) var pausedAutomatically: Bool = false

    enum AutoPauseReason {
        case idle
        case presence
    }
    /// Which monitor paused the session, while `pausedAutomatically` is true.
    private(set) var autoPauseReason: AutoPauseReason?

    enum TransientEvent {
        case started, paused, resumed, reset, ended, away, back

        var label: String {
            switch self {
            case .started: "Focus"
            case .paused: "Paused"
            case .resumed: "Resumed"
            case .reset: "Reset"
            case .ended: "Ended"
            case .away: "Away"
            case .back: "Welcome back"
            }
        }

        var symbol: String {
            switch self {
            case .started, .resumed: "play.fill"
            case .paused: "pause.fill"
            case .reset: "arrow.counterclockwise"
            case .ended: "checkmark"
            case .away: "person.slash"
            case .back: "person.fill.checkmark"
            }
        }
    }

    /// Briefly non-nil after a state change so the collapsed island can pop a
    /// small confirmation chip — physical feedback for ⌥⌘L.
    @Published private(set) var transientEvent: TransientEvent?
    private var transientTask: Task<Void, Never>?

    /// Seconds the presence monitor saw the user away this session.
    var awayTotal: TimeInterval { state?.awayTotal ?? 0 }

    func announce(_ event: TransientEvent) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
            transientEvent = event
        }
        transientTask?.cancel()
        transientTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard let self, !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 1.0)) {
                self.transientEvent = nil
            }
        }
    }

    private var ticker: AnyCancellable?
    private var graceTask: Task<Void, Never>?

    var hasSession: Bool { state != nil }
    var isRunning: Bool { state != nil && state?.isPaused == false }
    var isPaused: Bool { state?.isPaused == true }
    var isFocusPhase: Bool { state?.phase == .focus }

    var remaining: TimeInterval { state?.remaining(at: now) ?? 0 }
    var progress: Double { state?.progress(at: now) ?? 0 }
    var phaseLabel: String { state?.phase.label ?? "" }

    var remainingMinutesText: String {
        let minutes = Int(ceil(remaining / 60))
        return "\(minutes)"
    }

    var remainingTimeText: String {
        let total = Int(remaining.rounded(.up))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private init() {
        restore()
    }

    // MARK: - Controls

    func start(preset: FocusPreset? = nil) {
        let chosen = preset ?? Defaults[.lastFocusPreset]
        Defaults[.lastFocusPreset] = chosen
        graceTask?.cancel()
        inGrace = false
        state = .startingFocus(preset: chosen, at: Date())
        persist()
        startTicker()
        announce(.started)
        NotificationCenter.default.post(name: .focusPhaseDidChange, object: nil)
    }

    func pause() {
        guard var s = state, !s.isPaused else { return }
        pausedAutomatically = false
        autoPauseReason = nil
        s.pause(at: Date())
        state = s
        persist()
        announce(.paused)
        NotificationCenter.default.post(name: .focusPhaseDidChange, object: nil)
    }

    /// Idle auto-pause. Backdates the pause by the idle interval so idle time
    /// never counts toward the session — 25 minutes means 25 attended minutes.
    func autoPause(idleFor idleSeconds: TimeInterval, reason: AutoPauseReason = .idle) {
        guard var s = state, !s.isPaused else { return }
        pausedAutomatically = true
        autoPauseReason = reason
        s.pause(at: Date().addingTimeInterval(-idleSeconds))
        state = s
        persist()
        NotificationCenter.default.post(name: .focusPhaseDidChange, object: nil)
    }

    func resume() {
        guard var s = state, s.isPaused else { return }
        pausedAutomatically = false
        autoPauseReason = nil
        s.resume(at: Date())
        state = s
        persist()
        announce(.resumed)
        NotificationCenter.default.post(name: .focusPhaseDidChange, object: nil)
    }

    /// Restart the current phase from its full duration, running immediately.
    /// Deliberately low-friction: a reset only ever adds focus time.
    func resetPhase() {
        guard var s = state else { return }
        graceTask?.cancel()
        inGrace = false
        pausedAutomatically = false
        autoPauseReason = nil
        s.phaseStart = Date()
        s.pausedAt = nil
        state = s
        persist()
        startTicker()
        announce(.reset)
        NotificationCenter.default.post(name: .focusPhaseDidChange, object: nil)
    }

    /// Skip the current break straight into the next focus phase.
    func skipBreak() {
        guard let s = state, s.phase.isBreak else { return }
        graceTask?.cancel()
        inGrace = false
        pausedAutomatically = false
        state = s.advanced(at: Date(), longBreaksEnabled: Defaults[.longBreaksEnabled])
        persist()
        startTicker()
        announce(.started)
        NotificationCenter.default.post(name: .focusPhaseDidChange, object: nil)
    }

    /// Start / pause / resume from a single control (play-pause button, ⌥⌘L).
    func toggle() {
        if state == nil {
            start()
        } else if isPaused {
            resume()
        } else {
            pause()
        }
    }

    /// Pulse the island without a chime — physical feedback for the global hotkey.
    func visualPulse() {
        endPulse += 1
    }

    /// Presence monitor bookkeeping: adds one absence to the session's away total.
    func recordAway(seconds: TimeInterval) {
        guard var s = state, seconds > 0 else { return }
        s.awayTotal += seconds
        state = s
        persist()
    }

    func endSession() {
        graceTask?.cancel()
        inGrace = false
        state = nil
        persist()
        stopTicker()
        announce(.ended)
        NotificationCenter.default.post(name: .focusSessionDidEnd, object: nil)
    }

    // MARK: - Tick + phase completion

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tick()
            }
        tick()
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private func tick() {
        now = Date()
        guard let s = state, !s.isPaused, !inGrace else { return }
        if s.isExpired(at: now) {
            completePhase()
        }
    }

    private func completePhase() {
        guard let s = state else { return }
        endPulse += 1
        playChime()

        // 3s grace animation, then auto-advance to the next phase.
        inGrace = true
        graceTask?.cancel()
        graceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            self.inGrace = false
            withAnimation(.smooth) {
                self.state = s.advanced(at: Date(), longBreaksEnabled: Defaults[.longBreaksEnabled])
            }
            self.persist()
            NotificationCenter.default.post(name: .focusPhaseDidChange, object: nil)
        }
    }

    private func playChime() {
        if let url = Bundle.main.url(forResource: "chime", withExtension: "wav") {
            NSSound(contentsOf: url, byReference: true)?.play()
        }
    }

    // MARK: - Persistence

    private func persist() {
        Defaults[.focusSessionState] = state
    }

    private func restore() {
        guard let s = Defaults[.focusSessionState] else { return }
        let now = Date()
        if s.isPaused {
            state = s
            startTicker()
        } else if s.isExpired(at: now) {
            // The phase ran out while the app wasn't running; end quietly
            // rather than firing stale pulses or guessing how many phases passed.
            Defaults[.focusSessionState] = nil
        } else {
            state = s
            startTicker()
        }
    }
}
