import Foundation
import GatekeeprCore

/// The app's settings and notification bookkeeping, kept in UserDefaults.
public final class Preferences {
    public static let defaultWarnThreshold: TimeInterval = 30 * 60
    /// What the menu offers. A value set some other way (`defaults write`) is
    /// added to the list rather than dropped.
    public static let warnThresholdChoices: [TimeInterval] = [5, 10, 15, 30, 45, 60, 120].map { TimeInterval($0 * 60) }
    /// Sessions last 24 hours, so a longer warning would always be on.
    static let warnThresholdRange: ClosedRange<TimeInterval> = 60...(24 * 60 * 60)

    enum Key {
        static let warnThreshold = "warnThresholdSeconds"
        static let warnedSession = "warningSentForSessionStartingAt"
        static let expiredSession = "expiryNoticeSentForSessionStartingAt"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 30 minutes unless set; values outside a minute to a day fall back to that.
    public var warnThreshold: TimeInterval {
        get {
            guard let seconds = defaults.object(forKey: Key.warnThreshold) as? Double,
                  Self.warnThresholdRange.contains(seconds) else { return Self.defaultWarnThreshold }
            return seconds
        }
        set {
            defaults.set(newValue, forKey: Key.warnThreshold)
        }
    }

    public var ledger: NotificationLedger {
        get {
            NotificationLedger(warnedSession: date(Key.warnedSession), expiredSession: date(Key.expiredSession))
        }
        set {
            defaults.set(newValue.warnedSession?.timeIntervalSince1970, forKey: Key.warnedSession)
            defaults.set(newValue.expiredSession?.timeIntervalSince1970, forKey: Key.expiredSession)
        }
    }

    public static func warnThresholdChoices(including current: TimeInterval) -> [TimeInterval] {
        warnThresholdChoices.contains(current) ? warnThresholdChoices : (warnThresholdChoices + [current]).sorted()
    }

    /// `5 minutes`, `1 hour`, `2 hours`; anything else as `1h30m`.
    public static func label(forWarnThreshold seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        guard TimeInterval(minutes * 60) == seconds else { return DurationText.format(seconds) }
        switch minutes {
        case 1: return "1 minute"
        case 2..<60: return "\(minutes) minutes"
        case 60: return "1 hour"
        case let m where m.isMultiple(of: 60): return "\(m / 60) hours"
        default: return DurationText.format(seconds)
        }
    }

    private func date(_ key: String) -> Date? {
        (defaults.object(forKey: key) as? Double).map(Date.init(timeIntervalSince1970:))
    }
}
