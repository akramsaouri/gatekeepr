import Foundation
import GatekeeprCore

/// Calls back when Appgate's driver logs change, without polling: lines
/// appended to driver.log, driver.log truncated, replaced or removed by log
/// rotation, and rotated `driver-*.log.gz` files appearing or going away.
///
/// It uses kqueue vnode events (DispatchSource) on two things. The directory
/// source sees files being created, removed and renamed. The file source sees
/// writes to the current driver.log, and is re-opened whenever rotation puts a
/// new file in its place. Other files in the directory (`driver.status`) are
/// ignored. If the directory itself is missing (Appgate not installed yet), the
/// parent directory is watched until it shows up.
///
/// Bursts of changes are coalesced into one callback, at most `latency` after
/// the first change. Everything runs on `queue`, including the callback.
public final class LogWatcher {
    public static let liveFileName = "driver.log"

    public let directory: URL
    private let queue: DispatchQueue
    private let latency: TimeInterval
    private let onChange: () -> Void

    private var running = false
    private var pending = false
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var parentSource: DispatchSourceFileSystemObject?
    /// Driver log names in the directory and their inodes, to tell a log
    /// change from some other file in the directory changing.
    private var snapshot: [String: UInt64] = [:]
    /// The inode of the driver.log the file source has open.
    private var watchedInode: UInt64?

    public init(directory: URL, queue: DispatchQueue, latency: TimeInterval = 0.25, onChange: @escaping () -> Void) {
        self.directory = directory
        self.queue = queue
        self.latency = latency
        self.onChange = onChange
    }

    deinit {
        directorySource?.cancel()
        fileSource?.cancel()
        parentSource?.cancel()
    }

    public func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            watchDirectory()
        }
    }

    public func stop() {
        queue.async { [self] in
            running = false
            pending = false
            cancelSources()
        }
    }

    // MARK: Sources

    private func watchDirectory() {
        let source: DispatchSourceFileSystemObject
        do {
            source = try makeSource(directory.path, events: [.write, .delete, .rename, .revoke]) { [weak self] events in
                self?.directoryChanged(events)
            }
        } catch {
            watchParent()
            return
        }
        parentSource?.cancel()
        parentSource = nil
        directorySource = source
        snapshot = currentSnapshot()
        watchFile()
    }

    private func watchFile() {
        fileSource?.cancel()
        fileSource = nil
        watchedInode = nil
        let path = directory.appendingPathComponent(Self.liveFileName).path
        // A missing driver.log is fine: the directory source sees it appear.
        guard let source = try? makeSource(path, events: [.write, .extend, .attrib, .delete, .rename, .revoke], handler: { [weak self] events in
            self?.fileChanged(events)
        }) else { return }
        var info = stat()
        if fstat(Int32(source.handle), &info) == 0 { watchedInode = UInt64(info.st_ino) }
        fileSource = source
    }

    private func watchParent() {
        guard parentSource == nil else { return }
        let parent = directory.deletingLastPathComponent()
        parentSource = try? makeSource(parent.path, events: [.write]) { [weak self] _ in
            guard let self, FileManager.default.fileExists(atPath: self.directory.path) else { return }
            self.watchDirectory()
            self.changed()
        }
    }

    private func cancelSources() {
        [directorySource, fileSource, parentSource].forEach { $0?.cancel() }
        directorySource = nil
        fileSource = nil
        parentSource = nil
        watchedInode = nil
        snapshot = [:]
    }

    private func makeSource(
        _ path: String,
        events: DispatchSource.FileSystemEvent,
        handler: @escaping (DispatchSource.FileSystemEvent) -> Void
    ) throws -> DispatchSourceFileSystemObject {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: queue)
        source.setEventHandler { [unowned source] in handler(source.data) }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    // MARK: Events

    private func directoryChanged(_ events: DispatchSource.FileSystemEvent) {
        guard running else { return }
        if !events.isDisjoint(with: [.delete, .rename, .revoke]) {
            // The directory itself was removed or moved away.
            cancelSources()
            watchParent()
            changed()
            return
        }
        let current = currentSnapshot()
        if current[Self.liveFileName] != watchedInode {
            // Rotation replaced driver.log (or it appeared for the first time).
            watchFile()
        }
        if current != snapshot {
            snapshot = current
            changed()
        }
    }

    private func fileChanged(_ events: DispatchSource.FileSystemEvent) {
        guard running else { return }
        if !events.isDisjoint(with: [.delete, .rename, .revoke]) {
            // Rotated away. The new driver.log may already be there.
            watchFile()
        }
        changed()
    }

    private func changed() {
        guard running, !pending else { return }
        pending = true
        queue.asyncAfter(deadline: .now() + latency) { [weak self] in
            guard let self, self.running, self.pending else { return }
            self.pending = false
            self.onChange()
        }
    }

    private func currentSnapshot() -> [String: UInt64] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [:] }
        var snapshot: [String: UInt64] = [:]
        for name in names {
            let url = directory.appendingPathComponent(name)
            guard LogFile(url: url) != nil else { continue }
            var info = stat()
            if lstat(url.path, &info) == 0 { snapshot[name] = UInt64(info.st_ino) }
        }
        return snapshot
    }
}
