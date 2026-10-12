import Foundation
import XCTest
@testable import GatekeeprCore

/// `2026-10-09T12:00:00Z` or `2026-10-09T07:55:35.444Z` as a Date.
func utc(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = text.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
    guard let date = formatter.date(from: text) else {
        XCTFail("bad test date \(text)", file: file, line: line)
        return Date(timeIntervalSince1970: 0)
    }
    return date
}

func XCTAssertEqualDates(_ actual: Date?, _ expected: Date, accuracy: TimeInterval = 0.001,
                         file: StaticString = #filePath, line: UInt = #line) {
    guard let actual else {
        XCTFail("date is nil, expected \(expected)", file: file, line: line)
        return
    }
    XCTAssertEqual(actual.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: accuracy,
                   "\(actual) is not \(expected)", file: file, line: line)
}

/// Log directories under Tests/GatekeeprCoreTests/Fixtures. Each one is a
/// sanitized, trimmed excerpt of a real /var/log/appgate (see Fixtures/README.md).
enum Fixture {
    static var root: URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
    }

    static func directory(_ name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    /// The fixture as it would have looked at `now`: later lines are ignored.
    static func analyze(_ name: String, at now: String) throws -> Analysis {
        let date = utc(now)
        return try Gatekeepr(logDirectory: directory(name), clock: { date }).analyze()
    }

    static func status(_ name: String, at now: String, warn: TimeInterval = 30 * 60) throws -> Status {
        try analyze(name, at: now).status(warnThreshold: warn)
    }
}

/// A scratch directory that is removed at the end of the test.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gatekeepr-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: url.appendingPathComponent(name))
    }

    func write(_ name: String, _ data: Data) throws {
        try data.write(to: url.appendingPathComponent(name))
    }
}
