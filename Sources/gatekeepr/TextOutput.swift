import Foundation
import GatekeeprCore

/// The human-readable output. The wording comes from `StatusText`, which the
/// menu bar app shares; this adds the terminal layout. Times are local.
enum TextOutput {
    static func short(_ status: Status) -> String {
        StatusText.short(status)
    }

    static func status(_ status: Status, logDirectory: String) -> String {
        let summary = StatusText.summary(status, logDirectory: logDirectory)
        let width = summary.rows.map(\.label.count).max() ?? 0
        let body = summary.rows.map { "  " + $0.label.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + $0.value }
        return ([summary.heading] + body).joined(separator: "\n")
    }

    static func history(_ analysis: Analysis, logDirectory: String) -> String {
        guard !analysis.sessions.isEmpty else {
            return "No Appgate sessions found in \(logDirectory)."
        }
        let header = ["Start", "How", "End", "Outcome", "Length", "Reconnects"]
        let rows = analysis.sessions.map { session -> [String] in
            [
                StatusText.date(session.start),
                session.startKind == .renewal ? "renewal" : "sign-in",
                session.end.map { StatusText.date($0) } ?? "-",
                StatusText.outcome(analysis.outcome(of: session)),
                StatusText.measuredLength(session) ?? "-",
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
        let summary = "Session length: \(StatusText.sessionLength(analysis.sessionLength))."
        let note = "Length is sign-in to Appgate's first expiry warning plus the warning's countdown; "
            + "\"-\" means no warning was seen."
        return (table + ["", summary, note]).joined(separator: "\n")
    }
}
