//
//  FocusBehaviors.swift
//  boringNotch
//
//  The invisible session behaviors: keep-awake, idle auto-pause, Auto-DND.
//  Zero UI footprint — they react to FocusSessionManager notifications and
//  never add a pixel to the island.
//

import AppKit
import Combine
import Defaults
import IOKit.pwr_mgt

extension Defaults.Keys {
    static let idleAutoPauseEnabled = Key<Bool>("idleAutoPauseEnabled", default: true)
    static let autoDNDEnabled = Key<Bool>("autoDNDEnabled", default: true)
}

/// Wires the three behaviors to session state changes. Owned by the AppDelegate.
@MainActor
final class FocusBehaviorCoordinator {
    static let shared = FocusBehaviorCoordinator()

    private let keepAwake = KeepAwakeManager()
    private let idleMonitor = IdleAutoPauseMonitor()
    private var observers: [Any] = []

    private init() {}

    func start() {
        observers.append(NotificationCenter.default.addObserver(
            forName: .focusPhaseDidChange, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in self.sessionStateChanged() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .focusSessionDidEnd, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in self.sessionStateChanged() }
        })
        sessionStateChanged()
    }

    private func sessionStateChanged() {
        let focus = FocusSessionManager.shared
        let focusPhaseRunning = focus.isRunning && focus.isFocusPhase

        // Keep-awake holds only during running focus periods, never breaks.
        keepAwake.setActive(focusPhaseRunning)
        idleMonitor.setWatching(focusPhaseRunning || focus.pausedAutomatically)
        FocusModeController.setFocusMode(enabled: focusPhaseRunning)
    }
}

/// Display-sleep assertion for focus periods. Never leaks: released on every
/// deactivation path, and the OS reclaims it if the process dies.
final class KeepAwakeManager {
    private var assertionID: IOPMAssertionID = 0
    private var held = false

    func setActive(_ active: Bool) {
        if active && !held {
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypeNoDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "LockedIn focus session" as CFString,
                &assertionID
            )
            held = (result == kIOReturnSuccess)
        } else if !active && held {
            IOPMAssertionRelease(assertionID)
            held = false
        }
    }

    deinit {
        if held { IOPMAssertionRelease(assertionID) }
    }
}

/// Polls system input idle time every 30s during focus periods. Five idle
/// minutes pause the session (backdated, so idle time never counts); the next
/// input event resumes it automatically.
@MainActor
final class IdleAutoPauseMonitor {
    static let idleThreshold: TimeInterval = 5 * 60
    private var poller: AnyCancellable?
    private var cadence: TimeInterval = 0

    /// Seconds since the last keyboard/mouse/scroll input. Queried per event
    /// type and combined, which avoids the undocumented any-event sentinel.
    static func secondsSinceLastInput() -> TimeInterval {
        let types: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel, .leftMouseDragged]
        return types
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
    }

    /// (Re)arms the poll timer: 30s while attending a focus period, 2s while
    /// auto-paused so the next input resumes promptly.
    func setWatching(_ watching: Bool) {
        guard watching else {
            poller = nil
            cadence = 0
            return
        }
        let desired: TimeInterval = FocusSessionManager.shared.pausedAutomatically ? 2 : 30
        guard poller == nil || cadence != desired else { return }
        cadence = desired
        poller = Timer.publish(every: desired, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.check()
            }
    }

    private func check() {
        guard Defaults[.idleAutoPauseEnabled] else { return }
        let focus = FocusSessionManager.shared
        let idle = Self.secondsSinceLastInput()

        if focus.isRunning && focus.isFocusPhase && idle >= Self.idleThreshold {
            focus.autoPause(idleFor: idle)
        } else if focus.pausedAutomatically && idle < 2 {
            focus.resume()
        }
        // Cadence is re-evaluated by the coordinator on each state change.
    }
}

/// Auto-DND through the `shortcuts` CLI — there is no public Focus-mode API.
/// If the bundled Shortcuts aren't installed, this silently no-ops: never
/// error, never nag.
@MainActor
enum FocusModeController {
    private static var lastRequested: Bool?

    static func setFocusMode(enabled: Bool) {
        guard Defaults[.autoDNDEnabled] else { return }
        guard lastRequested != enabled else { return }
        lastRequested = enabled

        let name = enabled ? "LockedIn Focus On" : "LockedIn Focus Off"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            // shortcuts CLI missing — the graceful no-op path.
        }
    }
}
