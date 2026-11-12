import XCTest
@testable import ProbeKit

// The identifiers UI automation finds a conflict's buttons and the shown folder
// by. They are a contract with whoever drives the app, like the report's keys.
final class AUMSessionsAccessibilityTests: XCTestCase {
    func testIdentifiersCarryThePath() {
        XCTAssertEqual(AUMSessionsAccessibility.keepDevice("Songs/Example.aumproj"),
                       "keep-device:Songs/Example.aumproj")
        XCTAssertEqual(AUMSessionsAccessibility.keepController("Songs/Example.aumproj"),
                       "keep-controller:Songs/Example.aumproj")
        XCTAssertEqual(AUMSessionsAccessibility.folder("Live/Songs"), "aum-folder:Live/Songs")
        XCTAssertEqual(AUMSessionsAccessibility.folder(""), "aum-folder:", "the root")
    }
}
