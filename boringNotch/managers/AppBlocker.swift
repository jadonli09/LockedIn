//
//  AppBlocker.swift
//  boringNotch
//
//  App blocking during focus periods. Watches app activations and drops the
//  block overlay over blocklisted apps. Never force-quits anything — the
//  overlay plus the return button is the whole mechanism. The 2-minute pass
//  grants exactly 120s to one app, doesn't stack, and isn't logged anywhere.
//

import AppKit
import Combine
import Defaults
import SwiftUI

extension Defaults.Keys {
    static let blockedBundleIDs = Key<[String]>("blockedBundleIDs", default: [])
    static let blockedDomains = Key<[String]>("blockedDomains", default: [])
}

@MainActor
final class AppBlocker {
    static let shared = AppBlocker()

    private var matcher = BlocklistMatcher(blockedBundleIDs: Defaults[.blockedBundleIDs])
    private let overlay = BlockOverlayController()
    private var workspaceObserver: Any?
    private var sessionObservers: [Any] = []
    private var relockTask: Task<Void, Never>?
    /// The last non-blocked app, so "Back to work" has somewhere to return.
    private var previousApp: NSRunningApplication?

    private init() {}

    func start() {
        // Seed the return target so "Back to work" works for the first block.
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           !matcher.isBlocked(bundleID: frontmost.bundleIdentifier, at: Date()) {
            previousApp = frontmost
        }

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in
                AppBlocker.shared.handleActivation(app)
            }
        }

        for name in [Notification.Name.focusPhaseDidChange, .focusSessionDidEnd] {
            sessionObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { _ in
                Task { @MainActor in
                    AppBlocker.shared.sessionStateChanged()
                }
            })
        }

        Defaults.publisher(.blockedBundleIDs)
            .sink { change in
                Task { @MainActor in
                    AppBlocker.shared.matcher.blockedBundleIDs = Set(change.newValue.map { $0.lowercased() })
                }
            }
            .store(in: &cancellables)

        #if DEBUG
        simulateBlockIfRequested()
        #endif
    }

    private var cancellables: Set<AnyCancellable> = []

    private var blockingActive: Bool {
        let focus = FocusSessionManager.shared
        return focus.isRunning && focus.isFocusPhase
    }

    private func handleActivation(_ app: NSRunningApplication?) {
        guard let app else { return }
        guard blockingActive else {
            previousApp = app
            return
        }

        let now = Date()
        if matcher.isBlocked(bundleID: app.bundleIdentifier, at: now) {
            presentOverlay(for: app)
        } else {
            if matcher.hasActivePass(bundleID: app.bundleIdentifier, at: now) {
                scheduleRelock(for: app)
            }
            if !overlay.isVisible {
                previousApp = app
            }
        }
    }

    private func sessionStateChanged() {
        if blockingActive {
            // Catch a blocked app that was already frontmost when the session began.
            handleActivation(NSWorkspace.shared.frontmostApplication)
        } else {
            overlay.hide()
            relockTask?.cancel()
        }
        if !FocusSessionManager.shared.hasSession {
            matcher.clearPasses()
        }
    }

    private func presentOverlay(for app: NSRunningApplication, fadeIn: TimeInterval = 0) {
        let name = app.localizedName ?? app.bundleIdentifier ?? "this app"
        overlay.show(appName: name, fadeIn: fadeIn) { [weak self] in
            self?.backToWork()
        } onPass: { [weak self] in
            self?.grantPass(to: app)
        }
    }

    private func backToWork() {
        overlay.hide()
        relockTask?.cancel()
        previousApp?.activate()
    }

    private func grantPass(to app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier else { return }
        _ = matcher.grantPass(bundleID: bundleID, at: Date())
        overlay.hide()
        scheduleRelock(for: app)
    }

    /// When the pass runs out and the app is still frontmost, the overlay
    /// fades back in over 3 seconds — the fade is the warning.
    private func scheduleRelock(for app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier,
              let expiry = matcher.passes[bundleID.lowercased()] else { return }
        relockTask?.cancel()
        relockTask = Task { [weak self] in
            let delay = max(0, expiry.timeIntervalSinceNow - 3)
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            guard self.blockingActive,
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID else { return }
            self.presentOverlay(for: app, fadeIn: 3)
        }
    }

    #if DEBUG
    /// `defaults write <bundle-id> DEBUG_SIMULATE_BLOCK -bool true` fakes a
    /// blocked-app activation 2s after launch so the overlay is
    /// screenshot-verifiable without granting anything.
    private func simulateBlockIfRequested() {
        guard UserDefaults.standard.bool(forKey: "DEBUG_SIMULATE_BLOCK") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if !FocusSessionManager.shared.hasSession {
                FocusSessionManager.shared.start()
            }
            if let current = NSWorkspace.shared.frontmostApplication {
                self.presentOverlay(for: current)
            }
        }
    }
    #endif
}
