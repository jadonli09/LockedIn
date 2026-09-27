//
//  LockMonitor.swift
//  LockedIn
//
//  Lock / unlock / sleep / wake signals for the face-unlock coordinator.
//  The notifications are trigger signals only — `isScreenActuallyLocked()`
//  (CGSession) is the authoritative gate, re-checked before every scan.
//
//  Ported from Glance (github.com/jonnyoo/glance, MIT).
//

import AppKit
import Combine
import CoreGraphics
import Foundation

enum LockEventKind: Equatable {
    case screenLocked
    case screenUnlocked
    case willSleep
    /// Display turned back on: system wake, display wake, or the screensaver stopping.
    case wake
}

@MainActor
final class LockMonitor: ObservableObject {
    /// Fires on every event (repeats included) with the kind that just happened.
    let events = PassthroughSubject<LockEventKind, Never>()
    @Published private(set) var isScreenLocked = false
    /// True from `willSleep` until the next wake. `screenIsLocked` fires ~150 ms
    /// before the system finishes suspending, so a lock while this is true is
    /// skipped and the wake trigger handles it instead.
    @Published private(set) var isSleeping = false

    private var distributedObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        let distributed = DistributedNotificationCenter.default()
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isScreenLocked = true
                self?.events.send(.screenLocked)
            }
        })
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isScreenLocked = false
                self?.events.send(.screenUnlocked)
            }
        })
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screensaver.didstop"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.events.send(.wake) }
        })

        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isSleeping = true
                self?.events.send(.willSleep)
            }
        })
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.isSleeping = false
                    self?.events.send(.wake)
                }
            })
        }
    }

    deinit {
        let distributed = DistributedNotificationCenter.default()
        for observer in distributedObservers { distributed.removeObserver(observer) }
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { workspace.removeObserver(observer) }
    }

    /// Authoritative lock state from the CoreGraphics session server. Fails closed.
    nonisolated static func isScreenActuallyLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}
