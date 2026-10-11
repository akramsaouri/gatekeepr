import Foundation

/// Everything that stops gatekeepr from giving an answer it can stand behind.
/// The CLI maps all of these to exit code 3.
public enum GatekeeprError: Error, Equatable, CustomStringConvertible {
    /// The log directory is missing or can't be listed.
    case logDirectoryUnreadable(path: String, reason: String)
    /// The directory exists but holds no driver.log or driver-YYYY-MM-DD.log.gz.
    case noLogFiles(path: String)
    /// A log file exists but can't be read or decompressed.
    case logFileUnreadable(file: String, reason: String)
    /// A line doesn't look like any log line gatekeepr knows. Appgate may have
    /// changed its log format, so gatekeepr refuses to guess.
    case unrecognizedLine(file: String, line: Int, text: String)
    /// A line looks session-related (a login, a renewal notice, a close) but
    /// doesn't have the shape gatekeepr expects.
    case unrecognizedEvent(file: String, line: Int, text: String, reason: String)

    public var description: String {
        switch self {
        case let .logDirectoryUnreadable(path, reason):
            return "can't read the log directory \(path): \(reason)"
        case let .noLogFiles(path):
            return "no driver.log or driver-YYYY-MM-DD.log.gz files in \(path)"
        case let .logFileUnreadable(file, reason):
            return "can't read \(file): \(reason)"
        case let .unrecognizedLine(file, line, text):
            return "\(file):\(line): this line doesn't match any known Appgate log format, "
                + "so gatekeepr won't guess. Line: \(Self.excerpt(text))"
        case let .unrecognizedEvent(file, line, text, reason):
            return "\(file):\(line): \(reason), so gatekeepr won't guess. Line: \(Self.excerpt(text))"
        }
    }

    static func excerpt(_ text: String) -> String {
        text.count > 160 ? String(text.prefix(160)) + "…" : text
    }
}
