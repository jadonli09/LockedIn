//
//  AppBlocker.swift
//  boringNotch
//
//  App blocking during focus periods. Watches app activations and drops the
//  block overlay over blocklisted apps. Never force-quits anything — blocked
//  apps are hidden, not killed, and a watchdog re-presents the overlay if a
//  blocked app is ever frontmost without a pass. The 2-minute pass grants
//  exactly 120s to one app, doesn't stack, and isn't logged anywhere.
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
    private var watchdog: Timer?
    private var cancellables: Set<AnyCancellable> = []
    /// The last non-blocked app, so "Back to work" has somewhere to return.
    private var previousApp: NSRunningApplication?

    private init() {}

    func start() {
        // Seed the return target so "Back to work" works for the first block.
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           !matcher.isBlocklisted(bundleID: frontmost.bundleIdentifier) {
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

    private var blockingActive: Bool {
        let focus = FocusSessionManager.shared
        return focus.isRunning && focus.isFocusPhase
    }

    private func shouldBlock(_ app: NSRunningApplication) -> Bool {
        guard blockingActive, let bundleID = app.bundleIdentifier else { return false }
        guard matcher.isBlocklisted(bundleID: bundleID) else { return false }
        return PassCenter.shared.expiry(for: .app(bundleID: bundleID)) == nil
    }

    private func handleActivation(_ app: NSRunningApplication?) {
        guard let app else { return }
        if shouldBlock(app) {
            presentOverlay(for: app)
        } else if !matcher.isBlocklisted(bundleID: app.bundleIdentifier), !overlay.isVisible {
            previousApp = app
        }
    }

    private func sessionStateChanged() {
        if blockingActive {
            // Catch a blocked app that was already frontmost when the session
            // began, and keep a watchdog so blocked apps stay blocked even if
            // the overlay was dismissed without switching away.
            handleActivation(NSWorkspace.shared.frontmostApplication)
            startWatchdog()
        } else {
            overlay.hide()
            stopWatchdog()
        }
        if !FocusSessionManager.shared.hasSession {
            PassCenter.shared.clearAll()
        }
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task { @MainActor in
                AppBlocker.shared.watchdogCheck()
            }
        }
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    /// Perpetual enforcement: whenever a blocked app is frontmost without a
    /// pass — including right after the pass expires or after the overlay was
    /// dismissed in place — the overlay comes back. Pass-expiry relock arrives
    /// with the 3s fade warning.
    private func watchdogCheck() {
        guard blockingActive, !overlay.isVisible,
              let frontmost = NSWorkspace.shared.frontmostApplication,
              shouldBlock(frontmost) else { return }
        let bundleID = frontmost.bundleIdentifier?.lowercased() ?? ""
        let expiredPass = recentlyPassed.remove(bundleID) != nil
        presentOverlay(for: frontmost, fadeIn: expiredPass ? 3 : 0)
    }

    /// Bundle ids whose pass ran out this session — used to pick the fade-in
    /// (warning) presentation over the instant one.
    private var recentlyPassed: Set<String> = []

    private func presentOverlay(for app: NSRunningApplication, fadeIn: TimeInterval = 0) {
        let name = app.localizedName ?? app.bundleIdentifier ?? "this app"
        overlay.show(appName: name, fadeIn: fadeIn) { [weak self] in
            self?.backToWork(hiding: app)
        } onPass: { [weak self] in
            self?.grantPass(to: app)
        }
    }

    /// Hide the blocked app (never quit it) so it can't be used behind the
    /// dismissed overlay; reactivating it later re-triggers the block.
    private func backToWork(hiding app: NSRunningApplication) {
        overlay.hide()
        app.hide()
        if let previousApp, previousApp != app {
            previousApp.activate()
        }
    }

    private func grantPass(to app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier else { return }
        PassCenter.shared.grant(
            kind: .app(bundleID: bundleID),
            name: app.localizedName ?? bundleID
        )
        recentlyPassed.insert(bundleID.lowercased())
        overlay.hide()
        // The watchdog picks up expiry and relocks with the 3s fade.
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
