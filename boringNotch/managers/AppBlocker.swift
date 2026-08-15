//
//  AppBlocker.swift
//  boringNotch
//
//  App blocking during focus periods. Watches app activations and covers the
//  blocked app's own windows with a blurred overlay. "Stay locked in" quits
//  the app (gracefully first, force after a short grace); a watchdog
//  re-presents the overlay whenever a blocked app is frontmost without a
//  pass. The 2-minute pass grants exactly 120s, doesn't stack, isn't logged.
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
    private var tracker: Timer?
    private var cancellables: Set<AnyCancellable> = []
    /// The last non-blocked app, so closing a blocked app has somewhere to return.
    private var previousApp: NSRunningApplication?

    private init() {}

    func start() {
        // Seed the return target so the first block has somewhere to go back to.
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

        sessionStateChanged()

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
        } else {
            // Switched away from a blocked app: its windows are behind other
            // content now, so the overlay leaves with it.
            if overlay.isVisible {
                overlay.hide()
            }
            if !matcher.isBlocklisted(bundleID: app.bundleIdentifier) {
                previousApp = app
            }
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
        // Separate fast timer purely for window tracking, so dragging a
        // blocked window doesn't leave the blur behind.
        tracker = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in
            Task { @MainActor in
                AppBlocker.shared.trackWindows()
            }
        }
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
        tracker?.invalidate()
        tracker = nil
    }

    private func trackWindows() {
        guard overlay.isVisible,
              let frontmost = NSWorkspace.shared.frontmostApplication,
              shouldBlock(frontmost) else { return }
        let rects = Self.windowRects(for: frontmost)
        if rects.count == overlay.panelCount {
            overlay.reposition(to: rects)
        } else {
            presentOverlay(for: frontmost)
        }
    }

    /// Perpetual enforcement: whenever a blocked app is frontmost without a
    /// pass — including right after the pass expires — the overlay comes back,
    /// tracking the app's windows as they move. Pass-expiry relock arrives
    /// with the 3s fade warning. When the blocked app is no longer frontmost,
    /// the overlay leaves with it.
    private func watchdogCheck() {
        guard blockingActive else { return }
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return }

        if shouldBlock(frontmost) {
            if overlay.isVisible {
                overlay.reposition(to: Self.windowRects(for: frontmost))
            } else {
                let bundleID = frontmost.bundleIdentifier?.lowercased() ?? ""
                let expiredPass = recentlyPassed.remove(bundleID) != nil
                presentOverlay(for: frontmost, fadeIn: expiredPass ? 3 : 0)
            }
        } else if overlay.isVisible {
            overlay.hide()
        }
    }

    /// On-screen window bounds of the app, in Cocoa screen coordinates.
    /// CGWindowList exposes bounds + owner PID without any permissions.
    static func windowRects(for app: NSRunningApplication) -> [CGRect] {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return info.compactMap { entry in
            guard entry[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier,
                  (entry[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width > 120, bounds.height > 80
            else { return nil }
            // CG windows use a top-left origin; Cocoa panels use bottom-left.
            // Leave the title bar uncovered so the window can still be moved.
            let titleBarClearance: CGFloat = 30
            return CGRect(
                x: bounds.minX,
                y: primaryHeight - bounds.maxY,
                width: bounds.width,
                height: max(0, bounds.height - titleBarClearance)
            )
        }
    }

    /// Bundle ids whose pass ran out this session — used to pick the fade-in
    /// (warning) presentation over the instant one.
    private var recentlyPassed: Set<String> = []

    private func presentOverlay(for app: NSRunningApplication, fadeIn: TimeInterval = 0) {
        let name = app.localizedName ?? app.bundleIdentifier ?? "this app"
        overlay.show(
            covering: Self.windowRects(for: app),
            appName: name,
            fadeIn: fadeIn
        ) { [weak self] in
            self?.stayLockedIn(closing: app)
        } onPass: { [weak self] in
            self?.grantPass(to: app)
        }
    }

    /// "Stay locked in": hides the app instantly, asks it to quit gracefully,
    /// and force-quits if it's still alive after 2.5s (a graceful quit is an
    /// Apple event, which unauthorized apps silently swallow).
    private func stayLockedIn(closing app: NSRunningApplication) {
        overlay.hide()
        app.hide()
        if let previousApp, previousApp != app {
            previousApp.activate()
        }
        app.terminate()
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !app.isTerminated {
                app.forceTerminate()
            }
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
