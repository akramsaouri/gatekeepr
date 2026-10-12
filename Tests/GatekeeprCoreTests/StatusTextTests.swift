import XCTest
@testable import GatekeeprCore

final class StatusTextTests: XCTestCase {
    private let stockholm = TimeZone(identifier: "Europe/Stockholm")!

    private func rows(_ summary: StatusText.Summary) -> [String] {
        summary.rows.map { "\($0.label): \($0.value)" }
    }

    func testShort() throws {
        XCTAssertEqual(StatusText.short(try Fixture.status("normal-day", at: "2026-10-09T12:00:00Z")), "19h55m")
        XCTAssertEqual(StatusText.short(try Fixture.status("normal-day", at: "2026-10-10T09:00:00Z")), "expired")
        XCTAssertEqual(StatusText.short(try Fixture.status("empty", at: "2026-10-10T12:00:00Z")), "no session")
        // The rotation fixture's 6 Oct session ends with a driver restart.
        XCTAssertEqual(StatusText.short(try Fixture.status("rotation", at: "2026-10-07T06:15:00Z")), "signed out")
    }

    func testSummaryWhileActive() throws {
        let status = try Fixture.status("normal-day", at: "2026-10-09T12:00:00Z")
        let summary = StatusText.summary(status, logDirectory: "/var/log/appgate", timeZone: stockholm)

        XCTAssertEqual(summary.heading, "Appgate session active")
        XCTAssertEqual(rows(summary), [
            "Signed in: Fri 9 Oct 09:55",
            "Expires: Sat 10 Oct 09:55",
            "Time left: 19h55m",
            "Length: 24h00m, measured from 1 session",
        ])
    }

    func testSummaryInWarnWindowWithRenewalNotice() throws {
        let status = try Fixture.status("reconnect", at: "2026-09-29T07:18:00Z")
        let summary = StatusText.summary(status, logDirectory: "/var/log/appgate", timeZone: stockholm)

        XCTAssertEqual(summary.heading, "Appgate session expires soon (warning at 30m)")
        XCTAssertEqual(summary.rows[1].value, "Tue 29 Sep 09:21, per Appgate's expiry warning")
    }

    func testSummaryWhenExpiredAndSignedOut() throws {
        let expired = try Fixture.status("normal-day", at: "2026-10-10T09:00:00Z")
        XCTAssertEqual(rows(StatusText.summary(expired, logDirectory: "/x", timeZone: stockholm)), [
            "Signed in: Fri 9 Oct 09:55",
            "Expired: Sat 10 Oct 09:55 (1h04m ago)",
            "Length: 24h00m, measured from 1 session",
        ])

        let signedOut = try Fixture.status("rotation", at: "2026-10-07T06:15:00Z")
        let summary = StatusText.summary(signedOut, logDirectory: "/x", timeZone: stockholm)
        XCTAssertEqual(summary.heading, "Not signed in to Appgate")
        XCTAssertEqual(summary.rows.map(\.label), ["Last session", "Ended"])
        XCTAssertTrue(summary.rows[1].value.hasSuffix("(the Appgate driver restarted)"), summary.rows[1].value)
    }

    func testSummaryWithNoSession() throws {
        let status = try Fixture.status("empty", at: "2026-10-10T12:00:00Z")
        let summary = StatusText.summary(status, logDirectory: "/var/log/appgate")
        XCTAssertEqual(summary.heading, "No Appgate session found in /var/log/appgate.")
        XCTAssertEqual(summary.rows, [])
    }

    func testSessionLength() {
        XCTAssertEqual(StatusText.sessionLength(SessionLength(duration: 86_400, learnedFrom: 0)),
                       "24h00m (default, no measured sessions yet)")
        XCTAssertEqual(StatusText.sessionLength(SessionLength(duration: 86_399.2, learnedFrom: 17)),
                       "24h00m, the median of 17 measured sessions")
    }

    func testAnalysisAtLaterTimeMatchesRereadingTheLogs() throws {
        // Nothing is logged between these two moments, so moving the clock
        // forward must give the same answer as reading the logs again.
        let earlier = try Fixture.analyze("normal-day", at: "2026-10-10T07:00:00Z")
        let later = utc("2026-10-10T07:40:00Z")
        let moved = earlier.at(later).status(warnThreshold: 30 * 60)
        let reread = try Fixture.status("normal-day", at: "2026-10-10T07:40:00Z")

        XCTAssertEqual(earlier.status(warnThreshold: 30 * 60).state, .active)
        XCTAssertEqual(moved.state, .expiringSoon)
        XCTAssertEqual(moved.state, reread.state)
        XCTAssertEqual(moved.now, later)
        XCTAssertEqual(moved.expiry, reread.expiry)
        XCTAssertEqual(moved.session, reread.session)
    }
}
