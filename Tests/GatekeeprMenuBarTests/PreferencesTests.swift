@testable import GatekeeprMenuBar
import XCTest

final class PreferencesTests: XCTestCase {
    func testWarnThresholdDefaultsTo30MinutesAndPersists() {
        let scratch = ScratchDefaults()
        let preferences = Preferences(defaults: scratch.defaults)
        XCTAssertEqual(preferences.warnThreshold, 30 * 60)

        preferences.warnThreshold = 60 * 60
        XCTAssertEqual(Preferences(defaults: scratch.defaults).warnThreshold, 60 * 60)
    }

    func testOutOfRangeWarnThresholdFallsBackToTheDefault() {
        let scratch = ScratchDefaults()
        let preferences = Preferences(defaults: scratch.defaults)
        for bad: Any in [0, -60, 30, 25 * 60 * 60, "30m"] {
            scratch.defaults.set(bad, forKey: Preferences.Key.warnThreshold)
            XCTAssertEqual(preferences.warnThreshold, 30 * 60, "\(bad)")
        }
        scratch.defaults.set(90, forKey: Preferences.Key.warnThreshold)
        XCTAssertEqual(preferences.warnThreshold, 90)
    }

    func testLedgerPersists() {
        let scratch = ScratchDefaults()
        let start = utc("2026-10-09T07:55:35.444Z")
        Preferences(defaults: scratch.defaults).ledger = NotificationLedger(warnedSession: start)

        let reloaded = Preferences(defaults: scratch.defaults)
        XCTAssertEqual(reloaded.ledger, NotificationLedger(warnedSession: start, expiredSession: nil))
        // Exactly, not just to the second: it's compared with the session start.
        XCTAssertEqual(reloaded.ledger.warnedSession?.timeIntervalSince1970, start.timeIntervalSince1970)

        reloaded.ledger = NotificationLedger()
        XCTAssertEqual(Preferences(defaults: scratch.defaults).ledger, NotificationLedger())
        XCTAssertNil(scratch.defaults.object(forKey: Preferences.Key.warnedSession))
    }

    func testChoicesKeepACustomValue() {
        XCTAssertEqual(Preferences.warnThresholdChoices(including: 30 * 60), Preferences.warnThresholdChoices)
        let withCustom = Preferences.warnThresholdChoices(including: 20 * 60)
        XCTAssertEqual(withCustom.count, Preferences.warnThresholdChoices.count + 1)
        XCTAssertEqual(withCustom, withCustom.sorted())
        XCTAssertTrue(withCustom.contains(20 * 60))
        XCTAssertTrue(Preferences.warnThresholdChoices.contains(Preferences.defaultWarnThreshold))
    }

    func testLogDirectoryDefaultsToAppgatesAndCanBeOverridden() {
        let scratch = ScratchDefaults()
        let preferences = Preferences(defaults: scratch.defaults)
        XCTAssertEqual(preferences.logDirectory.path, "/var/log/appgate")

        scratch.defaults.set("/tmp/appgate-logs", forKey: Preferences.Key.logDirectory)
        XCTAssertEqual(preferences.logDirectory.path, "/tmp/appgate-logs")
        scratch.defaults.set("~/logs", forKey: Preferences.Key.logDirectory)
        XCTAssertEqual(preferences.logDirectory.path, NSHomeDirectory() + "/logs")
        scratch.defaults.set("", forKey: Preferences.Key.logDirectory)
        XCTAssertEqual(preferences.logDirectory.path, "/var/log/appgate")
    }

    func testLabels() {
        XCTAssertEqual(Preferences.label(forWarnThreshold: 60), "1 minute")
        XCTAssertEqual(Preferences.label(forWarnThreshold: 5 * 60), "5 minutes")
        XCTAssertEqual(Preferences.label(forWarnThreshold: 60 * 60), "1 hour")
        XCTAssertEqual(Preferences.label(forWarnThreshold: 2 * 60 * 60), "2 hours")
        XCTAssertEqual(Preferences.label(forWarnThreshold: 90 * 60), "1h30m")
        XCTAssertEqual(Preferences.label(forWarnThreshold: 90), "1m")
    }
}
