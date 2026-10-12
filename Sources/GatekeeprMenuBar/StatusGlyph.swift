import Foundation

/// What the menu bar item draws next to the time left: a ring that drains as
/// the session runs out. GatekeeprApp draws it; this decides what it shows.
public struct StatusGlyph: Equatable {
    public enum Shape: Equatable {
        /// What's left of the session: `fraction` of the ring, running
        /// anticlockwise from 12 o'clock, so the gap grows clockwise as time
        /// passes. Drawn over a faint full-circle track; nil draws the track alone.
        case ring(fraction: Double?)
        /// Expired: a ✕ in a solid ring.
        case crossedRing
        /// Not signed in: a dash in the faint track.
        case dashedTrack
        /// The logs can't be read or don't look the way gatekeepr expects.
        case warningTriangle
    }

    public enum Ink: Equatable {
        /// A template image, in the menu bar's own colour.
        case menuBar
        case orange
        case red
    }

    public let shape: Shape
    /// The colour of the glyph and of the text next to it.
    public let ink: Ink

    public init(tone: MenuState.Tone, progress: Double?) {
        switch tone {
        case .ok: self.init(shape: .ring(fraction: progress), ink: .menuBar)
        case .warning: self.init(shape: .ring(fraction: progress), ink: .orange)
        case .expired: self.init(shape: .crossedRing, ink: .red)
        case .signedOut: self.init(shape: .dashedTrack, ink: .menuBar)
        case .error: self.init(shape: .warningTriangle, ink: .red)
        }
    }

    init(shape: Shape, ink: Ink) {
        self.shape = shape
        self.ink = ink
    }

    /// The fraction of the session left: the time left over the session length,
    /// from 1 just after signing in to 0 at expiry, clamped to 0...1. Nil without
    /// a session, or when the length is zero or unknown.
    public static func progress(timeLeft: TimeInterval?, sessionLength: TimeInterval?) -> Double? {
        guard let timeLeft, let sessionLength, !timeLeft.isNaN, sessionLength.isFinite, sessionLength > 0 else {
            return nil
        }
        return min(max(timeLeft / sessionLength, 0), 1)
    }
}
