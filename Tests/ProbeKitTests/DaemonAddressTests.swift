import XCTest
@testable import ProbeKit

// Address choice and host formatting for Bonjour discovery. Addresses are from
// the documentation ranges (192.0.2.0/24, 2001:db8::/32) and fe80::/10.
final class DaemonAddressTests: XCTestCase {
    private let v4 = DaemonAddress("192.0.2.10", port: 7800)
    private let v4Zoned = DaemonAddress("192.0.2.10%en0", port: 7800)
    private let v4LinkLocal = DaemonAddress("169.254.7.7", port: 7800)
    private let v6Global = DaemonAddress("2001:db8::10", port: 7800)
    private let v6LinkLocal = DaemonAddress("fe80::1c2b:3d4e:5f60:7a8b%en0", port: 7800)
    private let v6LinkLocalBare = DaemonAddress("fe80::1c2b:3d4e:5f60:7a8b", port: 7800)

    // MARK: - Parsing

    func testParsesZone() {
        XCTAssertEqual(v6LinkLocal.address, "fe80::1c2b:3d4e:5f60:7a8b")
        XCTAssertEqual(v6LinkLocal.zone, "en0")
        XCTAssertEqual(v4Zoned.address, "192.0.2.10")
        XCTAssertEqual(v4Zoned.zone, "en0")
        XCTAssertNil(v4.zone)
        XCTAssertNil(DaemonAddress("fe80::1%", port: 1).zone)
    }

    func testToleratesBrackets() {
        let a = DaemonAddress("[fe80::1%en0]", port: 7800)
        XCTAssertEqual(a.address, "fe80::1")
        XCTAssertEqual(a.zone, "en0")
    }

    func testKinds() {
        XCTAssertEqual(v4.kind, .ipv4)
        XCTAssertEqual(v4Zoned.kind, .ipv4)
        XCTAssertEqual(v4LinkLocal.kind, .ipv4LinkLocal)
        XCTAssertEqual(v6Global.kind, .ipv6Routable)
        XCTAssertEqual(DaemonAddress("fd12:3456::1", port: 1).kind, .ipv6Routable)
        XCTAssertEqual(v6LinkLocal.kind, .ipv6LinkLocalScoped)
        XCTAssertEqual(v6LinkLocalBare.kind, .ipv6LinkLocalUnscoped)
        // fe80::/10 covers fe80 through febf, and nothing past it.
        XCTAssertEqual(DaemonAddress("febf::1%en0", port: 1).kind, .ipv6LinkLocalScoped)
        XCTAssertEqual(DaemonAddress("fec0::1", port: 1).kind, .ipv6Routable)
        XCTAssertEqual(DaemonAddress("::1", port: 1).kind, .ipv6Routable)
    }

    // MARK: - Host formatting

    func testHostPortIPv4DropsZone() {
        XCTAssertEqual(v4.hostPort, "192.0.2.10:7800")
        XCTAssertEqual(v4Zoned.hostPort, "192.0.2.10:7800")
    }

    func testHostPortLinkLocalIPv6KeepsZone() {
        XCTAssertEqual(v6LinkLocal.hostPort, "[fe80::1c2b:3d4e:5f60:7a8b%en0]:7800")
        XCTAssertEqual(v6LinkLocalBare.hostPort, "[fe80::1c2b:3d4e:5f60:7a8b]:7800")
    }

    func testHostPortRoutableIPv6DropsZone() {
        XCTAssertEqual(DaemonAddress("2001:db8::10%en0", port: 7800).hostPort, "[2001:db8::10]:7800")
    }

    // MARK: - Address choice

    func testIPv4BeatsLinkLocalIPv6WhicheverArrivesFirst() {
        XCTAssertEqual(DaemonAddress.preferred([v6LinkLocal, v4]), v4)
        XCTAssertEqual(DaemonAddress.preferred([v4, v6LinkLocal]), v4)
    }

    func testRoutableIPv6BeatsLinkLocal() {
        XCTAssertEqual(DaemonAddress.preferred([v6LinkLocal, v6Global]), v6Global)
        XCTAssertEqual(DaemonAddress.preferred([v4LinkLocal, v6Global]), v6Global)
    }

    func testScopedLinkLocalBeatsUnscoped() {
        XCTAssertEqual(DaemonAddress.preferred([v6LinkLocalBare, v6LinkLocal]), v6LinkLocal)
    }

    func testTiesKeepResolveOrder() {
        let other = DaemonAddress("192.0.2.20", port: 7800)
        XCTAssertEqual(DaemonAddress.preferred([other, v4]), other)
    }

