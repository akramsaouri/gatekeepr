import XCTest
@testable import GatekeeprCore

/// Session rules on hand-built event sequences, for the cases the fixtures don't cover.
final class SessionBuilderTests: XCTestCase {
    private let base = utc("2026-10-10T08:00:00Z")

    private func event(_ hours: Double, _ kind: LogEvent.Kind) -> LogEvent {
        LogEvent(date: base.addingTimeInterval(hours * 3600), kind: kind, file: "driver.log", line: 0)
    }

    private func analysis(_ events: [LogEvent], nowHours: Double) -> Analysis {
        Analysis(now: base.addingTimeInterval(nowHours * 3600), logFiles: [], events: events)
    }

    func testOneLoginPerSiteIsOneSignIn() {
        let sessions = SessionBuilder.sessions(from: [
            event(0, .login(site: "AWS")),
            event(0.0005, .login(site: "GCP")),
        ])
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].reconnects, 0)
    }

    func testSigningOutEarly() {
        let result = analysis([
            event(0, .login(site: "AWS")),
            event(2, .clientClosed),
        ], nowHours: 3)
        XCTAssertEqual(result.outcome(of: result.sessions[0]), .signedOut)
        XCTAssertEqual(result.status(warnThreshold: 1800).state, .signedOut)
        XCTAssertEqual(result.status(warnThreshold: 1800).state.exitCode, 2)
    }

    func testNewControlConnectionWithoutCloseStartsANewSession() {
        let result = analysis([
            event(0, .login(site: "AWS")),
            event(5, .clientConnected),
            event(5.001, .deploy),
            event(5.002, .login(site: "AWS")),
        ], nowHours: 6)
        XCTAssertEqual(result.sessions.count, 2)
        XCTAssertEqual(result.sessions[0].endKind, .clientRestarted)
        XCTAssertEqual(result.outcome(of: result.sessions[0]), .interrupted)
        XCTAssertEqualDates(result.sessions[1].start, base.addingTimeInterval(5.002 * 3600))
    }

    func testDeployWithoutACountdownIsNotARenewal() {
        let sessions = SessionBuilder.sessions(from: [
            event(0, .login(site: "AWS")),
            event(10, .deploy),
            event(10.001, .login(site: "AWS")),
        ])
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].reconnects, 1)
    }

    func testDeployAfterTheCountdownRanOutIsNotARenewal() {
        let sessions = SessionBuilder.sessions(from: [
            event(0, .login(site: "AWS")),
            event(23.9, .renewalNotification(timeLeft: 300)),
            event(24.5, .deploy),
        ])
        XCTAssertEqual(sessions.count, 1)
    }

    func testNoticesBeforeTheFirstSignInAreIgnored() {
        let sessions = SessionBuilder.sessions(from: [
            event(0, .renewalNotification(timeLeft: 300)),
            event(0.1, .clientClosed),
            event(1, .login(site: "AWS")),
        ])
        XCTAssertEqual(sessions.count, 1)
        XCTAssertNil(sessions[0].firstRenewalNotice)
    }

    func testLengthIsTheMedianOfMeasuredSessions() {
        func session(at start: Double, noticeAfter hours: Double) -> [LogEvent] {
            [
                event(start, .login(site: "AWS")),
                event(start + hours, .renewalNotification(timeLeft: 300)),
                event(start + hours + 300.0 / 3600, .clientClosed),
            ]
        }
        let result = analysis(
            session(at: 0, noticeAfter: 10) + session(at: 30, noticeAfter: 12) +
                session(at: 60, noticeAfter: 20) + session(at: 90, noticeAfter: 22),
            nowHours: 200
        )
        XCTAssertEqual(result.sessionLength.learnedFrom, 4)
        // Lengths 10h05, 12h05, 20h05, 22h05: the median is halfway between the middle two.
        XCTAssertEqual(result.sessionLength.duration, 16 * 3600 + 300, accuracy: 0.001)
    }

    func testMeasurementUsesTheFirstNoticeTimeLeft() {
        // Asleep through the first notices: the first one seen says 120 s left.
        let sessions = SessionBuilder.sessions(from: [
            event(0, .login(site: "AWS")),
            event(23.9, .renewalNotification(timeLeft: 120)),
        ])
        XCTAssertEqual(sessions[0].measuredLength ?? 0, 23.9 * 3600 + 120, accuracy: 0.001)
    }

    func testNoSessionsAtAll() {
        let result = analysis([event(0, .clientClosed)], nowHours: 1)
        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertEqual(result.status(warnThreshold: 1800).state, .noSession)
    }
}
