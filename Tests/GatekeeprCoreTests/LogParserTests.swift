import XCTest
@testable import GatekeeprCore

final class LogParserTests: XCTestCase {
    // Sanitized lines in the shape Appgate client 6.5.3 writes them.
    let login = #"[2026-10-10T23:24:41.741Z] Info : Got request from client <{"jsonrpc":"2.0","method":"send-to","params":{"id":"staticid","site-id":"AWS","message":{"jsonrpc":"2.0","id":2,"method":"login","params":{"claimsToken":"*","entitlementToken":"*","untrustedClaimsToken":"*","version":4}}}}>"#
    let updateTokens = #"[2026-10-11T00:20:41.900Z] Info : Got request from client <{"jsonrpc":"2.0","method":"send-to","params":{"id":"staticid","site-id":"GCP","message":{"jsonrpc":"2.0","id":3,"method":"update-tokens","params":{"claimsToken":"*","entitlementToken":"*","untrustedClaimsToken":"*","version":4}}}}>"#
    let deploy = #"[2026-10-10T23:24:41.129Z] Info : Got request from client <{"jsonrpc":"2.0","id":3,"method":"deploy","params":{"clientp12":"*","cacert":"*","sites":[],"id":"staticid"}}>"#
    let renewal = #"[2026-10-11T23:19:40.100Z] Info : Sending reply to client <{ "jsonrpc": "2.0", "method": "send-to", "params": { "id": "staticid", "site-id": "GCP", "message": {"method":"token-renewal-notification","params":{"id":"00000000-0000-4000-8000-000000000001","timeLeft":300},"jsonrpc":"2.0"} }}>"#
    let revocation = #"[2026-09-29T07:02:21.915Z] Info : Sending reply to client <{ "jsonrpc": "2.0", "method": "send-to", "params": { "id": "staticid", "site-id": "AWS", "message": {"method":"token-revocation","params":{"id":"00000000-0000-4000-8000-000000000003","timeLeft":300},"jsonrpc":"2.0"} }}>"#
    let status = #"[2026-10-10T23:24:30.939Z] Info : Sending reply to client <{ "jsonrpc": "2.0", "method": "status", "params": { "id": "staticid", "ip4": "198.18.0.1", "sites": { "AWS": {"gw-id": "sdp-gw2-aws", "status": "down", "error": "Disconnected by gateway", "code": 108}} }}>"#

    func events(_ lines: [String]) throws -> [LogEvent.Kind] {
        try LogParser.events(in: lines.joined(separator: "\n") + "\n", file: "driver.log").map(\.kind)
    }

    func testTimestampsAreUTC() throws {
        let events = try LogParser.events(in: login + "\n", file: "driver.log")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqualDates(events[0].date, utc("2026-10-10T23:24:41.741Z"))
        XCTAssertEqual(events[0].file, "driver.log")
        XCTAssertEqual(events[0].line, 1)
    }

    func testSessionEvents() throws {
        XCTAssertEqual(try events([
            "[2026-10-10T23:24:34.000Z] Info : Client closed control connection",
            "[2026-10-10T23:24:34.009Z] Info : [AWS] [] Closing *:0 (Client closed control connection)",
            "[2026-10-10T23:24:34.025Z] Info : [GCP] [] Closing *:51997 (Client closed control connection)",
            "[2026-10-10T23:24:41.117Z] Info : Got control connection",
            deploy,
            login,
            renewal,
            "[2026-10-07T06:12:29.811Z] Info : Starting event loop",
            "[2026-09-28T07:08:40.000Z] Info : Stopping event loop (killed by: 1|/sbin/launchd signo/code: 15/0)",
        ]), [
            .clientClosed, .clientClosed, .clientClosed, .clientConnected, .deploy,
            .login(site: "AWS"), .renewalNotification(timeLeft: 300), .driverRestarted, .driverRestarted,
        ])
    }

    func testNoiseIsIgnored() throws {
        XCTAssertEqual(try events([
            updateTokens,
            revocation,
            status,
            "[2026-10-10T23:24:43.100Z] Info : All sites connected in 2114ms",
            "[2026-10-10T23:24:43.200Z] Info : [netstat -nrv] Destination        Gateway            Flags               Netif Expire",
            "[2026-10-10T23:24:30.906Z] Info : [AWS] [sdp-gw2-aws] Closing *:51996 (Disconnected by gateway)",
            "[2026-10-11T00:00:41.264Z] Info : [GCP] [sdp-gw1-gcp] Closing *:54680 (Dead connection detected)",
            "[2026-09-10T06:30:37.048Z] Info : Closing VPNs: IP address change",
            "[2026-09-10T06:30:39.096Z] Warn : [AWS] [AWS] Failed to connect SPA-UDP socket: Network is unreachable",
            "[2026-10-10T23:24:41.700Z] Info : [AWS] [sdp-gw2-aws] Connected *:50836 --> TLSv1.3://198.18.0.2:443, server version: 6.5.6-45324",
            "[2026-10-10T23:24:41.800Z] Info : ",
        ]), [])
    }

