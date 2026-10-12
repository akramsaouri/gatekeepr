import Foundation
import GatekeeprCore

/// A notification about the current session.
public struct SessionNotification: Equatable {
    public enum Kind: String, Equatable {
        /// The session entered the warn window.
        case warning
        case expired
    }

    public let kind: Kind
    /// The session it's about, identified by its start: no two sessions share one.
    public let session: Date
    public let title: String
    public let body: String

    /// Notification Center keeps one notification per identifier, so a new
    /// session's warning replaces the last one rather than piling up.
    public var identifier: String { "gatekeepr.\(kind.rawValue)" }
}

/// Which session each kind of notification was last sent for. Persisted, so
/// relaunching the app doesn't send them again.
public struct NotificationLedger: Equatable {
    public var warnedSession: Date?
    public var expiredSession: Date?

    public init(warnedSession: Date? = nil, expiredSession: Date? = nil) {
        self.warnedSession = warnedSession
        self.expiredSession = expiredSession
    }

    public mutating func record(_ notification: SessionNotification) {
        switch notification.kind {
        case .warning: warnedSession = notification.session
        case .expired: expiredSession = notification.session
        }
    }
}

/// Decides when to notify: once per session when it enters the warn window,
/// and once when it expires.
public enum NotificationPlanner {
    /// An expiry is only worth a notification for this long. Opening the app
    /// (or the laptop) hours after the session ran out shouldn't announce it;
    /// the menu bar already says `expired`.
    public static let expiryNewsWindow: TimeInterval = 15 * 60

    /// The notification due now, or nil.
    public static func due(for status: Status, ledger: NotificationLedger, timeZone: TimeZone = .current) -> SessionNotification? {
        guard let session = status.session, let expiry = status.expiry, let timeLeft = status.timeLeft else { return nil }
        let id = session.start
        let at = StatusText.date(expiry.date, timeZone: timeZone)
        switch status.state {
        case .expiringSoon where ledger.warnedSession != id:
            // Rounded to the nearest minute: the check runs just after the
            // threshold is crossed, and "29m" would read oddly for a 30m warning.
            let left = DurationText.format(timeLeft, rounding: .toNearestOrAwayFromZero)
            return SessionNotification(kind: .warning, session: id,
                                       title: "Appgate session expires in \(left)",
                                       body: "It ends \(at). Click to open Appgate.")
        case .expired where ledger.expiredSession != id && -timeLeft <= expiryNewsWindow:
            return SessionNotification(kind: .expired, session: id,
                                       title: "Appgate session expired",
                                       body: "It ended \(at). Sign in again to reconnect.")
        default:
            return nil
        }
    }
}
