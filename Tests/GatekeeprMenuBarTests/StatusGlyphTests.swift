import GatekeeprCore
@testable import GatekeeprMenuBar
import XCTest

final class StatusGlyphTests: XCTestCase {
    private let day: TimeInterval = 24 * 60 * 60

    private func glyph(_ lines: [String], at now: String) throws -> StatusGlyph {
        let analysis = try analyze(lines, at: now)
        return MenuState(status: analysis.status(warnThreshold: 30 * 60), analysis: analysis,
                         logDirectory: "/var/log/appgate", timeZone: stockholm).glyph
    }

    /// How much of the ring is filled, or nil if it isn't a draining ring.
    private func fraction(_ glyph: StatusGlyph) -> Double? {
        guard case let .ring(fraction) = glyph.shape else { return nil }
        return fraction
    }

    // MARK: Progress

    func testProgressIsTheFractionOfTheSessionLeft() {
        XCTAssertEqual(StatusGlyph.progress(timeLeft: day, sessionLength: day), 1)
        XCTAssertEqual(StatusGlyph.progress(timeLeft: 18 * 60 * 60, sessionLength: day), 0.75)
        XCTAssertEqual(StatusGlyph.progress(timeLeft: 0, sessionLength: day), 0)
    }

    func testProgressIsClampedToZeroThroughOne() {
        // Expired: the time left is negative.
        XCTAssertEqual(StatusGlyph.progress(timeLeft: -60 * 60, sessionLength: day), 0)
        // More left than the learned length, as after a clock change.
        XCTAssertEqual(StatusGlyph.progress(timeLeft: day + 60, sessionLength: day), 1)
        XCTAssertEqual(StatusGlyph.progress(timeLeft: .infinity, sessionLength: day), 1)
    }

    func testProgressWithAZeroOrUnknownSessionLengthIsNil() {
        XCTAssertNil(StatusGlyph.progress(timeLeft: 60 * 60, sessionLength: 0))
        XCTAssertNil(StatusGlyph.progress(timeLeft: 60 * 60, sessionLength: -1))
        XCTAssertNil(StatusGlyph.progress(timeLeft: 60 * 60, sessionLength: nil))
        XCTAssertNil(StatusGlyph.progress(timeLeft: 60 * 60, sessionLength: .nan))
        XCTAssertNil(StatusGlyph.progress(timeLeft: 60 * 60, sessionLength: .infinity))
        // No session, so no expiry.
        XCTAssertNil(StatusGlyph.progress(timeLeft: nil, sessionLength: day))
        XCTAssertNil(StatusGlyph.progress(timeLeft: .nan, sessionLength: day))
    }

    // MARK: Tone → style

    func testEachToneHasItsOwnStyle() {
        XCTAssertEqual(StatusGlyph(tone: .ok, progress: 0.5), StatusGlyph(shape: .ring(fraction: 0.5), ink: .menuBar))
        XCTAssertEqual(StatusGlyph(tone: .warning, progress: 0.01), StatusGlyph(shape: .ring(fraction: 0.01), ink: .orange))
        XCTAssertEqual(StatusGlyph(tone: .expired, progress: 0), StatusGlyph(shape: .crossedRing, ink: .red))
        XCTAssertEqual(StatusGlyph(tone: .signedOut, progress: 0.4), StatusGlyph(shape: .dashedTrack, ink: .menuBar))
        XCTAssertEqual(StatusGlyph(tone: .error, progress: nil), StatusGlyph(shape: .warningTriangle, ink: .red))
    }

    func testUnknownProgressDrawsTheTrackAlone() {
        XCTAssertEqual(StatusGlyph(tone: .ok, progress: nil), StatusGlyph(shape: .ring(fraction: nil), ink: .menuBar))
        XCTAssertEqual(StatusGlyph(tone: .warning, progress: nil).shape, .ring(fraction: nil))
        XCTAssertEqual(MenuState.loading.glyph, StatusGlyph(shape: .ring(fraction: nil), ink: .menuBar))
    }

    // MARK: From the logs

    func testRingDrainsOverTheSession() throws {
        // The second session signed in at 08:00 UTC on 9 Oct; its length was learned as 24h.
        XCTAssertEqual(try XCTUnwrap(fraction(glyph(twoSessions, at: "2026-10-09T08:00:00Z"))), 1)
        XCTAssertEqual(try XCTUnwrap(fraction(glyph(twoSessions, at: "2026-10-09T10:00:00Z"))), 22.0 / 24, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(fraction(glyph(twoSessions, at: "2026-10-10T02:00:00Z"))), 0.25, accuracy: 1e-9)
        XCTAssertEqual(try glyph(twoSessions, at: "2026-10-10T02:00:00Z").ink, .menuBar)
    }

    func testRingTurnsOrangeInTheWarnWindow() throws {
        let glyph = try glyph(twoSessions, at: "2026-10-10T07:45:00Z")

        XCTAssertEqual(glyph.ink, .orange)
        XCTAssertEqual(try XCTUnwrap(fraction(glyph)), 15.0 / (24 * 60), accuracy: 1e-9)
    }

    func testRingFollowsTheGatewayCountdown() throws {
        // A renewal notice wins over the learned length: 3 of the last 5 minutes are left.
        let lines = twoSessions + [LogLine.renewalNotice("2026-10-10T07:55:00Z", timeLeft: 300)]
        let glyph = try glyph(lines, at: "2026-10-10T07:57:00Z")

        XCTAssertEqual(glyph.ink, .orange)
        XCTAssertEqual(try XCTUnwrap(fraction(glyph)), 180 / day, accuracy: 1e-9)
    }

    func testExpiredSignedOutNoSessionAndError() throws {
        XCTAssertEqual(try glyph(twoSessions, at: "2026-10-10T09:00:00Z"), StatusGlyph(shape: .crossedRing, ink: .red))
        let signedOut = twoSessions + [LogLine.clientClosed("2026-10-09T12:00:00Z")]
        XCTAssertEqual(try glyph(signedOut, at: "2026-10-09T13:00:00Z"), StatusGlyph(shape: .dashedTrack, ink: .menuBar))
        XCTAssertEqual(try glyph([], at: "2026-10-09T13:00:00Z"), StatusGlyph(shape: .dashedTrack, ink: .menuBar))
        let missing = URL(fileURLWithPath: "/nonexistent/appgate", isDirectory: true)
        let error = try XCTUnwrap(Result { try Gatekeepr(logDirectory: missing).analyze() }.error)
        XCTAssertEqual(MenuState(error: error).glyph, StatusGlyph(shape: .warningTriangle, ink: .red))
    }
}
