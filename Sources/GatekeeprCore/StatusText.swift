import Foundation

/// The wording shared by the CLI and the menu bar app, so both say the same
/// thing about a session. Times are shown in the given (by default local) time zone.
public enum StatusText {
    /// What `gatekeepr --short` prints when the logs can't be read or parsed.
    public static let shortError = "error"

    /// `gatekeepr --short`: `6h08m`, `expired`, `signed out` or `no session`.
    public static func short(_ status: Status) -> String {
        switch status.state {
        case .active, .expiringSoon: return DurationText.format(status.timeLeft ?? 0)
        case .expired: return "expired"
        case .signedOut: return "signed out"
        case .noSession: return "no session"
        }
    }

    /// A heading and labelled rows: what `gatekeepr` prints, and what the menu
    /// bar app shows at the top of its menu.
    public struct Summary: Equatable {
        public struct Row: Equatable {
            public let label: String
            public let value: String
        }

        public let heading: String
        public let rows: [Row]
    }

    public static func summary(_ status: Status, logDirectory: String, timeZone: TimeZone = .current) -> Summary {
        guard let session = status.session, let expiry = status.expiry else {
            return Summary(heading: "No Appgate session found in \(logDirectory).", rows: [])
        }
        func date(_ value: Date) -> String { StatusText.date(value, timeZone: timeZone) }
        func row(_ label: String, _ value: String) -> Summary.Row { Summary.Row(label: label, value: value) }
        let started = session.startKind == .renewal ? "Renewed" : "Signed in"
        let length = sessionLength(status.sessionLength)

        switch status.state {
        case .active, .expiringSoon:
            let heading = status.state == .active
                ? "Appgate session active"
                : "Appgate session expires soon (warning at \(DurationText.format(status.warnThreshold)))"
            let source = expiry.source == .renewalNotification ? ", per Appgate's expiry warning" : ""
            return Summary(heading: heading, rows: [
                row(started, date(session.start)),
                row("Expires", date(expiry.date) + source),
                row("Time left", DurationText.format(status.timeLeft ?? 0)),
                row("Length", length),
            ])
        case .expired:
            let ago = DurationText.format(status.now.timeIntervalSince(expiry.date))
            return Summary(heading: "Appgate session expired", rows: [
                row(started, date(session.start)),
                row("Expired", "\(date(expiry.date)) (\(ago) ago)"),
                row("Length", length),
            ])
        case .signedOut:
            let reason: String
            switch session.endKind {
            case .clientRestarted: reason = "the Appgate client restarted"
            case .driverRestarted: reason = "the Appgate driver restarted"
            default: reason = "signed out"
            }
            return Summary(heading: "Not signed in to Appgate", rows: [
                row("Last session", date(session.start)),
                row("Ended", "\(session.end.map(date) ?? "?") (\(reason))"),
            ])
        case .noSession:
            return Summary(heading: "No Appgate session found in \(logDirectory).", rows: [])
        }
    }

    /// `24h00m, the median of 17 measured sessions`.
    public static func sessionLength(_ length: SessionLength) -> String {
        let duration = DurationText.format(length.duration, rounding: .toNearestOrAwayFromZero)
        switch length.learnedFrom {
        case 0: return "\(duration) (default, no measured sessions yet)"
        case 1: return "\(duration), measured from 1 session"
        default: return "\(duration), the median of \(length.learnedFrom) measured sessions"
        }
    }

    /// A session's measured length (`24h00m`), or nil if no renewal notice was seen.
    public static func measuredLength(_ session: Session) -> String? {
        session.measuredLength.map { DurationText.format($0, rounding: .toNearestOrAwayFromZero) }
    }

    public static func outcome(_ outcome: Session.Outcome) -> String {
        switch outcome {
        case .active: return "active"
        case .expired: return "expired"
        case .signedOut: return "signed out"
        case .renewed: return "renewed"
        case .interrupted: return "interrupted"
        }
    }

    /// `Sun 11 Oct 01:24`.
    public static func date(_ date: Date, timeZone: TimeZone = .current) -> String {
        formatter(timeZone: timeZone, format: "EEE d MMM HH:mm").string(from: date)
    }

    /// `01:24`.
    public static func time(_ date: Date, timeZone: TimeZone = .current) -> String {
        formatter(timeZone: timeZone, format: "HH:mm").string(from: date)
    }

    private static func formatter(timeZone: TimeZone, format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}
