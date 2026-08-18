//
//  BlocklistMatcher.swift
//  LockedIn
//
//  Pure matching + 2-minute-pass bookkeeping for the blockers, separated from
//  the managers so the unit test target can compile it without AppKit.
//

import Foundation

struct BlocklistMatcher {
    var blockedBundleIDs: Set<String>

    init(blockedBundleIDs: some Sequence<String>) {
        self.blockedBundleIDs = Set(blockedBundleIDs.map { $0.lowercased() })
    }

    func isBlocklisted(bundleID: String?) -> Bool {
        guard let bundleID = bundleID?.lowercased() else { return false }
        return blockedBundleIDs.contains(bundleID)
    }

    /// Domain matching for the browser blocker: exact or subdomain match
    /// against the blocked domain list ("x.com" blocks "www.x.com").
    static func domainMatches(host: String?, blockedDomains: some Sequence<String>) -> String? {
        guard var host = host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        for domain in blockedDomains {
            let domain = domain.lowercased()
            if host == domain || host.hasSuffix("." + domain) {
                return domain
            }
        }
        return nil
    }
}

/// The 2-minute pass ledger: passes are exactly 120s, per-item, don't stack,
/// and aren't counted or logged anywhere. Keys are opaque ("app:com.x",
/// "domain:x.com") so one ledger serves both blockers.
struct PassBook {
    private(set) var passes: [String: Date] = [:]

    static let passDuration: TimeInterval = 120

    func expiry(for key: String, at now: Date) -> Date? {
        guard let expiry = passes[key], expiry > now else { return nil }
        return expiry
    }

    func hasActivePass(for key: String, at now: Date) -> Bool {
        expiry(for: key, at: now) != nil
    }

    /// Granting while a pass is active keeps the earlier expiry (no stacking).
    @discardableResult
    mutating func grant(_ key: String, at now: Date) -> Date {
        if let existing = passes[key], existing > now {
            return existing
        }
        let expiry = now.addingTimeInterval(Self.passDuration)
        passes[key] = expiry
        return expiry
    }

    mutating func revoke(_ key: String) {
        passes[key] = nil
    }

    mutating func prune(at now: Date) {
        passes = passes.filter { $0.value > now }
    }

    mutating func clear() {
        passes = [:]
    }
}
