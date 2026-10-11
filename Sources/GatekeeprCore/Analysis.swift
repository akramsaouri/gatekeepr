import Foundation

/// How long a session lasts, learned from the sessions in the log history.
public struct SessionLength: Equatable, Sendable {
    /// Used when no session in the history has a renewal notice to measure.
    public static let fallback: TimeInterval = 24 * 60 * 60

    public let duration: TimeInterval
    /// How many sessions the median was taken over; 0 means `fallback`.
    public let learnedFrom: Int

    public var isFallback: Bool { learnedFrom == 0 }

    public init(duration: TimeInterval, learnedFrom: Int) {
        self.duration = duration
        self.learnedFrom = learnedFrom
    }

    /// The median measured length, or 24h when nothing could be measured.
    static func learn(from sessions: [Session]) -> SessionLength {
        let lengths = sessions.compactMap(\.measuredLength).sorted()
        guard !lengths.isEmpty else { return SessionLength(duration: fallback, learnedFrom: 0) }
        let middle = lengths.count / 2
        let median = lengths.count.isMultiple(of: 2) ? (lengths[middle - 1] + lengths[middle]) / 2 : lengths[middle]
        return SessionLength(duration: median, learnedFrom: lengths.count)
    }
}

public struct Expiry: Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// Session start plus the learned (or default) session length.
        case sessionLength
        /// The gateway's own countdown: the latest renewal notice's time plus its `timeLeft`.
        case renewalNotification
    }

    public let date: Date
    public let source: Source
}

/// Where the current session stands.
public struct Status: Sendable {
    public enum State: String, Codable, Sendable {
        case active
        /// Signed in, with no more than the warn threshold left.
        case expiringSoon
        case expired
        case signedOut
        /// No session anywhere in the log history.
        case noSession

        /// 0 ok · 1 within the warn window · 2 expired or not signed in.
        public var exitCode: Int32 {
            switch self {
            case .active: return 0
            case .expiringSoon: return 1
            case .expired, .signedOut, .noSession: return 2
            }
        }
    }

    public let state: State
    public let now: Date
    /// The open session, or the most recent one when signed out. Nil when there are none.
    public let session: Session?
    public let expiry: Expiry?
    public let warnThreshold: TimeInterval
    public let sessionLength: SessionLength

    /// Negative once expired.
    public var timeLeft: TimeInterval? { expiry.map { $0.date.timeIntervalSince(now) } }
}

/// The log history read at one moment: sessions, the learned session length,
/// and from those, the status of the current session.
public struct Analysis: Sendable {
    /// A client close this close to the expected expiry counts as the session expiring.
    static let expiryTolerance: TimeInterval = 120

    public let now: Date
    public let logFiles: [LogFile]
    /// Oldest first. Only the last one can be open.
    public let sessions: [Session]
    public let sessionLength: SessionLength

    public init(now: Date, logFiles: [LogFile], events: [LogEvent]) {
        self.now = now
        self.logFiles = logFiles
        sessions = SessionBuilder.sessions(from: events)
        sessionLength = SessionLength.learn(from: sessions)
    }

    /// A renewal notice in the session wins over the timing model.
    public func expiry(of session: Session) -> Expiry {
        if let notice = session.lastRenewalNotice {
            return Expiry(date: notice.expiry, source: .renewalNotification)
        }
        return Expiry(date: session.start.addingTimeInterval(sessionLength.duration), source: .sessionLength)
    }

    public func outcome(of session: Session) -> Session.Outcome {
        let expiry = expiry(of: session).date
        guard let end = session.end, let endKind = session.endKind else {
            return now >= expiry ? .expired : .active
        }
        if endKind == .renewed { return .renewed }
        if end >= expiry.addingTimeInterval(-Self.expiryTolerance) { return .expired }
        return endKind == .clientClosed ? .signedOut : .interrupted
    }

    public func status(warnThreshold: TimeInterval) -> Status {
        guard let session = sessions.last else {
            return Status(state: .noSession, now: now, session: nil, expiry: nil,
                          warnThreshold: warnThreshold, sessionLength: sessionLength)
        }
        let expiry = expiry(of: session)
        let state: Status.State
        switch outcome(of: session) {
        case .active:
            state = expiry.date.timeIntervalSince(now) <= warnThreshold ? .expiringSoon : .active
        case .expired:
            state = .expired
        case .signedOut, .renewed, .interrupted:
            state = .signedOut
        }
        return Status(state: state, now: now, session: session, expiry: expiry,
                      warnThreshold: warnThreshold, sessionLength: sessionLength)
    }
}

/// Entry point: reads the driver logs and works out the session.
public struct Gatekeepr: Sendable {
    public let logDirectory: LogDirectory
    private let clock: @Sendable () -> Date

    /// - Parameters:
    ///   - logDirectory: where Appgate writes `driver.log`; `/var/log/appgate` by default.
    ///   - clock: the current time. Log lines after it are ignored, so tests can
    ///     ask "what did the log say at 9:00?".
    public init(
        logDirectory: URL = LogDirectory.appgateDefault,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.logDirectory = LogDirectory(url: logDirectory)
        self.clock = clock
    }

    public func analyze() throws -> Analysis {
        let now = clock()
        let files = try logDirectory.files()
        var events: [LogEvent] = []
        for file in files {
            events += try LogParser.events(in: logDirectory.text(of: file), file: file.name)
        }
        // Files are already oldest first; sorting by time (keeping file order for
        // ties) also copes with rotated files that overlap.
        events = events.enumerated()
            .filter { $0.element.date <= now }
            .sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
            .map(\.element)
        return Analysis(now: now, logFiles: files, events: events)
    }

    public func status(warnThreshold: TimeInterval) throws -> Status {
        try analyze().status(warnThreshold: warnThreshold)
    }
}
