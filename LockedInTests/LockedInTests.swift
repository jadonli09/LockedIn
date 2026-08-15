//
//  LockedInTests.swift
//  LockedInTests
//
//  Unit tests for the pure focus logic: the timestamp state machine,
//  persistence round-trips, idle-pause accounting, the blocklist matcher,
//  and 2-minute pass expiry.
//

import XCTest

final class FocusSessionStateTests: XCTestCase {
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testStartingFocusHasFullDuration() {
        let s = FocusSessionState.startingFocus(preset: .classic, at: t0)
        XCTAssertEqual(s.phase, .focus)
        XCTAssertEqual(s.remaining(at: t0), 25 * 60)
        XCTAssertEqual(s.progress(at: t0), 0)
        XCTAssertFalse(s.isPaused)
    }

    func testElapsedAndRemainingTrackWallClock() {
        let s = FocusSessionState.startingFocus(preset: .classic, at: t0)
        let later = t0.addingTimeInterval(10 * 60)
        XCTAssertEqual(s.elapsed(at: later), 10 * 60)
        XCTAssertEqual(s.remaining(at: later), 15 * 60)
        XCTAssertEqual(s.progress(at: later), 0.4, accuracy: 0.0001)
    }

    func testExpiry() {
        let s = FocusSessionState.startingFocus(preset: .classic, at: t0)
        XCTAssertFalse(s.isExpired(at: t0.addingTimeInterval(24 * 60)))
        XCTAssertTrue(s.isExpired(at: t0.addingTimeInterval(25 * 60)))
        // Far in the future — e.g. after a relaunch or sleep — still just expired.
        XCTAssertTrue(s.isExpired(at: t0.addingTimeInterval(9999 * 60)))
    }

    func testPauseFreezesTheClock() {
        var s = FocusSessionState.startingFocus(preset: .classic, at: t0)
        s.pause(at: t0.addingTimeInterval(5 * 60))
        // An hour passes while paused; elapsed stays frozen at 5 minutes.
        XCTAssertEqual(s.elapsed(at: t0.addingTimeInterval(65 * 60)), 5 * 60)
        XCTAssertFalse(s.isExpired(at: t0.addingTimeInterval(65 * 60)))
    }

    func testResumeShiftsStartSoPauseNeverCounts() {
        var s = FocusSessionState.startingFocus(preset: .classic, at: t0)
        s.pause(at: t0.addingTimeInterval(5 * 60))
        s.resume(at: t0.addingTimeInterval(35 * 60)) // paused 30 minutes
        // 5 attended minutes so far; 20 more minutes of work to go.
        let atResume = t0.addingTimeInterval(35 * 60)
        XCTAssertEqual(s.elapsed(at: atResume), 5 * 60)
        XCTAssertEqual(s.remaining(at: atResume.addingTimeInterval(10 * 60)), 10 * 60)
    }

    func testDoublePauseAndDoubleResumeAreNoOps() {
        var s = FocusSessionState.startingFocus(preset: .classic, at: t0)
        s.pause(at: t0.addingTimeInterval(60))
        let paused = s
        s.pause(at: t0.addingTimeInterval(120))
        XCTAssertEqual(s.pausedAt, paused.pausedAt)
        s.resume(at: t0.addingTimeInterval(180))
        let resumed = s
        s.resume(at: t0.addingTimeInterval(240))
        XCTAssertEqual(s.phaseStart, resumed.phaseStart)
    }

    // Idle auto-pause accounting: the pause is backdated by the idle interval,
    // so idle time never counts — 25 minutes means 25 attended minutes.
    func testBackdatedIdlePauseExcludesIdleTime() {
        var s = FocusSessionState.startingFocus(preset: .classic, at: t0)
        // User works 10 minutes, then goes idle. The monitor notices after the
        // 5-minute threshold at t=15min and pauses backdated to t=10min.
        let detectionTime = t0.addingTimeInterval(15 * 60)
        s.pause(at: detectionTime.addingTimeInterval(-5 * 60))
        XCTAssertEqual(s.elapsed(at: detectionTime), 10 * 60)
        // Resume at t=45min: still exactly 10 attended minutes on the clock.
        s.resume(at: t0.addingTimeInterval(45 * 60))
        XCTAssertEqual(s.elapsed(at: t0.addingTimeInterval(45 * 60)), 10 * 60)
        XCTAssertEqual(s.remaining(at: t0.addingTimeInterval(50 * 60)), 10 * 60)
    }

    func testBackdatedPauseBeforePhaseStartClampsToZero() {
        var s = FocusSessionState.startingFocus(preset: .classic, at: t0)
        // Idle the whole time: backdated pause lands before phaseStart.
        s.pause(at: t0.addingTimeInterval(-60))
        XCTAssertEqual(s.elapsed(at: t0.addingTimeInterval(600)), 0)
    }

    // MARK: - Phase advancement

    func testFocusAdvancesToShortBreak() {
        let s = FocusSessionState.startingFocus(preset: .classic, at: t0)
        let next = s.advanced(at: t0.addingTimeInterval(25 * 60), longBreaksEnabled: true)
        XCTAssertEqual(next.phase, .shortBreak)
        XCTAssertEqual(next.phaseDuration, 5 * 60)
        XCTAssertEqual(next.completedFocusCount, 1)
        XCTAssertFalse(next.isPaused)
    }

    func testBreakAdvancesToFocus() {
        let s = FocusSessionState.startingFocus(preset: .deep, at: t0)
            .advanced(at: t0, longBreaksEnabled: true)
        let next = s.advanced(at: t0, longBreaksEnabled: true)
        XCTAssertEqual(next.phase, .focus)
        XCTAssertEqual(next.phaseDuration, 50 * 60)
        XCTAssertEqual(next.completedFocusCount, 1)
    }

