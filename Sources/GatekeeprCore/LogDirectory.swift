import Foundation

/// One Appgate driver log: the live `driver.log` or a rotated
/// `driver-YYYY-MM-DD.log.gz` (or uncompressed `.log`).
public struct LogFile: Equatable, Sendable {
    public let url: URL
    /// The `YYYY-MM-DD` in a rotated file's name; nil for the live driver.log.
    public let rotationDate: String?

    public var name: String { url.lastPathComponent }
    public var isCompressed: Bool { url.pathExtension == "gz" }

    /// Recognises driver log names; returns nil for anything else in the directory.
    init?(url: URL) {
        let name = url.lastPathComponent
        if name == "driver.log" {
            self.url = url
            self.rotationDate = nil
            return
        }
        guard name.hasPrefix("driver-") else { return nil }
        let rest = name.dropFirst("driver-".count)
        let date: Substring
        if rest.hasSuffix(".log.gz") {
            date = rest.dropLast(".log.gz".count)
        } else if rest.hasSuffix(".log") {
            date = rest.dropLast(".log".count)
        } else {
            return nil
        }
        let shape = date.map { $0.isASCII && $0.isNumber ? "9" : String($0) }.joined()
        guard shape == "9999-99-99" else { return nil }
        self.url = url
        self.rotationDate = String(date)
    }
}

/// The directory Appgate writes its driver logs to.
public struct LogDirectory: Sendable {
    public static let appgateDefault = URL(fileURLWithPath: "/var/log/appgate", isDirectory: true)

    public let url: URL

    public init(url: URL = LogDirectory.appgateDefault) {
        self.url = url
    }

    /// Driver logs, oldest first: rotated files by date, then the live driver.log.
    public func files() throws -> [LogFile] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: url.path)
        } catch {
            throw GatekeeprError.logDirectoryUnreadable(path: url.path, reason: Self.reason(error))
        }
        let files = names
            .compactMap { LogFile(url: url.appendingPathComponent($0)) }
            .sorted { lhs, rhs in
                // driver.log has no rotation date and is always the newest.
                let left = lhs.rotationDate ?? "9999-99-99"
                let right = rhs.rotationDate ?? "9999-99-99"
                return left == right ? lhs.name < rhs.name : left < right
            }
        guard !files.isEmpty else { throw GatekeeprError.noLogFiles(path: url.path) }
        return files
    }

    /// The text of a log file, decompressed if needed.
    public func text(of file: LogFile) throws -> String {
        var data: Data
        do {
            data = try Data(contentsOf: file.url)
        } catch {
            throw GatekeeprError.logFileUnreadable(file: file.name, reason: Self.reason(error))
        }
        if file.isCompressed {
            do {
                data = try Gzip.decompress(data)
            } catch {
                throw GatekeeprError.logFileUnreadable(file: file.name, reason: "\(error)")
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func reason(_ error: Error) -> String {
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain,
           let code = POSIXErrorCode(rawValue: Int32(underlying.code)) {
            return String(cString: strerror(code.rawValue))
        }
        return nsError.localizedDescription
    }
}
