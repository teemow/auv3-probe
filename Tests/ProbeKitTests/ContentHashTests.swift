import XCTest
@testable import ProbeKit

final class ContentHashTests: XCTestCase {
    func testSHA256IsLowercaseHex() {
        XCTAssertEqual(
            ContentHash.sha256(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(
            ContentHash.sha256(Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}
