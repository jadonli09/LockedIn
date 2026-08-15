//
//  PassCenter.swift
//  boringNotch
//
//  Shared, observable 2-minute-pass registry for both blockers, so the island
//  can show countdowns and cancel passes. Wraps the pure PassBook ledger.
//

import Combine
import Foundation

struct ActivePass: Identifiable, Equatable {
    enum Kind: Equatable {
        case app(bundleID: String)
        case domain(String)
    }

    let kind: Kind
    let name: String
    let expiry: Date

    var id: String {
        switch kind {
        case .app(let bundleID): "app:\(bundleID.lowercased())"
        case .domain(let domain): "domain:\(domain.lowercased())"
        }
    }

    func remaining(at now: Date) -> TimeInterval {
        max(0, expiry.timeIntervalSince(now))
    }
}

@MainActor
final class PassCenter: ObservableObject {
    static let shared = PassCenter()

    @Published private(set) var passes: [ActivePass] = []
    /// Ticks once per second while passes exist, so countdown views refresh.
    @Published private(set) var now: Date = .init()

    private var book = PassBook()
    private var names: [String: String] = [:]
    private var ticker: AnyCancellable?

    private init() {}

    /// Non-stacking: granting while active keeps the earlier expiry.
    @discardableResult
    func grant(kind: ActivePass.Kind, name: String) -> Date {
        let key = ActivePass(kind: kind, name: name, expiry: .distantPast).id
        let expiry = book.grant(key, at: Date())
        names[key] = name
        rebuild()
        return expiry
    }

    func expiry(for kind: ActivePass.Kind) -> Date? {
        let key = ActivePass(kind: kind, name: "", expiry: .distantPast).id
        return book.expiry(for: key, at: Date())
    }

    func cancel(id: String) {
        book.revoke(id)
        names[id] = nil
        rebuild()
    }

    func clearAll() {
        book.clear()
        names = [:]
        rebuild()
    }

    /// The pass ending soonest — what the island's countdown shows.
    var soonest: ActivePass? {
        passes.min { $0.expiry < $1.expiry }
    }

    private func rebuild() {
        let currentNow = Date()
        book.prune(at: currentNow)
        passes = book.passes.compactMap { key, expiry in
            let kind: ActivePass.Kind
            if key.hasPrefix("app:") {
                kind = .app(bundleID: String(key.dropFirst(4)))
            } else if key.hasPrefix("domain:") {
                kind = .domain(String(key.dropFirst(7)))
            } else {
                return nil
            }
            return ActivePass(kind: kind, name: names[key] ?? key, expiry: expiry)
        }
        .sorted { $0.expiry < $1.expiry }

        now = currentNow
        if passes.isEmpty {
            ticker = nil
        } else if ticker == nil {
            ticker = Timer.publish(every: 1, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.now = Date()
                    if self.book.passes.contains(where: { $0.value <= self.now }) {
                        self.rebuild()
                    }
                }
        }
    }
}
