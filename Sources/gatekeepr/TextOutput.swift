import Foundation
import GatekeeprCore

/// The human-readable output. Times are shown in the local time zone.
enum TextOutput {
    static func short(_ status: Status) -> String {
        switch status.state {
        case .active, .expiringSoon: return DurationText.format(status.timeLeft ?? 0)
        case .expired: return "expired"
        case .signedOut: return "signed out"
        case .noSession: return "no session"
        }
    }

    static func status(_ status: Status, logDirectory: String) -> String {
        guard let session = status.session, let expiry = status.expiry else {
            return "No Appgate session found in \(logDirectory)."
        }
        let started = session.startKind == .renewal ? "Renewed" : "Signed in"
        let length = lengthDescription(status.sessionLength)
        var rows: [(String, String)] = []

        let heading: String
        switch status.state {
        case .active, .expiringSoon:
            heading = status.state == .active
                ? "Appgate session active"
                : "Appgate session expires soon (warning at \(DurationText.format(status.warnThreshold)))"
            let source = expiry.source == .renewalNotification ? ", per Appgate's expiry warning" : ""
            rows = [
                (started, date(session.start)),
                ("Expires", date(expiry.date) + source),
                ("Time left", DurationText.format(status.timeLeft ?? 0)),
                ("Length", length),
            ]
        case .expired:
            heading = "Appgate session expired"
            let ago = DurationText.format(status.now.timeIntervalSince(expiry.date))
            rows = [
                (started, date(session.start)),
                ("Expired", "\(date(expiry.date)) (\(ago) ago)"),
                ("Length", length),
            ]
        case .signedOut:
            heading = "Not signed in to Appgate"
            let reason: String
            switch session.endKind {
            case .clientRestarted: reason = "the Appgate client restarted"
            case .driverRestarted: reason = "the Appgate driver restarted"
            default: reason = "signed out"
            }
            rows = [
                ("Last session", date(session.start)),
                ("Ended", "\(session.end.map(date) ?? "?") (\(reason))"),
            ]
        case .noSession:
            return "No Appgate session found in \(logDirectory)."
        }

        let width = rows.map(\.0.count).max() ?? 0
        let body = rows.map { "  " + $0.0.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + $0.1 }
        return ([heading] + body).joined(separator: "\n")
    }

    static func history(_ analysis: Analysis, logDirectory: String) -> String {
        guard !analysis.sessions.isEmpty else {
            return "No Appgate sessions found in \(logDirectory)."
        }
        let header = ["Start", "How", "End", "Outcome", "Length", "Reconnects"]
        let rows = analysis.sessions.map { session -> [String] in
            [
                date(session.start),
                session.startKind == .renewal ? "renewal" : "sign-in",
                session.end.map(date) ?? "-",
                outcome(analysis.outcome(of: session)),
                session.measuredLength.map { DurationText.format($0, rounding: .toNearestOrAwayFromZero) } ?? "-",
                String(session.reconnects),
            ]
        }
        let widths = header.indices.map { column in
            ([header] + rows).map { $0[column].count }.max() ?? 0
        }
        let table = ([header] + rows).map { row in
            row.enumerated()
                .map { $0.element.padding(toLength: widths[$0.offset], withPad: " ", startingAt: 0) }
                .joined(separator: "  ")
                .trimmingCharacters(in: .whitespaces)
        }
        let summary = "Session length: \(lengthDescription(analysis.sessionLength))."
        let note = "Length is sign-in to Appgate's first expiry warning plus the warning's countdown; "
            + "\"-\" means no warning was seen."
        return (table + ["", summary, note]).joined(separator: "\n")
    }

    private static func lengthDescription(_ length: SessionLength) -> String {
        let duration = DurationText.format(length.duration, rounding: .toNearestOrAwayFromZero)
        switch length.learnedFrom {
        case 0: return "\(duration) (default, no measured sessions yet)"
        case 1: return "\(duration), measured from 1 session"
        default: return "\(duration), the median of \(length.learnedFrom) measured sessions"
        }
    }

    private static func outcome(_ outcome: Session.Outcome) -> String {
        switch outcome {
        case .active: return "active"
        case .expired: return "expired"
        case .signedOut: return "signed out"
        case .renewed: return "renewed"
        case .interrupted: return "interrupted"
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "EEE d MMM HH:mm"
        return formatter
    }()

    private static func date(_ date: Date) -> String {
        formatter.string(from: date)
    }
}