    func testEveryFourthCycleGetsLongBreak() {
        var s = FocusSessionState.startingFocus(preset: .classic, at: t0)
        for cycle in 1...4 {
            s = s.advanced(at: t0, longBreaksEnabled: true) // focus → break
            if cycle == 4 {
                XCTAssertEqual(s.phase, .longBreak)
                XCTAssertEqual(s.phaseDuration, 15 * 60) // 3× the short break
            } else {
                XCTAssertEqual(s.phase, .shortBreak)
            }
            s = s.advanced(at: t0, longBreaksEnabled: true) // break → focus
        }
    }

    func testLongBreaksCanBeDisabled() {
        var s = FocusSessionState.startingFocus(preset: .classic, at: t0)
        for _ in 1...4 {
            s = s.advanced(at: t0, longBreaksEnabled: false)
            XCTAssertEqual(s.phase, .shortBreak)
            s = s.advanced(at: t0, longBreaksEnabled: false)
        }
    }

    // MARK: - Persistence across relaunch

    func testCodableRoundTripPreservesTheClock() throws {
        var s = FocusSessionState.startingFocus(preset: .marathon, at: t0)
        s.pause(at: t0.addingTimeInterval(120))

        let data = try JSONEncoder().encode(s)
        let restored = try JSONDecoder().decode(FocusSessionState.self, from: data)

        let much = t0.addingTimeInterval(7200)
        XCTAssertEqual(restored.phase, s.phase)
        XCTAssertEqual(restored.elapsed(at: much), s.elapsed(at: much))
        XCTAssertEqual(restored.remaining(at: much), s.remaining(at: much))
        XCTAssertEqual(restored.pausedAt, s.pausedAt)
        XCTAssertEqual(restored.completedFocusCount, s.completedFocusCount)
    }

    func testRunningSessionSurvivesRelaunchByTimestamps() throws {
        let s = FocusSessionState.startingFocus(preset: .classic, at: t0)
        let data = try JSONEncoder().encode(s)
        // "Relaunch" 7 minutes later: remaining is derived purely from timestamps.
        let restored = try JSONDecoder().decode(FocusSessionState.self, from: data)
        XCTAssertEqual(restored.remaining(at: t0.addingTimeInterval(7 * 60)), 18 * 60)
    }
}

final class BlocklistMatcherTests: XCTestCase {
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testMatchingIsCaseInsensitive() {
        let m = BlocklistMatcher(blockedBundleIDs: ["com.Apple.TextEdit"])
        XCTAssertTrue(m.isBlocked(bundleID: "com.apple.textedit", at: t0))
        XCTAssertTrue(m.isBlocked(bundleID: "COM.APPLE.TEXTEDIT", at: t0))
        XCTAssertFalse(m.isBlocked(bundleID: "com.apple.Safari", at: t0))
        XCTAssertFalse(m.isBlocked(bundleID: nil, at: t0))
    }

    func testPassGrantsExactlyTwoMinutes() {
        var m = BlocklistMatcher(blockedBundleIDs: ["a.b.c"])
        let expiry = m.grantPass(bundleID: "a.b.c", at: t0)
        XCTAssertEqual(expiry, t0.addingTimeInterval(120))
        XCTAssertFalse(m.isBlocked(bundleID: "a.b.c", at: t0.addingTimeInterval(119)))
        XCTAssertTrue(m.isBlocked(bundleID: "a.b.c", at: t0.addingTimeInterval(120)))
    }

    func testPassesDoNotStack() {
        var m = BlocklistMatcher(blockedBundleIDs: ["a.b.c"])
        let first = m.grantPass(bundleID: "a.b.c", at: t0)
        let second = m.grantPass(bundleID: "a.b.c", at: t0.addingTimeInterval(60))
        XCTAssertEqual(first, second)
        // After the original expiry a fresh grant works again.
        let third = m.grantPass(bundleID: "a.b.c", at: t0.addingTimeInterval(130))
        XCTAssertEqual(third, t0.addingTimeInterval(250))
    }

    func testPassesArePerItem() {
        var m = BlocklistMatcher(blockedBundleIDs: ["a.b.c", "x.y.z"])
        _ = m.grantPass(bundleID: "a.b.c", at: t0)
        XCTAssertFalse(m.isBlocked(bundleID: "a.b.c", at: t0.addingTimeInterval(10)))
        XCTAssertTrue(m.isBlocked(bundleID: "x.y.z", at: t0.addingTimeInterval(10)))
    }

    func testClearPassesRelocksEverything() {
        var m = BlocklistMatcher(blockedBundleIDs: ["a.b.c"])
        _ = m.grantPass(bundleID: "a.b.c", at: t0)
        m.clearPasses()
        XCTAssertTrue(m.isBlocked(bundleID: "a.b.c", at: t0.addingTimeInterval(10)))
    }

    func testDomainMatching() {
        let blocked = ["x.com", "reddit.com"]
        XCTAssertEqual(BlocklistMatcher.domainMatches(host: "x.com", blockedDomains: blocked), "x.com")
        XCTAssertEqual(BlocklistMatcher.domainMatches(host: "www.x.com", blockedDomains: blocked), "x.com")
        XCTAssertEqual(BlocklistMatcher.domainMatches(host: "old.reddit.com", blockedDomains: blocked), "reddit.com")
        XCTAssertNil(BlocklistMatcher.domainMatches(host: "notx.com", blockedDomains: blocked))
        XCTAssertNil(BlocklistMatcher.domainMatches(host: "x.com.evil.net", blockedDomains: blocked))
        XCTAssertNil(BlocklistMatcher.domainMatches(host: nil, blockedDomains: blocked))
    }
}
