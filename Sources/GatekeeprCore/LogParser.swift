import Foundation

/// Turns driver log text into session events.
///
/// Every line must look like `[2026-10-10T23:24:41.741Z] Info : <message>`
/// (UTC timestamps). A line that doesn't is an error rather than something to
/// skip, and so is a session-related line with an unexpected shape: these are
/// observed, undocumented formats, so gatekeepr fails loudly instead of guessing.
public enum LogParser {
    static let requestPrefix = "Got request from client <"
    static let replyPrefix = "Sending reply to client <"

    public static func events(in text: String, file: String) throws -> [LogEvent] {
        var events: [LogEvent] = []
        let lines = text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        for (index, bytes) in lines.enumerated() {
            var line = Substring(bytes)
            if line.utf8.last == UInt8(ascii: "\r") { line = line.dropLast() }
            if line.allSatisfy(\.isWhitespace) { continue }
            let number = index + 1

            guard let envelope = Envelope(line) else {
                // A last line with no newline yet may still be being written.
                if index == lines.count - 1, line.hasPrefix("[") { continue }
                throw GatekeeprError.unrecognizedLine(file: file, line: number, text: String(line))
            }
            func unrecognized(_ reason: String) -> GatekeeprError {
                .unrecognizedEvent(file: file, line: number, text: String(line), reason: reason)
            }
            guard let kind = try classify(envelope.message, unrecognized: unrecognized) else { continue }
            guard let date = envelope.date else {
                throw unrecognized("the timestamp isn't a real date")
            }
            events.append(LogEvent(date: date, kind: kind, file: file, line: number))
        }
        return events
    }

    /// The event a message stands for, nil for noise.
    static func classify(
        _ message: Substring,
        unrecognized: (String) -> GatekeeprError
    ) throws -> LogEvent.Kind? {
        if message.hasPrefix(requestPrefix),
           message.contains("\"login\"") || message.contains("\"deploy\"") {
            guard let request = payload(of: message, after: requestPrefix) else {
                throw unrecognized("a login or deploy request isn't valid JSON")
            }
            let method = request["method"] as? String
            let params = request["params"] as? [String: Any]
            let inner = params?["message"] as? [String: Any]
            let innerMethod = inner?["method"] as? String
            if method == "deploy" { return .deploy }
            if method == "send-to", innerMethod == "login" {
                guard let site = params?["site-id"] as? String else {
                    throw unrecognized("a login request has no site-id")
                }
                return .login(site: site)
            }
            if method == "login" || innerMethod == "login" {
                throw unrecognized("a login request isn't wrapped in send-to as expected")
            }
            return nil
        }

        if message.contains("token-renewal-notification") {
            guard let reply = payload(of: message, after: replyPrefix),
                  let params = reply["params"] as? [String: Any],
                  let inner = params["message"] as? [String: Any],
                  inner["method"] as? String == "token-renewal-notification" else {
                throw unrecognized("a token-renewal-notification isn't the expected send-to reply")
            }
            guard let timeLeft = (inner["params"] as? [String: Any])?["timeLeft"] as? NSNumber,
                  timeLeft.doubleValue >= 0 else {
                throw unrecognized("a token-renewal-notification has no usable timeLeft")
            }
            return .renewalNotification(timeLeft: timeLeft.doubleValue)
        }

        if message.contains("Closing *:") {
            guard let reason = closeReason(message) else {
                throw unrecognized("a connection close doesn't look like `[SITE] [gateway] Closing *:PORT (reason)`")
            }
            // "Client closed control connection" is the client going away.
            // Everything else (Disconnected by gateway, Dead connection detected,
            // IP address change, timeouts) is the network, and a reconnect follows.
            return reason.hasPrefix("Client") ? .clientClosed : nil
        }

        if message == "Client closed control connection" { return .clientClosed }
        if message == "Got control connection" { return .clientConnected }
        if message.hasPrefix("Starting event loop") || message.hasPrefix("Stopping event loop") {
            return .driverRestarted
        }
        return nil
    }

