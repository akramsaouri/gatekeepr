import XCTest
@testable import GatekeeprCore

final class LogDirectoryTests: XCTestCase {
    private func fixtureData(_ path: String) throws -> Data {
        try Data(contentsOf: Fixture.root.appendingPathComponent(path))
    }

    private func gunzip(_ path: String) throws -> String {
        String(decoding: try Gzip.decompress(fixtureData(path)), as: UTF8.self)
    }

    func testFindsDriverLogsOldestFirstAndIgnoresTheRest() throws {
        let directory = try TemporaryDirectory()
        for name in ["driver.log", "driver-2026-10-09.log.gz", "driver-2026-10-08.log", "driver.status",
                     "notes.txt", "driver-latest.log.gz", "driver-2026-10-9.log.gz"] {
            try directory.write(name, "")
        }
        let files = try LogDirectory(url: directory.url).files()
        XCTAssertEqual(files.map(\.name), ["driver-2026-10-08.log", "driver-2026-10-09.log.gz", "driver.log"])
        XCTAssertEqual(files.map(\.rotationDate), ["2026-10-08", "2026-10-09", nil])
    }

    func testDirectoryWithoutDriverLogs() throws {
        let directory = try TemporaryDirectory()
        try directory.write("driver.status", "{}")
        XCTAssertThrowsError(try LogDirectory(url: directory.url).files()) { error in
            XCTAssertEqual(error as? GatekeeprError, .noLogFiles(path: directory.url.path))
        }
    }

    func testGzip() throws {
        let text = try gunzip("rotation/driver-2026-10-07.log.gz")
        XCTAssertTrue(text.hasPrefix("[2026-10-07T"))
        XCTAssertEqual(text.split(separator: "\n").count, 40)
    }

    func testGzipWithSeveralMembers() throws {
        // `cat a.gz b.gz > ab.gz` is a valid gzip file.
        let joined = try fixtureData("rotation/driver-2026-10-06.log.gz") + fixtureData("rotation/driver-2026-10-07.log.gz")
        let expected = try gunzip("rotation/driver-2026-10-06.log.gz") + gunzip("rotation/driver-2026-10-07.log.gz")
        XCTAssertEqual(String(decoding: try Gzip.decompress(joined), as: UTF8.self), expected)
    }

    func testTruncatedGzipFails() throws {
        let data = try fixtureData("rotation/driver-2026-10-07.log.gz")
        XCTAssertThrowsError(try Gzip.decompress(data.prefix(data.count / 2))) { error in
            XCTAssertTrue("\(error)".contains("truncated"), "\(error)")
        }
    }

    func testCorruptGzipFails() throws {
        var data = try fixtureData("rotation/driver-2026-10-07.log.gz")
        let middle = data.startIndex + data.count / 2
        data[middle] ^= 0xFF
        data[middle + 1] ^= 0xFF
        XCTAssertThrowsError(try Gzip.decompress(data))
    }

    func testNotGzipFails() {
        XCTAssertThrowsError(try Gzip.decompress(Data("[2026-10-10T23:24:41.741Z] Info : hello\n".utf8)))
    }

    func testUnreadableArchiveIsReportedAsSuch() throws {
        let directory = try TemporaryDirectory()
        try directory.write("driver-2026-10-09.log.gz", "not gzip at all")
        try directory.write("driver.log", "")
        XCTAssertThrowsError(try Gatekeepr(logDirectory: directory.url).analyze()) { error in
            guard case let GatekeeprError.logFileUnreadable(file, _) = error else {
                return XCTFail("expected logFileUnreadable, got \(error)")
            }
            XCTAssertEqual(file, "driver-2026-10-09.log.gz")
        }
    }
}
