import Foundation

/// `gatekeepr --json`. The field names are a contract for statusline scripts
/// and other consumers; add fields rather than renaming them.
public struct StatusReport: Encodable, Equatable {
    public let state: Status.State
    public let exitCode: Int32
    public let now: Date
    public let sessionStart: Date?
    public let sessionStartKind: Session.Start?
    /// Set once the session has ended (signed out, or the client closed it on expiry).
    public let sessionEnd: Date?
    public let expiresAt: Date?
    public let expirySource: Expiry.Source?
    /// Negative once expired.
    public let secondsLeft: Int?
    /// `6h08m`, rounded down; `0m` once expired.
    public let timeLeft: String?
    public let warnThresholdSeconds: Int
    public let sessionLengthSeconds: Int
    /// 0 means the length is the 24h default.
    public let sessionLengthLearnedFrom: Int

    public init(_ status: Status) {
        state = status.state
        exitCode = status.state.exitCode
        now = status.now
        sessionStart = status.session?.start
        sessionStartKind = status.session?.startKind
        sessionEnd = status.session?.end
        expiresAt = status.expiry?.date
        expirySource = status.expiry?.source
        secondsLeft = status.timeLeft.map { Int($0.rounded(.down)) }
        timeLeft = status.timeLeft.map { DurationText.format($0) }
        warnThresholdSeconds = Int(status.warnThreshold)
        sessionLengthSeconds = Int(status.sessionLength.duration.rounded())
        sessionLengthLearnedFrom = status.sessionLength.learnedFrom
    }
}

/// `gatekeepr history --json`.
public struct HistoryReport: Encodable, Equatable {
    public struct Entry: Encodable, Equatable {
        public let start: Date
        public let startKind: Session.Start
        public let end: Date?
        public let endKind: Session.End?
        public let outcome: Session.Outcome
        public let expiresAt: Date
        public let expirySource: Expiry.Source
        /// Start to first renewal notice plus its timeLeft; absent if none was seen.
        public let measuredLengthSeconds: Int?
        public let reconnects: Int
    }

    public let now: Date
    public let sessionLengthSeconds: Int
    public let sessionLengthLearnedFrom: Int
    /// Oldest first.
    public let sessions: [Entry]

    public init(_ analysis: Analysis) {
        now = analysis.now
        sessionLengthSeconds = Int(analysis.sessionLength.duration.rounded())
        sessionLengthLearnedFrom = analysis.sessionLength.learnedFrom
        sessions = analysis.sessions.map { session in
            let expiry = analysis.expiry(of: session)
            return Entry(
                start: session.start,
                startKind: session.startKind,
                end: session.end,
                endKind: session.endKind,
                outcome: analysis.outcome(of: session),
                expiresAt: expiry.date,
                expirySource: expiry.source,
                measuredLengthSeconds: session.measuredLength.map { Int($0.rounded()) },
                reconnects: session.reconnects
            )
        }
    }
}

public enum JSONReport {
    /// Pretty-printed, sorted keys, dates as ISO 8601 in the given time zone
    /// (`2026-10-12T01:24:40+02:00`).
    public static func encode<Report: Encodable>(_ report: Report, timeZone: TimeZone = .current) throws -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return String(decoding: try encoder.encode(report), as: UTF8.self)
    }
}
