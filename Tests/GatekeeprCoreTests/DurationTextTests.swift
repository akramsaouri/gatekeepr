import XCTest
import GatekeeprCore

final class DurationTextTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(DurationText.parse("30m"), 1800)
        XCTAssertEqual(DurationText.parse("2h"), 7200)
        XCTAssertEqual(DurationText.parse("1h30m"), 5400)
        XCTAssertEqual(DurationText.parse("1H30M"), 5400)
        XCTAssertEqual(DurationText.parse("45s"), 45)
        XCTAssertEqual(DurationText.parse("1h30m15s"), 5415)
        XCTAssertEqual(DurationText.parse("90m"), 5400)
        XCTAssertEqual(DurationText.parse("0m"), 0)
    }

    func testParseRejects() {
        for text in ["", "30", "m", "1m1h", "1h1h", "1.5h", "-5m", " 30m", "30m ", "1d", "h30m"] {
            XCTAssertNil(DurationText.parse(text), text)
        }
    }

    func testFormat() {
        XCTAssertEqual(DurationText.format(6 * 3600 + 8 * 60 + 59), "6h08m")
        XCTAssertEqual(DurationText.format(59 * 60 + 59), "59m")
        XCTAssertEqual(DurationText.format(59), "<1m")
        XCTAssertEqual(DurationText.format(0), "0m")
        XCTAssertEqual(DurationText.format(-90), "0m")
        XCTAssertEqual(DurationText.format(86_399.234), "23h59m")
        XCTAssertEqual(DurationText.format(86_399.234, rounding: .toNearestOrAwayFromZero), "24h00m")
    }
}
