import XCTest
@testable import GatekeeprCore

/// End-to-end runs over the fixture log directories.
final class ScenarioTests: XCTestCase {
    // MARK: Normal day

    func testNormalDayIsActiveWithExpiryFromLearnedLength() throws {
        let status = try Fixture.status("normal-day", at: "2026-10-09T12:00:00Z")

        XCTAssertEqual(status.state, .active)
        XCTAssertEqual(status.state.exitCode, 0)
        // AWS and GCP both log in at 07:55:35.444: one sign-in.
        XCTAssertEqualDates(status.session?.start, utc("2026-10-09T07:55:35.444Z"))
        XCTAssertEqual(status.session?.startKind, .signIn)
        // Learned from the previous session: first notice at 07:37:22.620 with
        // 300 s left, signed in at 07:42:23.386 the day before.
        XCTAssertEqual(status.sessionLength.learnedFrom, 1)
        XCTAssertEqual(status.sessionLength.duration, 86_399.234, accuracy: 0.001)
        XCTAssertEqual(status.expiry?.source, .sessionLength)
        XCTAssertEqualDates(status.expiry?.date, utc("2026-10-10T07:55:34.678Z"))
        XCTAssertEqual(DurationText.format(status.timeLeft ?? 0), "19h55m")
    }

    func testNormalDayHistory() throws {
        let analysis = try Fixture.analyze("normal-day", at: "2026-10-09T12:00:00Z")

        XCTAssertEqual(analysis.sessions.count, 2)
        let previous = analysis.sessions[0]
        XCTAssertEqualDates(previous.start, utc("2026-10-08T07:42:23.386Z"))
        XCTAssertEqualDates(previous.end, utc("2026-10-09T07:42:22.616Z"))
        XCTAssertEqual(previous.endKind, .clientClosed)
        XCTAssertEqual(analysis.outcome(of: previous), .expired)
        // The dead-connection reconnect at 21:19 the same evening.
        XCTAssertEqual(previous.reconnects, 1)
        XCTAssertEqual(analysis.outcome(of: analysis.sessions[1]), .active)
    }

    func testNormalDayWarnWindow() throws {
        let status = try Fixture.status("normal-day", at: "2026-10-10T07:30:00Z")
        XCTAssertEqual(status.state, .expiringSoon)
        XCTAssertEqual(status.state.exitCode, 1)

        let relaxed = try Fixture.status("normal-day", at: "2026-10-10T07:30:00Z", warn: 10 * 60)
        XCTAssertEqual(relaxed.state, .active)
    }

    func testNormalDayPastExpiryWithoutCloseIsExpired() throws {
        // The log just stops (laptop asleep); the learned expiry has passed.
        let status = try Fixture.status("normal-day", at: "2026-10-10T09:00:00Z")
        XCTAssertEqual(status.state, .expired)
        XCTAssertEqual(status.state.exitCode, 2)
    }

    func testFirstSessionInHistoryFallsBackTo24Hours() throws {
        let status = try Fixture.status("normal-day", at: "2026-10-08T12:00:00Z")
        XCTAssertEqual(status.state, .active)
        XCTAssertTrue(status.sessionLength.isFallback)
        XCTAssertEqual(status.sessionLength.duration, 24 * 60 * 60)
        XCTAssertEqualDates(status.expiry?.date, utc("2026-10-09T07:42:23.386Z"))
    }

    // MARK: Reconnect

    func testGatewayReconnectDoesNotResetSession() throws {
        // 07:02 a token revocation brings a deploy + update-tokens; 07:11 the
        // gateway disconnects and the client logs in again. Neither is a sign-in.
        let status = try Fixture.status("reconnect", at: "2026-09-29T07:12:30Z", warn: 5 * 60)

        XCTAssertEqual(status.state, .active)
        XCTAssertEqualDates(status.session?.start, utc("2026-09-28T07:21:20.113Z"))
        XCTAssertEqual(status.session?.reconnects, 1)
        XCTAssertEqualDates(status.expiry?.date, utc("2026-09-29T07:21:20.113Z"))
    }

