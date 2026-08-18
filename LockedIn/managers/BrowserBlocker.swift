//
//  BrowserBlocker.swift
//  LockedIn
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
    private var didPrimePermissions = false
    private var observers: [Any] = []
    private var checkStartedAt: Date?
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

    /// Fires a harmless query at every *running* browser from the table so
    /// macOS surfaces the per-browser Automation prompts at a deliberate
    /// moment (session start) instead of mid-poll where they can hang unseen.
    private func primePermissionsIfNeeded() {
        guard !didPrimePermissions else { return }
        didPrimePermissions = true
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
        for bundleID in Self.browsers.keys where running.contains(bundleID) {
            Task { @MainActor in
                try? await AppleScriptHelper.executeVoid("tell application id \"\(bundleID)\" to count windows")
            }
        }
    }

    private func sessionStateChanged() {
        if blockingActive {
            primePermissionsIfNeeded()
        }
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

    /// One poll: for every *running* browser (not just the frontmost app),
    /// walk every window and every tab, and redirect any tab on a blocked
    /// domain — so a blocked site can't hide in a background window or an
    /// inactive tab (the Google Meet screen-share case).
    private func checkActiveTab() async {
        if let started = checkStartedAt, Date().timeIntervalSince(started) < 6 { return }
        guard blockingActive else { return }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
        let targets = Self.browsers.filter { running.contains($0.key) }
        guard !targets.isEmpty else { return }
        checkStartedAt = Date()
        defer { checkStartedAt = nil }

        for (bundleID, engine) in targets {
            await scanBrowser(bundleID: bundleID, engine: engine)
        }
    }

    /// Lists every tab as "windowIndex|tabIndex|url" lines in one round-trip,
    /// then redirects each blocked tab by exact index. (Inside a browser's
    /// `tell` block the bare word `tab` is the tab *class*, so the delimiter
    /// is an explicit "|" character, never the tab character.)
    private func scanBrowser(bundleID: String, engine: Engine) async {
        let listScript = """
        tell application id "\(bundleID)"
            set out to ""
            set wi to 0
            repeat with w in windows
                set wi to wi + 1
                set ti to 0
                repeat with t in tabs of w
                    set ti to ti + 1
                    try
                        set out to out & wi & "|" & ti & "|" & (URL of t) & linefeed
                    end try
                end repeat
            end repeat
            return out
        end tell
        """
        // Missing Automation permission or no windows: silently do nothing.
        guard let descriptor = try? await AppleScriptHelper.execute(listScript),
              let listing = descriptor.stringValue else { return }

        let blocked = Defaults[.blockedDomains]
        for line in listing.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3,
                  let windowIndex = Int(parts[0]), let tabIndex = Int(parts[1]),
                  let url = URL(string: String(parts[2])) else { continue }
            guard url.scheme != "file" else { continue } // already on the block page
            guard let domain = BlocklistMatcher.domainMatches(host: url.host, blockedDomains: blocked) else { continue }
            if PassCenter.shared.expiry(for: .domain(domain)) != nil { continue }
            let relocking = recentlyPassed.remove(domain) != nil

            await redirect(bundleID: bundleID, engine: engine, windowIndex: windowIndex, tabIndex: tabIndex,
                           from: url, domain: domain, relock: relocking)
        }
    }

    private func redirect(bundleID: String, engine: Engine, windowIndex: Int, tabIndex: Int,
                          from original: URL, domain: String, relock: Bool) async {
        guard var components = Bundle.main.url(forResource: "lockedin", withExtension: "html")
            .flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { return }
        let deadlineMillis = Int(Date().addingTimeInterval(FocusSessionManager.shared.remaining).timeIntervalSince1970 * 1000)
        let durationSeconds = Int(FocusSessionManager.shared.state?.phaseDuration ?? 0)
        components.queryItems = [
            URLQueryItem(name: "until", value: String(deadlineMillis)),
            URLQueryItem(name: "duration", value: String(durationSeconds)),
            URLQueryItem(name: "accent", value: Defaults[.focusAccent].hex),
            URLQueryItem(name: "b", value: bundleID),
            URLQueryItem(name: "domain", value: domain),
            URLQueryItem(name: "back", value: original.absoluteString),
            URLQueryItem(name: "relock", value: relock ? "1" : "0"),
        ]
        guard let blockURL = components.url?.absoluteString else { return }

        // Same tab/window model on both engines for indexed access.
        _ = engine
        let setScript = "tell application id \"\(bundleID)\" to set URL of tab \(tabIndex) of window \(windowIndex) to \"\(blockURL)\""
        try? await AppleScriptHelper.executeVoid(setScript)
    }

    /// Handles lockedin:// actions from the block page:
    /// lockedin://pass?domain=x&back=url&b=browser grants a 2-min pass and
    /// restores the tab; lockedin://close?b=browser closes the block-page tab
    /// ("Stay locked in"). The `b` param names the browser that showed the
    /// page — the frontmost app can be LockedIn itself while the URL opens.
    func handleURL(_ url: URL) {
        guard url.scheme == "lockedin",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return }
        let action = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let browser = components.queryItems?.first(where: { $0.name == "b" })?.value

        switch action {
        case "pass":
            guard let domain = components.queryItems?.first(where: { $0.name == "domain" })?.value
            else { return }

            PassCenter.shared.grant(kind: .domain(domain), name: domain)
            recentlyPassed.insert(domain)

            // Send the tab back where it was going.
            if let back = components.queryItems?.first(where: { $0.name == "back" })?.value,
               let backURL = URL(string: back) {
                runInBrowser(browser,
                    safari: "set URL of current tab of front window to \"\(backURL.absoluteString)\"",
                    chromium: "set URL of active tab of front window to \"\(backURL.absoluteString)\""
                )
            }

        case "close":
            runInBrowser(browser,
                safari: "close current tab of front window",
                chromium: "close active tab of front window"
            )

        default:
            break
        }
    }

    /// Runs a tab command in the named browser, falling back to the frontmost
    /// app when the block page predates the `b` param.
    private func runInBrowser(_ preferredBundleID: String?, safari: String, chromium: String) {
        var bundleID = preferredBundleID?.lowercased()
        if bundleID == nil || Self.browsers[bundleID!] == nil {
            bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased()
        }
        guard let bundleID, let engine = Self.browsers[bundleID] else { return }
        let body = engine == .safari ? safari : chromium
        Task { @MainActor in
            try? await AppleScriptHelper.executeVoid("tell application id \"\(bundleID)\" to \(body)")
        }
    }
}
