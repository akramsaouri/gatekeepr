import Foundation

/// One Appgate session, from sign-in (or in-place renewal) to whatever ended it.
public struct Session: Equatable, Sendable {
    public enum Start: String, Codable, Sendable {
        /// A login after the client closed, the client or driver restarted,
        /// or the first login in the log history.
        case signIn
        /// The user renewed from the expiry warning: a `deploy` arrived while
        /// renewal notifications were counting down, with no close or login.
        case renewal
    }

    public enum End: String, Codable, Sendable {
        /// The client closed its control connection (sign-out or expiry).
        case clientClosed
        /// The client opened a new control connection without closing the old one.
        case clientRestarted
        /// The driver's event loop stopped or started (reboot, driver restart).
        case driverRestarted
        /// Renewed in place; the next session starts at the same moment.
        case renewed
    }

    public enum Outcome: String, Codable, Sendable {
        case active
        case expired
        case signedOut
        case renewed
        /// Ended early by a client or driver restart.
        case interrupted
    }

    /// A token-renewal-notification: the gateway saying the session ends in `timeLeft`.
    public struct RenewalNotice: Equatable, Sendable {
        public let date: Date
        public let timeLeft: TimeInterval
        public var expiry: Date { date.addingTimeInterval(timeLeft) }
    }

    public internal(set) var start: Date
    public internal(set) var startKind: Start
    public internal(set) var end: Date?
    public internal(set) var endKind: End?
    public internal(set) var firstRenewalNotice: RenewalNotice?
    public internal(set) var lastRenewalNotice: RenewalNotice?
    /// Gateway reconnects during the session. Each one sends a new login, and
    /// none of them restart the session.
    public internal(set) var reconnects = 0

    init(start: Date, startKind: Start) {
        self.start = start
        self.startKind = startKind
    }

    /// Still going as far as the log knows.
    public var isOpen: Bool { end == nil }

    /// Start to first renewal notice, plus that notice's `timeLeft`: how long
    /// the gateway gave this session. Nil if no notice was seen.
    public var measuredLength: TimeInterval? {
        firstRenewalNotice.map { $0.expiry.timeIntervalSince(start) }
    }
}

/// Splits events into sessions.
enum SessionBuilder {
    /// Logins closer together than this are one burst: a sign-in or reconnect
    /// sends one login per site within a second or two.
    static let loginBurst: TimeInterval = 10

    static func sessions(from events: [LogEvent]) -> [Session] {
        var sessions: [Session] = []
        var open: Session?
        var lastLogin: Date?

        func close(at date: Date, _ kind: Session.End) {
            guard var session = open else { return }
            session.end = date
            session.endKind = kind
            sessions.append(session)
            open = nil
        }

        for event in events {
            switch event.kind {
            case .login:
                if var session = open {
                    if let lastLogin, event.date.timeIntervalSince(lastLogin) > loginBurst {
                        session.reconnects += 1
                    }
                    open = session
                } else {
                    open = Session(start: event.date, startKind: .signIn)
                }
                lastLogin = event.date
            case .clientClosed:
                close(at: event.date, .clientClosed)
            case .clientConnected:
                close(at: event.date, .clientRestarted)
            case .driverRestarted:
                close(at: event.date, .driverRestarted)
            case .deploy:
                // Outside the countdown a deploy is a reconnect or token refresh.
                if let notice = open?.lastRenewalNotice, event.date <= notice.expiry {
                    close(at: event.date, .renewed)
                    open = Session(start: event.date, startKind: .renewal)
                }
            case let .renewalNotification(timeLeft):
                // Notices from before the first sign-in in the history have no session.
                guard var session = open else { continue }
                let notice = Session.RenewalNotice(date: event.date, timeLeft: timeLeft)
                if session.firstRenewalNotice == nil { session.firstRenewalNotice = notice }
                session.lastRenewalNotice = notice
                open = session
            }
        }
        if let open { sessions.append(open) }
        return sessions
    }
}