    func testRenewalNotificationOverridesTheTimingModel() throws {
        let status = try Fixture.status("reconnect", at: "2026-09-29T07:18:00Z")

        XCTAssertEqual(status.state, .expiringSoon)
        XCTAssertEqual(status.expiry?.source, .renewalNotification)
        // Last notice before 07:18: 07:17:18.631 with 240 s left.
        XCTAssertEqualDates(status.expiry?.date, utc("2026-09-29T07:21:18.631Z"))
    }

    // MARK: Expiry

    func testCountdownToExpiry() throws {
        let status = try Fixture.status("expired", at: "2026-10-10T07:53:00Z")
        XCTAssertEqual(status.state, .expiringSoon)
        XCTAssertEqual(status.expiry?.source, .renewalNotification)
        // 07:52:34 notice, 180 s left.
        XCTAssertEqualDates(status.expiry?.date, utc("2026-10-10T07:55:34Z"), accuracy: 1)
    }

    func testExpiredBeforeTheClientCloses() throws {
        // The last notice said 0 s left at 07:55:34.384; the client closes at 07:55:36.888.
        let status = try Fixture.status("expired", at: "2026-10-10T07:55:35.500Z")
        XCTAssertEqual(status.state, .expired)
        XCTAssertTrue(status.session?.isOpen ?? false)
    }

    func testExpiredAfterTheClientCloses() throws {
        let status = try Fixture.status("expired", at: "2026-10-10T08:00:00Z")

        XCTAssertEqual(status.state, .expired)
        XCTAssertEqual(status.state.exitCode, 2)
        XCTAssertEqualDates(status.session?.end, utc("2026-10-10T07:55:36.888Z"))
        XCTAssertEqual(status.session?.measuredLength ?? 0, 86_398.929, accuracy: 0.001)
    }

    // MARK: Renewing in place

    func testRenewingFromTheWarningStartsANewSession() throws {
        let analysis = try Fixture.analyze("renewal", at: "2026-09-12T08:00:00Z")

        XCTAssertEqual(analysis.sessions.count, 2)
        let first = analysis.sessions[0]
        XCTAssertEqualDates(first.start, utc("2026-09-10T07:36:27.387Z"))
        XCTAssertEqual(first.endKind, .renewed)
        XCTAssertEqual(analysis.outcome(of: first), .renewed)
        // Four network reconnects that day, each with its own deploy and logins.
        XCTAssertEqual(first.reconnects, 4)
        XCTAssertEqual(first.measuredLength ?? 0, 86_398.739, accuracy: 0.001)

        let renewed = analysis.sessions[1]
        XCTAssertEqual(renewed.startKind, .renewal)
        XCTAssertEqualDates(renewed.start, utc("2026-09-11T07:31:43.100Z"))
        XCTAssertEqual(analysis.outcome(of: renewed), .expired)
        XCTAssertEqual(renewed.measuredLength ?? 0, 86_399.143, accuracy: 0.001)
        XCTAssertEqual(analysis.sessionLength.learnedFrom, 2)
    }

    func testStatusAfterRenewingInPlace() throws {
        let status = try Fixture.status("renewal", at: "2026-09-11T12:00:00Z")

        XCTAssertEqual(status.state, .active)
        XCTAssertEqual(status.session?.startKind, .renewal)
        // Not the old countdown: the renewed session's own learned expiry.
        XCTAssertEqual(status.expiry?.source, .sessionLength)
        XCTAssertEqualDates(status.expiry?.date, utc("2026-09-12T07:31:41.839Z"))
    }

    func testStatusDuringTheWarningBeforeRenewing() throws {
        let status = try Fixture.status("renewal", at: "2026-09-11T07:31:30Z")
        XCTAssertEqual(status.state, .expiringSoon)
        XCTAssertEqualDates(status.expiry?.date, utc("2026-09-11T07:36:26.959Z"))
    }

