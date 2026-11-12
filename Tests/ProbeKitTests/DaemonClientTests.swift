import XCTest
@testable import ProbeKit

// The URLs the client builds for the session routes. The host is from the
// documentation range (192.0.2.0/24); the names are made up.
final class DaemonClientTests: XCTestCase {
    private let client = DaemonClient(host: "192.0.2.10")!

    // Go's query parser reads `+` as a space and drops a pair that holds a
    // `;`. A path with either was staged under another name (or none), never
    // listed under its own, and so uploaded in every sync cycle.
    func testTheUploadEscapesWhatTheDaemonsQueryParserReadsAsSyntax() throws {
        let url = try XCTUnwrap(client.aumUploadURL(
            filename: "Set.aumproj", relativePath: "Band + Friends/A;B & C=D.aumproj", modified: nil))
        XCTAssertEqual(
            url.absoluteString,
            "http://192.0.2.10:7800/aum-session?path=Band%20%2B%20Friends%2FA%3BB%20%26%20C%3DD.aumproj")
    }

    func testTheUploadKeepsNonASCIINames() throws {
        let url = try XCTUnwrap(client.aumUploadURL(
            filename: "x.aumproj", relativePath: "Lieder/Über.aumproj", modified: nil))
        XCTAssertEqual(url.absoluteString, "http://192.0.2.10:7800/aum-session?path=Lieder%2F%C3%9Cber.aumproj")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first?.value, "Lieder/Über.aumproj")
    }

    func testTheUploadSendsTheFilesDate() throws {
        let url = try XCTUnwrap(client.aumUploadURL(
            filename: "Set.aumproj", relativePath: "Set.aumproj",
            modified: Date(timeIntervalSince1970: 1_767_323_045)))
        XCTAssertEqual(
            url.absoluteString,
            "http://192.0.2.10:7800/aum-session?path=Set.aumproj&modified=2026-01-02T03%3A04%3A05Z")
    }

    func testAnUploadWithoutAPathGoesByItsName() throws {
        let url = try XCTUnwrap(client.aumUploadURL(filename: "My Set.aumproj", relativePath: "", modified: nil))
        XCTAssertEqual(url.absoluteString, "http://192.0.2.10:7800/aum-session?name=My%20Set.aumproj")
    }
}
