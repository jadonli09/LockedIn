//
//  BlocklistMatcher.swift
//  boringNotch
//
//  Pure matching + 2-minute-pass bookkeeping for the blocker, separated from
//  AppBlocker so the unit test target can compile it without AppKit.
//

import Foundation

struct BlocklistMatcher {
    var blockedBundleIDs: Set<String>
    /// bundle id → pass expiry
    var passes: [String: Date] = [:]

    static let passDuration: TimeInterval = 120

    init(blockedBundleIDs: some Sequence<String>) {
        self.blockedBundleIDs = Set(blockedBundleIDs.map { $0.lowercased() })
    }

    func isBlocked(bundleID: String?, at now: Date) -> Bool {
        guard let bundleID = bundleID?.lowercased(), blockedBundleIDs.contains(bundleID) else { return false }
        return !hasActivePass(bundleID: bundleID, at: now)
    }

    func hasActivePass(bundleID: String?, at now: Date) -> Bool {
        guard let bundleID = bundleID?.lowercased(), let expiry = passes[bundleID] else { return false }
        return expiry > now
    }

    /// Grants a 120s pass. Passes are per-item and don't stack: granting while
    /// one is active keeps the earlier expiry.
    mutating func grantPass(bundleID: String, at now: Date) -> Date {
        let bundleID = bundleID.lowercased()
        if let existing = passes[bundleID], existing > now {
            return existing
        }
        let expiry = now.addingTimeInterval(Self.passDuration)
        passes[bundleID] = expiry
        return expiry
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

    mutating func clearPasses() {
        passes = [:]
    }
}