    func testCRLFLineEndings() throws {
        let events = try LogParser.events(in: login + "\r\n" + renewal + "\r\n", file: "driver.log")
        XCTAssertEqual(events.map(\.kind), [.login(site: "AWS"), .renewalNotification(timeLeft: 300)])
    }

    func testHalfWrittenLastLineIsSkipped() throws {
        let events = try LogParser.events(in: login + "\n[2026-10-11T00:0", file: "driver.log")
        XCTAssertEqual(events.map(\.kind), [.login(site: "AWS")])
    }

    func testCompleteLastLineWithoutNewlineIsParsed() throws {
        XCTAssertEqual(try LogParser.events(in: login, file: "driver.log").map(\.kind), [.login(site: "AWS")])
    }

    func testUnknownLineFailsWithItsLocation() {
        let text = [login, "Oct 10 23:24:41 appgate-driver[123]: Got control connection", renewal].joined(separator: "\n")
        XCTAssertThrowsError(try LogParser.events(in: text, file: "driver-2026-10-10.log.gz")) { error in
            XCTAssertEqual(error as? GatekeeprError, .unrecognizedLine(
                file: "driver-2026-10-10.log.gz", line: 2,
                text: "Oct 10 23:24:41 appgate-driver[123]: Got control connection"
            ))
        }
    }

    func testRenewalNotificationWithoutTimeLeftFails() {
        let broken = renewal.replacingOccurrences(of: #""timeLeft":300"#, with: #""secondsLeft":300"#)
        assertUnrecognizedEvent([login, broken], line: 2, reason: "no usable timeLeft")
    }

    func testRenewalNotificationInAnotherShapeFails() {
        let broken = "[2026-10-11T23:19:40.100Z] Info : token-renewal-notification in 300 seconds"
        assertUnrecognizedEvent([broken], line: 1, reason: "isn't the expected send-to reply")
    }

    func testLoginThatIsNotJSONFails() {
        let broken = String(login.dropLast(5)) + ">"
        assertUnrecognizedEvent([broken], line: 1, reason: "isn't valid JSON")
    }

    func testLoginOutsideSendToFails() {
        let unwrapped = #"[2026-10-10T23:24:41.741Z] Info : Got request from client <{"jsonrpc":"2.0","id":2,"method":"login","params":{"claimsToken":"*"}}>"#
        assertUnrecognizedEvent([unwrapped], line: 1, reason: "isn't wrapped in send-to")
    }

    func testCloseInAnotherShapeFails() {
        let broken = "[2026-10-10T23:24:34.009Z] Info : [AWS] [] Closing *:? Client closed control connection"
        assertUnrecognizedEvent([broken], line: 1, reason: "connection close doesn't look like")
    }

    func testImpossibleDateOnAnEventFails() {
        let broken = login.replacingOccurrences(of: "2026-10-10T23", with: "2026-02-30T23")
        assertUnrecognizedEvent([broken], line: 1, reason: "isn't a real date")
    }

    func testCloseReason() {
        XCTAssertEqual(LogParser.closeReason("[AWS] [sdp-gw1-aws] Closing *:54679 (Disconnected by gateway)"), "Disconnected by gateway")
        XCTAssertEqual(LogParser.closeReason("[AWS] [] Closing *:0 (Client closed control connection)"), "Client closed control connection")
        XCTAssertEqual(LogParser.closeReason("[GCP] [sdp-gw1-gcp] Closing *:0 (Failed to connect: Failed to send SPA UDP packet)"), "Failed to connect: Failed to send SPA UDP packet")
        XCTAssertNil(LogParser.closeReason("Closing VPNs: IP address change"))
    }

    private func assertUnrecognizedEvent(_ lines: [String], line: Int, reason: String,
                                         file: StaticString = #filePath, testLine: UInt = #line) {
        XCTAssertThrowsError(try events(lines), file: file, line: testLine) { error in
            guard case let GatekeeprError.unrecognizedEvent(_, actualLine, _, actualReason) = error else {
                return XCTFail("expected unrecognizedEvent, got \(error)", file: file, line: testLine)
            }
            XCTAssertEqual(actualLine, line, file: file, line: testLine)
            XCTAssertTrue(actualReason.contains(reason), "\(actualReason)", file: file, line: testLine)
        }
    }
}