    /// The JSON object in `<prefix>{...}>`.
    static func payload(of message: Substring, after prefix: String) -> [String: Any]? {
        guard message.hasPrefix(prefix), message.hasSuffix(">") else { return nil }
        let json = message.dropFirst(prefix.count).dropLast()
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    /// `[AWS] [sdp-gw1-aws] Closing *:54679 (Disconnected by gateway)` → `Disconnected by gateway`.
    static func closeReason(_ message: Substring) -> Substring? {
        var rest = message
        while rest.hasPrefix("[") {
            guard let end = rest.firstIndex(of: "]") else { return nil }
            rest = rest[rest.index(after: end)...]
            guard rest.hasPrefix(" ") else { return nil }
            rest = rest.dropFirst()
        }
        guard rest.hasPrefix("Closing *:") else { return nil }
        rest = rest.dropFirst("Closing *:".count)
        let port = rest.prefix { $0.isASCII && $0.isNumber }
        guard !port.isEmpty else { return nil }
        rest = rest.dropFirst(port.count)
        guard rest.hasPrefix(" ("), rest.hasSuffix(")") else { return nil }
        return rest.dropFirst(2).dropLast()
    }
}

/// `[2026-10-10T23:24:41.741Z] Info : <message>`
struct Envelope {
    /// `2026-10-10T23:24:41.741Z`, shape already checked.
    let timestamp: Substring
    let level: Substring
    let message: Substring

    private static let timestampShape = Array("dddd-dd-ddTdd:dd:dd.dddZ".utf8)

    init?(_ line: Substring) {
        let bytes = line.utf8
        guard bytes.first == UInt8(ascii: "["),
              bytes.count > Self.timestampShape.count + 2 else { return nil }
        let timestampStart = bytes.index(after: bytes.startIndex)
        let timestampEnd = bytes.index(timestampStart, offsetBy: Self.timestampShape.count)
        for (byte, expected) in zip(bytes[timestampStart..<timestampEnd], Self.timestampShape) {
            let ok = expected == UInt8(ascii: "d") ? (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) : byte == expected
            guard ok else { return nil }
        }
        // "] " + level + " : "
        var cursor = timestampEnd
        guard bytes[cursor] == UInt8(ascii: "]") else { return nil }
        cursor = bytes.index(after: cursor)
        guard cursor < bytes.endIndex, bytes[cursor] == UInt8(ascii: " ") else { return nil }
        cursor = bytes.index(after: cursor)
        let levelStart = cursor
        while cursor < bytes.endIndex, Self.isLetter(bytes[cursor]) {
            cursor = bytes.index(after: cursor)
        }
        let levelEnd = cursor
        guard levelStart < levelEnd else { return nil }
        for expected in " : ".utf8 {
            // The message may be empty, in which case the trailing space can be missing.
            if cursor == bytes.endIndex, expected == UInt8(ascii: " ") { break }
            guard cursor < bytes.endIndex, bytes[cursor] == expected else { return nil }
            cursor = bytes.index(after: cursor)
        }
        timestamp = line[timestampStart..<timestampEnd]
        level = line[levelStart..<levelEnd]
        message = line[cursor...]
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
    }

    /// The timestamp as a UTC date, or nil for impossible dates like 2026-02-30.
    var date: Date? {
        let digits = Array(timestamp.utf8).map { Int($0) - Int(UInt8(ascii: "0")) }
        func number(_ range: Range<Int>) -> Int { range.reduce(0) { $0 * 10 + digits[$1] } }
        let year = number(0..<4), month = number(5..<7), day = number(8..<10)
        let hour = number(11..<13), minute = number(14..<16), second = number(17..<19)
        let millisecond = number(20..<23)
        guard (1...12).contains(month), day >= 1, day <= Self.daysIn(month: month, year: year),
              hour < 24, minute < 60, second < 61 else { return nil }
        let seconds = Self.daysSinceEpoch(year: year, month: month, day: day) * 86_400
            + hour * 3600 + minute * 60 + second
        return Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(millisecond) / 1000)
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Days from 1970-01-01 to a proleptic Gregorian date (Howard Hinnant's days_from_civil).
    private static func daysSinceEpoch(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
