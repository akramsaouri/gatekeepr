import XCTest
@testable import GatekeeprCore

final class ReportTests: XCTestCase {
    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testStatusReport() throws {
        let status = try Fixture.status("normal-day", at: "2026-10-09T12:00:00Z")
        let report = try json(JSONReport.encode(StatusReport(status), timeZone: TimeZone(identifier: "Europe/Stockholm")!))

        XCTAssertEqual(report["state"] as? String, "active")
        XCTAssertEqual(report["exitCode"] as? Int, 0)
        XCTAssertEqual(report["now"] as? String, "2026-10-09T14:00:00+02:00")
        XCTAssertEqual(report["sessionStart"] as? String, "2026-10-09T09:55:35+02:00")
        XCTAssertEqual(report["sessionStartKind"] as? String, "signIn")
        XCTAssertEqual(report["expiresAt"] as? String, "2026-10-10T09:55:34+02:00")
        XCTAssertEqual(report["expirySource"] as? String, "sessionLength")
        XCTAssertEqual(report["secondsLeft"] as? Int, 19 * 3600 + 55 * 60 + 34)
        XCTAssertEqual(report["timeLeft"] as? String, "19h55m")
        XCTAssertEqual(report["warnThresholdSeconds"] as? Int, 1800)
        XCTAssertEqual(report["sessionLengthSeconds"] as? Int, 86_399)
        XCTAssertEqual(report["sessionLengthLearnedFrom"] as? Int, 1)
        XCTAssertNil(report["sessionEnd"])
    }

    func testStatusReportWithNoSession() throws {
        let status = try Fixture.status("empty", at: "2026-10-10T12:00:00Z")
        let report = try json(JSONReport.encode(StatusReport(status), timeZone: TimeZone(identifier: "UTC")!))

        XCTAssertEqual(report["state"] as? String, "noSession")
        XCTAssertEqual(report["exitCode"] as? Int, 2)
        XCTAssertNil(report["expiresAt"])
        XCTAssertEqual(report["sessionLengthLearnedFrom"] as? Int, 0)
    }

    func testHistoryReport() throws {
        let analysis = try Fixture.analyze("renewal", at: "2026-09-12T08:00:00Z")
        let report = try json(JSONReport.encode(HistoryReport(analysis), timeZone: TimeZone(identifier: "UTC")!))
        let sessions = try XCTUnwrap(report["sessions"] as? [[String: Any]])

        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0]["start"] as? String, "2026-09-10T07:36:27Z")
        XCTAssertEqual(sessions[0]["outcome"] as? String, "renewed")
        XCTAssertEqual(sessions[0]["endKind"] as? String, "renewed")
        XCTAssertEqual(sessions[0]["reconnects"] as? Int, 4)
        XCTAssertEqual(sessions[1]["startKind"] as? String, "renewal")
        XCTAssertEqual(sessions[1]["outcome"] as? String, "expired")
        XCTAssertEqual(sessions[1]["measuredLengthSeconds"] as? Int, 86_399)
        XCTAssertEqual(report["sessionLengthLearnedFrom"] as? Int, 2)
    }
}