    func testNoCandidates() {
        XCTAssertNil(DaemonAddress.preferred([]))
        XCTAssertNil(DaemonAddress.preferred([], failed: ["192.0.2.10:7800"]))
    }

    func testFailedAddressLosesToAWorseKind() {
        let failed = [v4.hostPort]
        XCTAssertEqual(DaemonAddress.preferred([v4, v6LinkLocal], failed: failed), v6LinkLocal)
    }

    func testAllFailedRetriesTheOldestFailure() {
        let failed = [v6LinkLocal.hostPort, v4.hostPort]
        XCTAssertEqual(DaemonAddress.preferred([v4, v6LinkLocal], failed: failed), v6LinkLocal)
        XCTAssertEqual(DaemonAddress.preferred([v4, v6LinkLocal], failed: failed.reversed()), v4)
    }

    func testReResolvesRotateOffDeadAddresses() {
        // Each round: pick, the pick keeps failing, record it, re-resolve.
        var failed: [String] = []
        var picks: [DaemonAddress] = []
        for _ in 0..<4 {
            let pick = DaemonAddress.preferred([v6LinkLocal, v4], failed: failed)!
            picks.append(pick)
            failed = DaemonAddress.recordFailure(pick.hostPort, in: failed)
        }
        XCTAssertEqual(picks, [v4, v6LinkLocal, v4, v6LinkLocal])
    }

    func testRecordFailureMovesToEndAndCaps() {
        XCTAssertEqual(DaemonAddress.recordFailure("a", in: ["a", "b"]), ["b", "a"])
        XCTAssertEqual(DaemonAddress.recordFailure("c", in: ["a", "b"], limit: 2), ["b", "c"])
    }
}

// The `host:port` strings above, as the networking clients consume them.
final class DaemonHostFormattingTests: XCTestCase {
    func testEscapingZone() {
        XCTAssertEqual(DaemonClient.escapingZone("http://[fe80::1%en0]:7800"), "http://[fe80::1%25en0]:7800")
        XCTAssertEqual(DaemonClient.escapingZone("http://[fe80::1%25en0]:7800"), "http://[fe80::1%25en0]:7800")
        XCTAssertEqual(DaemonClient.escapingZone("http://[2001:db8::1]:7800"), "http://[2001:db8::1]:7800")
        XCTAssertEqual(DaemonClient.escapingZone("http://192.0.2.10:7800"), "http://192.0.2.10:7800")
        // A `%` outside the brackets (a query, say) is not a zone.
        XCTAssertEqual(DaemonClient.escapingZone("http://[::1]:7800/?q=%41"), "http://[::1]:7800/?q=%41")
    }

    func testClientAcceptsDiscoveredHosts() throws {
        let v4 = try XCTUnwrap(DaemonClient(host: "192.0.2.10:7800"))
        XCTAssertEqual(v4.baseURL.absoluteString, "http://192.0.2.10:7800")

        let v6 = try XCTUnwrap(DaemonClient(host: "[2001:db8::10]:7800"))
        XCTAssertEqual(v6.baseURL.absoluteString, "http://[2001:db8::10]:7800")

        let linkLocal = try XCTUnwrap(DaemonClient(host: "[fe80::1%en0]:7800"))
        XCTAssertEqual(linkLocal.baseURL.absoluteString, "http://[fe80::1%25en0]:7800")
        XCTAssertEqual(linkLocal.webSocketURL(path: "audio-stream")?.absoluteString,
                       "ws://[fe80::1%25en0]:7800/audio-stream")
    }

    func testNormalizeManual() {
        XCTAssertNil(DaemonDiscovery.normalizeManual(nil))
        XCTAssertNil(DaemonDiscovery.normalizeManual("  "))
        XCTAssertNil(DaemonDiscovery.normalizeManual("http://"))
        XCTAssertEqual(DaemonDiscovery.normalizeManual("192.0.2.10"), "192.0.2.10:7800")
        XCTAssertEqual(DaemonDiscovery.normalizeManual(" http://192.0.2.10:9000/ "), "192.0.2.10:9000")
        XCTAssertEqual(DaemonDiscovery.normalizeManual("[::1]"), "[::1]:7800")
        XCTAssertEqual(DaemonDiscovery.normalizeManual("[::1]:9000"), "[::1]:9000")
        XCTAssertEqual(DaemonDiscovery.normalizeManual("fe80::1%en0"), "[fe80::1%en0]:7800")
        XCTAssertEqual(DaemonDiscovery.normalizeManual("2001:db8::10"), "[2001:db8::10]:7800")
    }
}
