import GatekeeprCore
@testable import GatekeeprMenuBar
import XCTest

final class MenuStateTests: XCTestCase {
    private func state(_ lines: [String], at now: String, warn: TimeInterval = 30 * 60) throws -> MenuState {
        let analysis = try analyze(lines, at: now)
        return MenuState(status: analysis.status(warnThreshold: warn), analysis: analysis,
                         logDirectory: "/var/log/appgate", timeZone: stockholm)
    }

    // MARK: States

    func testActive() throws {
        let state = try state(twoSessions, at: "2026-10-09T10:00:00Z")

        XCTAssertEqual(state.tone, .ok)
        XCTAssertEqual(state.title, "22h00m")
        XCTAssertEqual(state.accessibilityLabel, "Appgate session: 22h00m left")
        XCTAssertEqual(state.heading, "Appgate session active")
        XCTAssertEqual(state.details, [
            "Signed in: Fri 9 Oct 10:00",
            "Expires: Sat 10 Oct 10:00",
            "Time left: 22h00m",
            "Length: 24h00m, measured from 1 session",
        ])
        XCTAssertEqual(state.history, [
            "Fri 9 Oct 10:00 – now  active",
            "Thu 8 Oct 09:00 – Fri 9 Oct 09:00  expired, 24h00m",
        ])
    }

    func testTitleIsWhatTheCLIPrintsWithShort() throws {
        for now in ["2026-10-09T10:00:00Z", "2026-10-10T07:45:00Z", "2026-10-10T07:59:30Z", "2026-10-10T09:00:00Z"] {
            let analysis = try analyze(twoSessions, at: now)
            let status = analysis.status(warnThreshold: 30 * 60)
            let state = MenuState(status: status, analysis: analysis, logDirectory: "/x", timeZone: stockholm)
            XCTAssertEqual(state.title, StatusText.short(status), now)
        }
    }

    func testWarnWindow() throws {
        let state = try state(twoSessions, at: "2026-10-10T07:45:00Z")

        XCTAssertEqual(state.tone, .warning)
        XCTAssertEqual(state.title, "15m")
        XCTAssertEqual(state.heading, "Appgate session expires soon (warning at 30m)")
        XCTAssertEqual(try self.state(twoSessions, at: "2026-10-10T07:45:00Z", warn: 10 * 60).tone, .ok)
        XCTAssertEqual(try self.state(twoSessions, at: "2026-10-10T07:59:30Z").title, "<1m")
    }

    func testExpired() throws {
        let state = try state(twoSessions, at: "2026-10-10T09:00:00Z")

        XCTAssertEqual(state.tone, .expired)
        XCTAssertEqual(state.title, "expired")
        XCTAssertEqual(state.details[1], "Expired: Sat 10 Oct 10:00 (1h00m ago)")
        // The log just stops; the session ended when it expired.
        XCTAssertEqual(state.history.first, "Fri 9 Oct 10:00 – Sat 10 Oct 10:00  expired")
    }

    func testSignedOut() throws {
        let state = try state(twoSessions + [LogLine.clientClosed("2026-10-09T12:00:00Z")], at: "2026-10-09T13:00:00Z")

        XCTAssertEqual(state.tone, .signedOut)
        XCTAssertEqual(state.title, "signed out")
        XCTAssertEqual(state.heading, "Not signed in to Appgate")
        XCTAssertEqual(state.details, ["Last session: Fri 9 Oct 10:00", "Ended: Fri 9 Oct 14:00 (signed out)"])
        XCTAssertEqual(state.history.first, "Fri 9 Oct 10:00 – 14:00  signed out")
    }

    func testNoSession() throws {
        let state = try state([], at: "2026-10-09T13:00:00Z")

        XCTAssertEqual(state.tone, .signedOut)
        XCTAssertEqual(state.title, "no session")
        XCTAssertEqual(state.heading, "No Appgate session found in /var/log/appgate.")
        XCTAssertEqual(state.details, [])
        XCTAssertEqual(state.history, [])
    }

    // MARK: Milestone 1's extra rules, as the app sees them

    func testDriverRestartEndsTheSession() throws {
        let state = try state(twoSessions + [LogLine.driverStarted("2026-10-09T12:00:00Z")], at: "2026-10-09T13:00:00Z")

        XCTAssertEqual(state.tone, .signedOut)
        XCTAssertEqual(state.details.last, "Ended: Fri 9 Oct 14:00 (the Appgate driver restarted)")
        XCTAssertEqual(state.history.first, "Fri 9 Oct 10:00 – 14:00  interrupted")
    }

    func testNewControlConnectionEndsTheSession() throws {
        let state = try state(twoSessions + [LogLine.controlConnection("2026-10-09T12:00:00Z")], at: "2026-10-09T13:00:00Z")

        XCTAssertEqual(state.tone, .signedOut)
        XCTAssertEqual(state.details.last, "Ended: Fri 9 Oct 14:00 (the Appgate client restarted)")
    }

