import Foundation
import GatekeeprCore
@testable import GatekeeprMenuBar
import XCTest

/// `2026-10-09T08:00:00Z` or `2026-10-09T07:55:35.444Z` as a Date.
func utc(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = text.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
    guard let date = formatter.date(from: text) else {
        XCTFail("bad test date \(text)", file: file, line: line)
        return Date(timeIntervalSince1970: 0)
    }
    return date
}

let stockholm = TimeZone(identifier: "Europe/Stockholm")!

/// Driver log lines in the shapes Appgate client 6.5.3 writes them (see the
/// sanitized fixtures in GatekeeprCoreTests), so tests go through the real parser.
enum LogLine {
    static func login(_ time: String, site: String = "AWS") -> String {
        line(time, #"Got request from client <{"jsonrpc":"2.0","method":"send-to","params":{"id":"staticid","site-id":"\#(site)","message":{"jsonrpc":"2.0","id":2,"method":"login","params":{"claimsToken":"*","version":4}}}}>"#)
    }

    /// A sign-in: one login per site, a moment apart.
    static func signIn(_ time: String) -> [String] {
        [login(time, site: "AWS"), login(time, site: "GCP")]
    }

    static func renewalNotice(_ time: String, timeLeft: Int = 300) -> String {
        line(time, #"Sending reply to client <{ "jsonrpc": "2.0", "method": "send-to", "params": { "id": "staticid", "site-id": "GCP", "message": {"method":"token-renewal-notification","params":{"id":"00000000-0000-4000-8000-000000000001","timeLeft":\#(timeLeft)},"jsonrpc":"2.0"} }}>"#)
    }

    static func clientClosed(_ time: String) -> String {
        line(time, "Client closed control connection")
    }

    static func controlConnection(_ time: String) -> String {
        line(time, "Got control connection")
    }

    static func driverStarted(_ time: String) -> String {
        line(time, "Starting event loop")
    }

    static func deploy(_ time: String) -> String {
        line(time, #"Got request from client <{"jsonrpc":"2.0","id":3,"method":"deploy","params":{"clientp12":"*"}}>"#)
    }

    static func noise(_ time: String) -> String {
        line(time, "[AWS] New rules in place")
    }

    /// `2026-10-09T08:00:00Z` → `[2026-10-09T08:00:00.000Z] Info : message`.
    private static func line(_ time: String, _ message: String) -> String {
        let stamp = time.contains(".") ? time : time.replacingOccurrences(of: "Z", with: ".000Z")
        return "[\(stamp)] Info : \(message)"
    }
}

/// A two-session history. The first session was measured at exactly 24h (its
/// renewal notice came 23h55m in, with 300 s left) and expired; the second
/// signed in at 08:00 UTC on 9 Oct and so expires at 08:00 UTC on 10 Oct.
let twoSessions: [String] =
    LogLine.signIn("2026-10-08T07:00:00Z")
    + [LogLine.noise("2026-10-08T12:00:00Z"),
       LogLine.renewalNotice("2026-10-09T06:55:00Z", timeLeft: 300),
       LogLine.clientClosed("2026-10-09T07:00:00Z")]
    + LogLine.signIn("2026-10-09T08:00:00Z")

/// A scratch directory that is removed at the end of the test.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gatekeepr-menubar-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func path(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    func write(_ name: String, lines: [String]) throws {
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: path(name))
    }

    func append(_ name: String, lines: [String]) throws {
        let handle = try FileHandle(forWritingTo: path(name))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(lines.map { $0 + "\n" }.joined().utf8))
    }
}

/// UserDefaults that start empty and are thrown away after the test.
final class ScratchDefaults {
    let suiteName = "gatekeepr-tests-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

/// Reads a log directory as it was at `now`.
func analyze(_ directory: URL, at now: String) throws -> Analysis {
    let date = utc(now)
    return try Gatekeepr(logDirectory: directory, clock: { date }).analyze()
}

/// Reads a log written from `lines` as it was at `now`.
func analyze(_ lines: [String], at now: String) throws -> Analysis {
    let directory = try TemporaryDirectory()
    try directory.write("driver.log", lines: lines)
    return try analyze(directory.url, at: now)
}

final class FakeNotifier: SessionNotifier {
    private(set) var posted: [SessionNotification] = []
    private(set) var withdrawals = 0

    func post(_ notification: SessionNotification) {
        posted.append(notification)
    }

    func withdrawAll() {
        withdrawals += 1
    }
}
