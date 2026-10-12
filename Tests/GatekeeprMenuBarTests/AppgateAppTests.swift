@testable import GatekeeprMenuBar
import XCTest

final class AppgateAppTests: XCTestCase {
    private let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
    private let home = URL(fileURLWithPath: "/Users/someone/Applications", isDirectory: true)

    func testBundleIDComesFirst() {
        let registered = URL(fileURLWithPath: "/Somewhere/Appgate SDP.app")
        let url = AppgateApp.locate(
            bundleURL: { $0 == "com.appgate.sdp" ? registered : nil },
            searchDirectories: [applications],
            exists: { _ in XCTFail("shouldn't look by name"); return true }
        )
        XCTAssertEqual(url, registered)
    }

    func testFallsBackToTheName() {
        let url = AppgateApp.locate(
            bundleURL: { _ in nil },
            searchDirectories: [applications, home],
            exists: { $0.path == "/Users/someone/Applications/AppGate SDP.app" }
        )
        XCTAssertEqual(url?.path, "/Users/someone/Applications/AppGate SDP.app")
    }

    func testNotInstalled() {
        XCTAssertNil(AppgateApp.locate(bundleURL: { _ in nil }, searchDirectories: [applications], exists: { _ in false }))
    }
}