    func testDeployDuringTheCountdownStartsANewSession() throws {
        let lines = twoSessions + [
            LogLine.renewalNotice("2026-10-10T07:55:00Z", timeLeft: 300),
            LogLine.deploy("2026-10-10T07:57:00Z"),
        ]
        let state = try state(lines, at: "2026-10-10T09:00:00Z")

        XCTAssertEqual(state.tone, .ok)
        XCTAssertEqual(state.title, "22h57m")
        XCTAssertEqual(state.details.first, "Renewed: Sat 10 Oct 09:57")
        XCTAssertEqual(state.history.prefix(2), [
            "Sat 10 Oct 09:57 (renewed) – now  active",
            "Fri 9 Oct 10:00 – Sat 10 Oct 09:57  renewed, 24h00m",
        ])
    }

    func testDeployOutsideTheCountdownIsJustATokenRefresh() throws {
        let state = try state(twoSessions + [LogLine.deploy("2026-10-09T12:00:00Z")], at: "2026-10-09T13:00:00Z")

        XCTAssertEqual(state.details.first, "Signed in: Fri 9 Oct 10:00")
        XCTAssertEqual(state.history.count, 2)
    }

    // MARK: Errors

    func testUnparseableLogIsAnErrorNotAGuess() throws {
        let directory = try TemporaryDirectory()
        try directory.write("driver.log", lines: twoSessions + ["2026-10-09 08:00:00 INFO something new"])
        let error = try XCTUnwrap(Result { try analyze(directory.url, at: "2026-10-09T13:00:00Z") }.failure)
        let state = MenuState(error: error)

        XCTAssertEqual(state.tone, .error)
        XCTAssertEqual(state.title, "error")
        XCTAssertEqual(state.title, StatusText.shortError)
        XCTAssertEqual(state.heading, "Can't tell when the Appgate session ends")
        XCTAssertEqual(state.details.joined(separator: " "), "\(error)")
        XCTAssertTrue(state.details.allSatisfy { $0.count <= MenuState.lineWidth }, "\(state.details)")
        XCTAssertTrue(state.details[0].hasPrefix("driver.log:8: this line doesn't match"), state.details[0])
        XCTAssertEqual(state.history, [])
    }

    func testMissingLogDirectoryIsAnError() throws {
        let missing = URL(fileURLWithPath: "/nonexistent/appgate", isDirectory: true)
        let error = try XCTUnwrap(Result { try Gatekeepr(logDirectory: missing).analyze() }.failure)
        let state = MenuState(error: error)

        XCTAssertEqual(state.tone, .error)
        XCTAssertEqual(state.details.joined(separator: " "), "\(error)")
        XCTAssertTrue(state.details[0].hasPrefix("can't read the log directory /nonexistent/appgate:"), state.details[0])
    }

    func testHistoryIsLimited() throws {
        var lines: [String] = []
        for day in 1...14 {
            let date = String(format: "2026-09-%02d", day)
            lines += LogLine.signIn("\(date)T08:00:00Z") + [LogLine.clientClosed("\(date)T17:00:00Z")]
        }
        let state = try state(lines, at: "2026-09-15T12:00:00Z")

        XCTAssertEqual(state.history.count, MenuState.historyLimit)
        XCTAssertEqual(state.history.first, "Mon 14 Sep 10:00 – 19:00  signed out")
    }

    // MARK: Helpers

    func testWrap() {
        XCTAssertEqual(MenuState.wrap("one two three four", width: 9), ["one two", "three", "four"])
        XCTAssertEqual(MenuState.wrap("a muchtoolongword b", width: 5), ["a", "muchtoolongword", "b"])
        XCTAssertEqual(MenuState.wrap("", width: 5), [])
    }

    func testRefreshDelayLandsJustAfterTheDisplayedMinuteChanges() {
        XCTAssertEqual(MenuState.refreshDelay(timeLeft: nil), 60)
        XCTAssertEqual(MenuState.refreshDelay(timeLeft: -30), 60)
        // 2m05s left shows "2m" until 2m00s, 5 s from now.
        XCTAssertEqual(MenuState.refreshDelay(timeLeft: 125), 5.05, accuracy: 0.001)
        XCTAssertEqual(MenuState.refreshDelay(timeLeft: 60), 0.05, accuracy: 0.001)
        XCTAssertEqual(MenuState.refreshDelay(timeLeft: 59.5), 59.55, accuracy: 0.001)
        // 30m30s left with a 30m threshold: the next tick is the one that enters the window.
        XCTAssertEqual(MenuState.refreshDelay(timeLeft: 30 * 60 + 30), 30.05, accuracy: 0.001)
    }
}

extension Result {
    var failure: Failure? {
        if case let .failure(error) = self { return error }
        return nil
    }
}
