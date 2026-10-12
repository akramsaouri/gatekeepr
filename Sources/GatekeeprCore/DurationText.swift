import Foundation

/// Short durations like `6h08m`, as used on the command line and in statuslines.
public enum DurationText {
    /// Parses `30m`, `2h`, `1h30m`, `45s` or `1h30m15s`. Units must come in
    /// h, m, s order, each at most once. Returns nil for anything else.
    public static func parse(_ text: String) -> TimeInterval? {
        var rest = Substring(text.lowercased())
        var total: TimeInterval = 0
        var units: [(Character, TimeInterval)] = [("h", 3600), ("m", 60), ("s", 1)]
        guard !rest.isEmpty else { return nil }
        while !rest.isEmpty {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, let value = Int(digits) else { return nil }
            rest = rest.dropFirst(digits.count)
            guard let unit = rest.first, let index = units.firstIndex(where: { $0.0 == unit }) else { return nil }
            total += TimeInterval(value) * units[index].1
            units.removeFirst(index + 1)
            rest = rest.dropFirst()
        }
        return total
    }

    /// `6h08m`, `45m`, `<1m` or `0m`. Rounds down by default, so time left is
    /// never overstated.
    public static func format(_ interval: TimeInterval, rounding: FloatingPointRoundingRule = .down) -> String {
        let seconds = max(0, interval)
        let minutes = Int((seconds / 60).rounded(rounding))
        if minutes == 0 { return seconds > 0 && rounding == .down ? "<1m" : "0m" }
        let hours = minutes / 60
        return hours > 0 ? String(format: "%dh%02dm", hours, minutes % 60) : "\(minutes)m"
    }
}
