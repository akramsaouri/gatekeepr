import Combine
import GatekeeprCore
@testable import GatekeeprMenuBar
import XCTest

@MainActor
final class StatusModelTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private var scratch: ScratchDefaults!
    private var clock: TestClock!

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
        try directory.write("driver.log", lines: twoSessions)
        scratch = ScratchDefaults()
        clock = TestClock(utc("2026-10-10T07:20:00Z"))
    }

    private func makeModel(_ notifier: FakeNotifier) -> StatusModel {
        StatusModel(logDirectory: directory.url, preferences: Preferences(defaults: scratch.defaults),
                    notifier: notifier, clock: clock.read, timeZone: stockholm)
    }

    private var read: Result<Analysis, Error> {
        let clock = clock!
        return Result { try Gatekeepr(logDirectory: directory.url, clock: clock.read).analyze() }
    }

    func testStartsLoading() {
        XCTAssertEqual(makeModel(FakeNotifier()).state, .loading)
    }

    func testWarnsOncePerSessionAcrossTicksAndRelaunches() {
        let notifier = FakeNotifier()
        let model = makeModel(notifier)
        model.receive(read, generation: 1)
        XCTAssertEqual(model.state.tone, .ok)
        XCTAssertEqual(model.state.title, "40m")
        XCTAssertEqual(notifier.posted, [])

        clock.now = utc("2026-10-10T07:30:00.050Z")
        model.evaluate()
        XCTAssertEqual(model.state.tone, .warning)
        XCTAssertEqual(notifier.posted.map(\.kind), [.warning])

        clock.now = utc("2026-10-10T07:45:00Z")
        model.evaluate()
        XCTAssertEqual(model.state.title, "15m")
        XCTAssertEqual(notifier.posted.count, 1)

        // Relaunch: a fresh model reading the same preferences doesn't warn again.
        let relaunchedNotifier = FakeNotifier()
        let relaunched = makeModel(relaunchedNotifier)
        relaunched.receive(read, generation: 1)
        XCTAssertEqual(relaunched.state.tone, .warning)
        XCTAssertEqual(relaunchedNotifier.posted, [])

        // But it does say when the session expires, once.
        clock.now = utc("2026-10-10T08:00:00.050Z")
        relaunched.evaluate()
        XCTAssertEqual(relaunched.state.tone, .expired)
        XCTAssertEqual(relaunchedNotifier.posted.map(\.kind), [.expired])
        relaunched.evaluate()
        XCTAssertEqual(relaunchedNotifier.posted.count, 1)
    }

    func testChangingTheThresholdPersistsAndCanWarnStraightAway() {
        let notifier = FakeNotifier()
        let model = makeModel(notifier)
        model.receive(read, generation: 1)
        XCTAssertEqual(model.state.tone, .ok)

        model.warnThreshold = 60 * 60
        XCTAssertEqual(Preferences(defaults: scratch.defaults).warnThreshold, 60 * 60)
        XCTAssertEqual(model.state.tone, .warning)
        XCTAssertEqual(model.state.heading, "Appgate session expires soon (warning at 1h00m)")
        XCTAssertEqual(notifier.posted.map(\.kind), [.warning])

        // Back down and up again: still only one warning for this session.
        model.warnThreshold = 5 * 60
        XCTAssertEqual(model.state.tone, .ok)
        model.warnThreshold = 60 * 60
        XCTAssertEqual(notifier.posted.count, 1)

        XCTAssertEqual(makeModel(FakeNotifier()).warnThreshold, 60 * 60)
    }

    func testAnErrorReplacesTheLastGoodAnswer() throws {
        let model = makeModel(FakeNotifier())
        model.receive(read, generation: 1)
        XCTAssertEqual(model.state.tone, .ok)

        model.receive(.failure(GatekeeprError.noLogFiles(path: "/var/log/appgate")), generation: 2)
        XCTAssertEqual(model.state.tone, .error)
        XCTAssertEqual(model.state.title, "error")
        XCTAssertEqual(model.state.details.joined(separator: " "), "no driver.log or driver-YYYY-MM-DD.log.gz files in /var/log/appgate")
        XCTAssertEqual(model.state.history, [])

        // Ticking doesn't bring the old answer back either.
        clock.now = utc("2026-10-10T07:31:00Z")
        model.evaluate()
        XCTAssertEqual(model.state.tone, .error)

        model.receive(read, generation: 3)
        XCTAssertEqual(model.state.tone, .warning)
    }

    func testALateOlderReadIsDropped() throws {
        let model = makeModel(FakeNotifier())
        let older = read
        try directory.append("driver.log", lines: [LogLine.clientClosed("2026-10-10T07:10:00Z")])
        model.receive(read, generation: 2)
        XCTAssertEqual(model.state.tone, .signedOut)

        model.receive(older, generation: 1)
        XCTAssertEqual(model.state.tone, .signedOut)
    }

    func testANewSessionWithdrawsOldNotifications() throws {
        let notifier = FakeNotifier()
        let model = makeModel(notifier)
        clock.now = utc("2026-10-10T07:40:00Z")
        model.receive(read, generation: 1)
        XCTAssertEqual(notifier.posted.map(\.kind), [.warning])
        XCTAssertEqual(notifier.withdrawals, 0)

        // Renewed from Appgate's warning.
        try directory.append("driver.log", lines: [
            LogLine.renewalNotice("2026-10-10T07:55:00Z", timeLeft: 300),
            LogLine.deploy("2026-10-10T07:57:00Z"),
        ])
        clock.now = utc("2026-10-10T07:58:00Z")
        model.receive(read, generation: 2)
        XCTAssertEqual(model.state.tone, .ok)
        XCTAssertEqual(model.state.details.first, "Renewed: Sat 10 Oct 09:57")
        XCTAssertEqual(notifier.withdrawals, 1)

        model.evaluate()
        XCTAssertEqual(notifier.withdrawals, 1)
    }

    /// End to end: the real watcher and loader, following driver.log as it's
    /// written to and rotated.
    func testFollowsTheLogs() async throws {
        clock.now = utc("2026-10-09T13:00:00Z")
        let model = makeModel(FakeNotifier())
        model.start()
        defer { model.stop() }
        await waitForState(model) { $0.tone == .ok && $0.title == "19h00m" }

        try directory.append("driver.log", lines: [LogLine.clientClosed("2026-10-09T12:00:00Z")])
        await waitForState(model) { $0.tone == .signedOut }

        // Rotation, then a new sign-in in the new driver.log.
        try FileManager.default.moveItem(at: directory.path("driver.log"), to: directory.path("driver-2026-10-09.log"))
        try directory.write("driver.log", lines: LogLine.signIn("2026-10-09T12:30:00Z"))
        await waitForState(model) { $0.tone == .ok && $0.title == "23h30m" }
        XCTAssertEqual(model.state.history.count, 3)
    }

    private func waitForState(_ model: StatusModel, timeout: TimeInterval = 5, _ predicate: @escaping (MenuState) -> Bool) async {
        let expectation = expectation(description: "menu state")
        expectation.assertForOverFulfill = false
        let subscription = model.$state.sink { if predicate($0) { expectation.fulfill() } }
        await fulfillment(of: [expectation], timeout: timeout)
        subscription.cancel()
    }
}

/// A clock the test moves by hand. The model reads it from the log queue too.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ date: Date) {
        value = date
    }

    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }

    var read: @Sendable () -> Date {
        { [self] in now }
    }
}
