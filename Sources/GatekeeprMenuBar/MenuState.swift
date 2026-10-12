import Foundation
import GatekeeprCore

/// Everything the menu bar item and its menu show, worked out from one read of
/// the logs at one moment. All the session logic is GatekeeprCore's; this only
/// decides how it looks.
public struct MenuState: Equatable {
    public enum Tone: Equatable {
        /// Signed in, more than the warn threshold left.
        case ok
        /// Signed in, inside the warn window.
        case warning
        case expired
        /// Signed out, or no session anywhere in the logs.
        case signedOut
        /// The logs can't be read or don't look the way gatekeepr expects (the
        /// CLI's exit code 3). Nothing about the session is shown.
        case error
    }

    public let tone: Tone
    /// The menu bar text: exactly what `gatekeepr --short` prints.
    public let title: String
    /// What VoiceOver reads for the menu bar item.
    public let accessibilityLabel: String
    /// The first line of the menu.
    public let heading: String
    /// `Signed in: Sun 11 Oct 23:18`, `Time left: 6h08m`, …, or the error,
    /// wrapped to fit a menu.
    public let details: [String]
    /// Recent sessions, newest first.
    public let history: [String]

    /// How many past sessions the menu lists.
    public static let historyLimit = 10
    /// Menu items don't wrap, so long error messages are split at this width.
    static let lineWidth = 64

    /// Before the first read, which takes well under a second.
    public static let loading = MenuState(
        tone: .ok, title: "…", accessibilityLabel: "Gatekeepr: reading the Appgate logs",
        heading: "Reading the Appgate logs…", details: [], history: []
    )

    init(tone: Tone, title: String, accessibilityLabel: String, heading: String, details: [String], history: [String]) {
        self.tone = tone
        self.title = title
        self.accessibilityLabel = accessibilityLabel
        self.heading = heading
        self.details = details
        self.history = history
    }

    public init(status: Status, analysis: Analysis, logDirectory: String, timeZone: TimeZone = .current) {
        let summary = StatusText.summary(status, logDirectory: logDirectory, timeZone: timeZone)
        title = StatusText.short(status)
        heading = summary.heading
        details = summary.rows.map { "\($0.label): \($0.value)" }
        history = Self.history(analysis, timeZone: timeZone)
        switch status.state {
        case .active:
            tone = .ok
            accessibilityLabel = "Appgate session: \(title) left"
        case .expiringSoon:
            tone = .warning
            accessibilityLabel = "Appgate session expires soon: \(title) left"
        case .expired:
            tone = .expired
            accessibilityLabel = "Appgate session expired"
        case .signedOut, .noSession:
            tone = .signedOut
            accessibilityLabel = "Not signed in to Appgate"
        }
    }

    public init(error: Error) {
        tone = .error
        title = StatusText.shortError
        accessibilityLabel = "Gatekeepr can't read the Appgate logs"
        heading = "Can't tell when the Appgate session ends"
        details = Self.wrap("\(error)", width: Self.lineWidth)
        history = []
    }

    /// One line per session, newest first, from the same history `gatekeepr
    /// history` prints: `Fri 9 Oct 09:55 – Sat 10 Oct 09:55  expired, 24h00m`.
    static func history(_ analysis: Analysis, timeZone: TimeZone) -> [String] {
        analysis.sessions.suffix(historyLimit).reversed().map { session in
            let outcome = analysis.outcome(of: session)
            let start = StatusText.date(session.start, timeZone: timeZone)
            let how = session.startKind == .renewal ? " (renewed)" : ""
            // An open session that ran past its expiry ended then, as far as anyone can tell.
            let endDate = session.end ?? (outcome == .active ? nil : analysis.expiry(of: session).date)
            let end: String
            if let endDate {
                let sameDay = Calendar.gregorian(in: timeZone).isDate(endDate, inSameDayAs: session.start)
                end = sameDay ? StatusText.time(endDate, timeZone: timeZone) : StatusText.date(endDate, timeZone: timeZone)
            } else {
                end = "now"
            }
            let length = StatusText.measuredLength(session).map { ", \($0)" } ?? ""
            return "\(start)\(how) – \(end)  \(StatusText.outcome(outcome))\(length)"
        }
    }

    /// Splits text at spaces into lines of at most `width` characters (longer
    /// words get a line of their own).
    static func wrap(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            if line.isEmpty {
                line = String(word)
            } else if line.count + 1 + word.count <= width {
                line += " " + word
            } else {
                lines.append(line)
                line = String(word)
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    /// Seconds until the menu bar text next changes: just past the next whole
    /// minute of time left, since it shows whole minutes rounded down. The warn
    /// threshold and the expiry fall on those minutes too. At most a minute.
    public static func refreshDelay(timeLeft: TimeInterval?) -> TimeInterval {
        guard let timeLeft, timeLeft > 0 else { return 60 }
        return timeLeft.truncatingRemainder(dividingBy: 60) + 0.05
    }
}

extension Calendar {
    static func gregorian(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
