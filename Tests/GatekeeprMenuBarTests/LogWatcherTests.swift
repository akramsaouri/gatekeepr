@testable import GatekeeprMenuBar
import XCTest

/// These use real kqueue events on a scratch directory.
final class LogWatcherTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private var queue: DispatchQueue!
    private var changes: ChangeCounter!
    private var watcher: LogWatcher?

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
        try directory.write("driver.log", lines: [LogLine.noise("2026-10-12T08:00:00Z")])
        try directory.write("driver-2026-10-11.log.gz", lines: [])
        queue = DispatchQueue(label: "log-watcher-tests")
        changes = ChangeCounter()
    }

    override func tearDown() {
        watcher?.stop()
        queue.sync {}
        watcher = nil
    }

    private func startWatching(_ url: URL? = nil, latency: TimeInterval = 0.05) {
        let changes = changes!
        let watcher = LogWatcher(directory: url ?? directory.url, queue: queue, latency: latency) { changes.increment() }
        self.watcher = watcher
        watcher.start()
        queue.sync {}
    }

    /// Waits for the change count to reach `count`.
    private func waitForChanges(_ count: Int, file: StaticString = #filePath, line: UInt = #line) {
        wait(for: [changes.expectation(reaching: count)], timeout: 5)
        XCTAssertGreaterThanOrEqual(changes.count, count, file: file, line: line)
    }

    /// Lets in-flight events and coalescing settle, then returns the count.
    private func settle() -> Int {
        Thread.sleep(forTimeInterval: 0.3)
        queue.sync {}
        return changes.count
    }

    func testAppendingToDriverLog() throws {
        startWatching()
        try directory.append("driver.log", lines: [LogLine.noise("2026-10-12T08:01:00Z")])
        waitForChanges(1)
    }

    func testRotationThatReplacesDriverLog() throws {
        startWatching()
        // What Appgate does at midnight: the old file goes, a new one takes its name.
        try FileManager.default.moveItem(at: directory.path("driver.log"), to: directory.path("driver-2026-10-12.log"))
        try directory.write("driver.log", lines: [LogLine.noise("2026-10-12T22:00:00Z")])
        waitForChanges(1)

        // The watch follows the new driver.log.
        let before = settle()
        try directory.append("driver.log", lines: [LogLine.noise("2026-10-12T22:01:00Z")])
        waitForChanges(before + 1)
    }

    func testRotationThatDeletesThenRecreatesDriverLog() throws {
        startWatching()
        try FileManager.default.removeItem(at: directory.path("driver.log"))
        waitForChanges(1)

        var before = settle()
        try directory.write("driver.log", lines: [LogLine.noise("2026-10-12T22:00:00Z")])
        waitForChanges(before + 1)

        before = settle()
        try directory.append("driver.log", lines: [LogLine.noise("2026-10-12T22:01:00Z")])
        waitForChanges(before + 1)
    }

    func testTruncation() throws {
        startWatching()
        let handle = try FileHandle(forWritingTo: directory.path("driver.log"))
        try handle.truncate(atOffset: 0)
        try handle.close()
        waitForChanges(1)
    }

    func testNewRotatedFile() throws {
        startWatching()
        try directory.write("driver-2026-10-12.log.gz", lines: [])
        waitForChanges(1)
    }

    func testRemovedRotatedFile() throws {
        startWatching()
        try FileManager.default.removeItem(at: directory.path("driver-2026-10-11.log.gz"))
        waitForChanges(1)
    }

    func testOtherFilesAreIgnored() throws {
        startWatching()
        try directory.write("driver.status", lines: ["{}"])
        try directory.write("notes.txt", lines: ["hello"])
        try FileManager.default.removeItem(at: directory.path("notes.txt"))
        XCTAssertEqual(settle(), 0)

        try directory.append("driver.log", lines: [LogLine.noise("2026-10-12T08:01:00Z")])
        waitForChanges(1)
    }

    func testBurstsAreCoalesced() throws {
        startWatching(latency: 0.3)
        for minute in 10..<30 {
            try directory.append("driver.log", lines: [LogLine.noise("2026-10-12T08:\(minute):00Z")])
        }
        Thread.sleep(forTimeInterval: 0.6)
        queue.sync {}
        XCTAssertEqual(changes.count, 1)
    }

    func testMissingDirectoryIsPickedUpWhenItAppears() throws {
        let missing = directory.url.appendingPathComponent("appgate", isDirectory: true)
        startWatching(missing)

        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: false)
        waitForChanges(1)

        let before = settle()
        try Data(LogLine.noise("2026-10-12T08:00:00Z").utf8).write(to: missing.appendingPathComponent("driver.log"))
        waitForChanges(before + 1)

        let afterCreate = settle()
        let handle = try FileHandle(forWritingTo: missing.appendingPathComponent("driver.log"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()
        waitForChanges(afterCreate + 1)
    }

    func testDirectoryRemovedAndRecreated() throws {
        let logs = directory.url.appendingPathComponent("appgate", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: false)
        try Data().write(to: logs.appendingPathComponent("driver.log"))
        startWatching(logs)

        try FileManager.default.removeItem(at: logs)
        waitForChanges(1)

        let before = settle()
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: false)
        try Data().write(to: logs.appendingPathComponent("driver.log"))
        waitForChanges(before + 1)
    }

    func testStopSilencesIt() throws {
        startWatching()
        watcher?.stop()
        queue.sync {}
        try directory.append("driver.log", lines: [LogLine.noise("2026-10-12T08:01:00Z")])
        XCTAssertEqual(settle(), 0)
    }
}

/// Counts callbacks from the watcher's queue and fulfils expectations as the
/// count reaches them.
final class ChangeCounter {
    private let lock = NSLock()
    private var value = 0
    private var waiting: [(Int, XCTestExpectation)] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        value += 1
        let reached = waiting.filter { $0.0 <= value }
        waiting.removeAll { $0.0 <= value }
        lock.unlock()
        reached.forEach { $0.1.fulfill() }
    }

    func expectation(reaching target: Int) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "\(target) change(s)")
        lock.lock()
        if value >= target {
            expectation.fulfill()
        } else {
            waiting.append((target, expectation))
        }
        lock.unlock()
        return expectation
    }
}