    // MARK: Rotation

    func testRotatedGzipFilesAreReadInOrder() throws {
        let analysis = try Fixture.analyze("rotation", at: "2026-10-09T12:00:00Z")

        XCTAssertEqual(analysis.logFiles.map(\.name), [
            "driver-2026-10-06.log.gz",
            "driver-2026-10-07.log.gz",
            "driver-2026-10-08.log.gz",
            "driver.log",
        ])
        // The notice and close at the top of the 10-06 file belong to a session
        // whose sign-in rotated away, so they're ignored.
        XCTAssertEqual(analysis.sessions.map(\.start), [
            utc("2026-10-06T07:52:45.811Z"),
            utc("2026-10-07T06:18:43.685Z"),
            utc("2026-10-08T07:42:23.386Z"),
            utc("2026-10-09T07:55:35.444Z"),
        ])
    }

    func testSessionsSpanningRotatedFiles() throws {
        let analysis = try Fixture.analyze("rotation", at: "2026-10-09T12:00:00Z")

        // Signed in in the 10-07 file, warned and closed in the 10-08 file.
        let spanning = analysis.sessions[1]
        XCTAssertEqual(spanning.measuredLength ?? 0, 86_397.531, accuracy: 0.001)
        XCTAssertEqual(analysis.outcome(of: spanning), .expired)
        // Median of the two measurable sessions.
        XCTAssertEqual(analysis.sessionLength.learnedFrom, 2)
        XCTAssertEqual(analysis.sessionLength.duration, (86_397.531 + 86_399.234) / 2, accuracy: 0.001)

        let status = analysis.status(warnThreshold: 30 * 60)
        XCTAssertEqual(status.state, .active)
        XCTAssertEqualDates(status.session?.start, utc("2026-10-09T07:55:35.444Z"))
    }

    func testSignInAfterDriverRestartWithoutClientClose() throws {
        // 10-07 06:12 the driver restarts (reboot); the 06:18 login has no client
        // close before it but is still a new sign-in.
        let analysis = try Fixture.analyze("rotation", at: "2026-10-09T12:00:00Z")

        XCTAssertEqual(analysis.sessions[0].endKind, .driverRestarted)
        XCTAssertEqualDates(analysis.sessions[0].end, utc("2026-10-07T06:12:29.811Z"))
        XCTAssertEqual(analysis.outcome(of: analysis.sessions[0]), .interrupted)
        XCTAssertEqual(analysis.sessions[1].startKind, .signIn)
    }

    // MARK: Empty and unknown

    func testEmptyLogMeansNoSession() throws {
        let status = try Fixture.status("empty", at: "2026-10-10T12:00:00Z")

        XCTAssertEqual(status.state, .noSession)
        XCTAssertEqual(status.state.exitCode, 2)
        XCTAssertNil(status.session)
        XCTAssertTrue(status.sessionLength.isFallback)
    }

    func testUnknownFormatFailsLoudly() {
        XCTAssertThrowsError(try Fixture.analyze("unknown-format", at: "2026-10-10T12:00:00Z")) { error in
            guard case let GatekeeprError.unrecognizedLine(file, line, text) = error else {
                return XCTFail("expected unrecognizedLine, got \(error)")
            }
            XCTAssertEqual(file, "driver.log")
            XCTAssertEqual(line, 1)
            XCTAssertTrue(text.hasPrefix("2026-10-08 07:42:22,804 INFO"))
            XCTAssertTrue("\(error)".contains("doesn't match any known Appgate log format"))
        }
    }

    func testMissingLogDirectoryIsAnError() {
        let gatekeepr = Gatekeepr(logDirectory: Fixture.directory("does-not-exist"))
        XCTAssertThrowsError(try gatekeepr.analyze()) { error in
            guard case GatekeeprError.logDirectoryUnreadable = error else {
                return XCTFail("expected logDirectoryUnreadable, got \(error)")
            }
        }
    }
}
