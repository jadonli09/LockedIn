//
//  BrowserBlocker.swift
//  boringNotch
//
//  Website blocking v1: poll the frontmost browser's active tab every 2s
//  during focus periods via AppleScript. On a domain match, redirect the tab
//  to the bundled block page. No /etc/hosts, no helper, no proxy — per spec.
//  Requires per-browser Automation permission; silently inert without it.
//

import AppKit
import Defaults
import SwiftUI

@MainActor
final class BrowserBlocker {
    static let shared = BrowserBlocker()

    private enum Engine {
        case safari
        case chromium
    }

    // Every Chromium fork here ships the same scripting dictionary
    // (window → active tab → URL), verified via `sdef` where installed.
    private static let browsers: [String: Engine] = [
        "com.apple.safari": .safari,
        "com.google.chrome": .chromium,
        "company.thebrowser.browser": .chromium, // Arc
        "company.thebrowser.dia": .chromium, // Dia
        "com.microsoft.edgemac": .chromium,
        "ai.perplexity.comet": .chromium, // Comet
        "com.operasoftware.opera": .chromium,
        "com.brave.browser": .chromium,
        "com.vivaldi.vivaldi": .chromium,
    ]

    private var poller: Timer?
    private var observers: [Any] = []
    private var checkInFlight = false
    /// Domains whose pass ran out this session — relock gets the 3s fade.
    private var recentlyPassed: Set<String> = []

    private init() {}

    func start() {
        for name in [Notification.Name.focusPhaseDidChange, .focusSessionDidEnd] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { _ in
                Task { @MainActor in
                    BrowserBlocker.shared.sessionStateChanged()
                }
            })
        }
        sessionStateChanged()
    }

    private var blockingActive: Bool {
        let focus = FocusSessionManager.shared
        return focus.isRunning && focus.isFocusPhase
    }

    private func sessionStateChanged() {
        if blockingActive, poller == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                Task { @MainActor in
                    await BrowserBlocker.shared.checkActiveTab()
                }
            }
            poller = timer
        } else if !blockingActive {
            poller?.invalidate()
            poller = nil
        }
    }

    private func checkActiveTab() async {
        guard !checkInFlight, blockingActive else { return }
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontmost.bundleIdentifier?.lowercased(),
              let engine = Self.browsers[bundleID] else { return }
        checkInFlight = true
        defer { checkInFlight = false }

        let urlScript = switch engine {
        case .safari:
            "tell application id \"\(bundleID)\" to get URL of current tab of front window"
        case .chromium:
            "tell application id \"\(bundleID)\" to get URL of active tab of front window"
        }

        // Missing Automation permission or no window: silently do nothing.
        guard let descriptor = try? await AppleScriptHelper.execute(urlScript),
              let urlString = descriptor.stringValue,
              let url = URL(string: urlString) else { return }

        guard url.scheme != "file" else { return } // already on the block page
        guard let domain = BlocklistMatcher.domainMatches(host: url.host, blockedDomains: Defaults[.blockedDomains]) else { return }

        if PassCenter.shared.expiry(for: .domain(domain)) != nil { return }
        let relocking = recentlyPassed.remove(domain) != nil

        await redirect(bundleID: bundleID, engine: engine, from: url, domain: domain, relock: relocking)
    }

    private func redirect(bundleID: String, engine: Engine, from original: URL, domain: String, relock: Bool) async {
        guard var components = Bundle.main.url(forResource: "lockedin", withExtension: "html")
            .flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { return }
        components.queryItems = [
            URLQueryItem(name: "left", value: FocusSessionManager.shared.remainingTimeText),
            URLQueryItem(name: "domain", value: domain),
            URLQueryItem(name: "back", value: original.absoluteString),
            URLQueryItem(name: "relock", value: relock ? "1" : "0"),
        ]
        guard let blockURL = components.url?.absoluteString else { return }

        let setScript = switch engine {
        case .safari:
            "tell application id \"\(bundleID)\" to set URL of current tab of front window to \"\(blockURL)\""
        case .chromium:
            "tell application id \"\(bundleID)\" to set URL of active tab of front window to \"\(blockURL)\""
        }
        try? await AppleScriptHelper.executeVoid(setScript)
    }

    /// Handles lockedin://pass?domain=x&back=url from the block page.
    func handlePassURL(_ url: URL) {
        guard url.scheme == "lockedin", url.host == "pass" || url.path == "pass",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let domain = components.queryItems?.first(where: { $0.name == "domain" })?.value
        else { return }

        PassCenter.shared.grant(kind: .domain(domain), name: domain)
        recentlyPassed.insert(domain)

        // Send the tab back where it was going.
        if let back = components.queryItems?.first(where: { $0.name == "back" })?.value,
           let backURL = URL(string: back),
           let frontmost = NSWorkspace.shared.frontmostApplication,
           let bundleID = frontmost.bundleIdentifier?.lowercased(),
           let engine = Self.browsers[bundleID] {
            Task { @MainActor in
                let script = switch engine {
                case .safari:
                    "tell application id \"\(bundleID)\" to set URL of current tab of front window to \"\(backURL.absoluteString)\""
                case .chromium:
                    "tell application id \"\(bundleID)\" to set URL of active tab of front window to \"\(backURL.absoluteString)\""
                }
                try? await AppleScriptHelper.executeVoid(script)
            }
        }
    }
}
