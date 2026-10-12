import GatekeeprCore
@testable import GatekeeprMenuBar
import XCTest

final class NotificationPlannerTests: XCTestCase {
    private let session = utc("2026-10-09T08:00:00Z")

    private func due(_ lines: [String] = twoSessions, at now: String, warn: TimeInterval = 30 * 60,
                     ledger: NotificationLedger = NotificationLedger()) throws -> SessionNotification? {
        let status = try analyze(lines, at: now).status(warnThreshold: warn)
        return NotificationPlanner.due(for: status, ledger: ledger, timeZone: stockholm)
    }

    func testWarningOnceInsideTheWindow() throws {
        XCTAssertNil(try due(at: "2026-10-10T07:29:00Z"))

        let warning = try XCTUnwrap(try due(at: "2026-10-10T07:30:00Z"))
        XCTAssertEqual(warning.kind, .warning)
        XCTAssertEqual(warning.session, session)
        XCTAssertEqual(warning.title, "Appgate session expires in 30m")
        XCTAssertEqual(warning.body, "It ends Sat 10 Oct 10:00. Click to open Appgate.")
        XCTAssertEqual(warning.identifier, "gatekeepr.warning")

        var ledger = NotificationLedger()
        ledger.record(warning)
        XCTAssertNil(try due(at: "2026-10-10T07:30:00Z", ledger: ledger))
        XCTAssertNil(try due(at: "2026-10-10T07:50:00Z", ledger: ledger))
    }

    func testWarningTitleRoundsToTheNearestMinute() throws {
        // The tick lands just after the threshold is crossed.
        XCTAssertEqual(try due(at: "2026-10-10T07:30:00.050Z")?.title, "Appgate session expires in 30m")
        XCTAssertEqual(try due(at: "2026-10-10T07:15:00Z", warn: 60 * 60)?.title, "Appgate session expires in 45m")
    }

    func testExpiryNoticeOnceWhileItIsNews() throws {
        let warned = NotificationLedger(warnedSession: session)
        let expired = try XCTUnwrap(try due(at: "2026-10-10T08:01:00Z", ledger: warned))
        XCTAssertEqual(expired.kind, .expired)
        XCTAssertEqual(expired.title, "Appgate session expired")
        XCTAssertEqual(expired.body, "It ended Sat 10 Oct 10:00. Sign in again to reconnect.")

        var ledger = warned
        ledger.record(expired)
        XCTAssertEqual(ledger, NotificationLedger(warnedSession: session, expiredSession: session))
        XCTAssertNil(try due(at: "2026-10-10T08:05:00Z", ledger: ledger))
    }

    func testOldExpiryIsNotAnnounced() throws {
        // Starting the app (or waking the Mac) long after the session ran out.
        XCTAssertNotNil(try due(at: "2026-10-10T08:15:00Z"))
        XCTAssertNil(try due(at: "2026-10-10T08:15:01Z"))
        XCTAssertNil(try due(at: "2026-10-12T09:00:00Z"))
    }

    func testExpiryWhenTheClientClosesAtTheEnd() throws {
        let lines = twoSessions + [
            LogLine.renewalNotice("2026-10-10T07:55:00Z", timeLeft: 300),
            LogLine.renewalNotice("2026-10-10T07:59:00Z", timeLeft: 60),
            LogLine.clientClosed("2026-10-10T08:00:01Z"),
        ]
        XCTAssertEqual(try due(lines, at: "2026-10-10T08:02:00Z", ledger: NotificationLedger(warnedSession: session))?.kind, .expired)
    }

    func testNothingForSigningOutOrNoSession() throws {
        let signedOut = twoSessions + [LogLine.clientClosed("2026-10-10T07:40:00Z")]
        XCTAssertNil(try due(signedOut, at: "2026-10-10T07:45:00Z"))
        XCTAssertNil(try due(signedOut, at: "2026-10-10T08:05:00Z"))
        XCTAssertNil(try due([], at: "2026-10-10T08:05:00Z"))
    }

    func testRenewalIsANewSessionForNotifications() throws {
        let lines = twoSessions + [
            LogLine.renewalNotice("2026-10-10T07:55:00Z", timeLeft: 300),
            LogLine.deploy("2026-10-10T07:57:00Z"),
        ]
        let renewed = utc("2026-10-10T07:57:00Z")
        // Warned during the old session's countdown; the new session gets its own warning.
        let ledger = NotificationLedger(warnedSession: session)
        XCTAssertNil(try due(lines, at: "2026-10-10T12:00:00Z", ledger: ledger))
        let warning = try XCTUnwrap(try due(lines, at: "2026-10-11T07:30:00Z", ledger: ledger))
        XCTAssertEqual(warning.session, renewed)
        XCTAssertEqual(warning.kind, .warning)
    }
}
