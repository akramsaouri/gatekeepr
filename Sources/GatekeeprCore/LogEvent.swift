import Foundation

/// A log line that matters for working out sessions. Everything else in the
/// driver log (routes, DNS, status JSON, periodic `update-tokens`) is noise.
public struct LogEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The client sent a `login` to a site. One per site, so a sign-in
        /// shows up as two logins a second or two apart. Gateway reconnects
        /// send a fresh login too.
        case login(site: String)
        /// The Appgate client closed its control connection: the user signed
        /// out, or the session expired and the client tore it down.
        case clientClosed
        /// The Appgate client opened a control connection to the driver. Every
        /// sign-in starts with one; a session can't survive it.
        case clientConnected
        /// The driver's event loop started or stopped (reboot, driver restart).
        /// Any session from before is gone.
        case driverRestarted
        /// The client pushed a new deployment to the driver. Right after a
        /// renewal notification this is the user renewing the session in place.
        case deploy
        /// The gateway's "your session ends in `timeLeft` seconds" warning,
        /// repeated every minute until expiry.
        case renewalNotification(timeLeft: TimeInterval)
    }

    public let date: Date
    public let kind: Kind
    /// Where the line came from, for error messages: `driver.log:120`.
    public let file: String
    public let line: Int

    public init(date: Date, kind: Kind, file: String, line: Int) {
        self.date = date
        self.kind = kind
        self.file = file
        self.line = line
    }
}
