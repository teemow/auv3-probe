import XCTest
@testable import ProbeKit

// The report of the session sync to the daemon (docs/aum-sync-report.md). Its
// JSON keys are the contract with mcp-midi-controller. The names are made up.
final class AUMSyncReportTests: XCTestCase {
    private func entry(listed: Bool? = true) -> AUMSyncIndexEntry {
        AUMSyncIndexEntry(deviceModified: 5000, deviceBytes: 2000,
                          controllerModified: "2026-01-02T03:04:05Z", controllerBytes: 2000,
                          contentHash: "aa", controllerListed: listed)
    }

    func testTheReportSortsEveryFileThatIsNotInSync() {
        let report = AUMSyncReport(
            rev: 7,
            states: [
                "Songs/Held.aumproj": .conflict,
                "Songs/Broken.aumproj": .error("mcp-midi-controller returned HTTP 400: decode session"),
                "Songs/Up.aumproj": .pushing,
                "Songs/Down.aumproj": .pulling,
                "Live/Also held.aumproj": .conflict,
            ],
            index: [:])
        XCTAssertEqual(report.conflicts, ["Live/Also held.aumproj", "Songs/Held.aumproj"])
        XCTAssertEqual(report.errors, [AUMSyncReport.FileError(
            path: "Songs/Broken.aumproj", error: "mcp-midi-controller returned HTTP 400: decode session")])
        XCTAssertEqual(report.inFlight, [
            AUMSyncReport.Transfer(path: "Songs/Down.aumproj", to: .device),
            AUMSyncReport.Transfer(path: "Songs/Up.aumproj", to: .controller),
        ])
        XCTAssertEqual(report.rev, 7)
        XCTAssertEqual(report.v, 1)
    }

    // In sync: synced once, listed by the controller, and nothing pending.
    func testSyncedCountsTheFilesBothSidesHold() {
        let report = AUMSyncReport(
            rev: 1,
            states: ["c.aumproj": .conflict, "d.aumproj": .pulling, "e.aumproj": .error("not listed")],
            index: [
                "a.aumproj": entry(), "b.aumproj": entry(listed: nil),
                "c.aumproj": entry(), "d.aumproj": entry(), "e.aumproj": entry(listed: false),
                "f.aumproj": entry(listed: false),
            ])
        XCTAssertEqual(report.synced, 2)
    }

    func testTheDocumentHasTheKeysTheDaemonReads() throws {
        let report = AUMSyncReport(
            app: "auv3-probe 1.2.3",
            at: Date(timeIntervalSince1970: 1_767_323_045),
            rev: 42,
            states: [
                "Songs/Held.aumproj": .conflict,
                "Songs/Broken.aumproj": .error("refused"),
                "Songs/Down.aumproj": .pulling,
            ],
            index: ["Songs/Fine.aumproj": entry()],
            audioUnits: AUMSyncReport.AudioUnits(total: 4, synced: 2, failed: 1, syncing: true))
        let json = String(decoding: try report.encoded(), as: UTF8.self)
        XCTAssertEqual(json, """
            {"app":"auv3-probe 1.2.3","at":"2026-01-02T03:04:05Z",\
            "audio_units":{"failed":1,"state":"syncing","synced":2,"total":4},\
            "conflicts":["Songs/Held.aumproj"],\
            "errors":[{"error":"refused","path":"Songs/Broken.aumproj"}],\
            "in_flight":[{"path":"Songs/Down.aumproj","to":"device"}],\
            "rev":42,"synced":1,"v":1}
            """)
        XCTAssertEqual(try JSONDecoder().decode(AUMSyncReport.self, from: Data(json.utf8)), report)
    }

    // The lists are always there, empty or not; what does not apply is left out.
    func testAQuietCycleReportsEmptyLists() throws {
        let report = AUMSyncReport(at: Date(timeIntervalSince1970: 1_767_323_045), rev: 0, states: [:], index: [:])
        XCTAssertEqual(String(decoding: try report.encoded(), as: UTF8.self), """
            {"at":"2026-01-02T03:04:05Z","conflicts":[],"errors":[],"in_flight":[],"rev":0,"synced":0,"v":1}
            """)
    }

    func testACycleThatCouldNotRunSaysWhy() throws {
        let report = AUMSyncReport(rev: 3, states: [:], index: [:], error: "no aum folder linked yet")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try report.encoded()) as? [String: Any])
        XCTAssertEqual(object["error"] as? String, "no aum folder linked yet")
    }

    func testAudioUnitProgress() {
        typealias Units = AUMSyncReport.AudioUnits
        XCTAssertEqual(Units(total: 40, synced: 20, failed: 0, syncing: true).state, .syncing)
        XCTAssertEqual(Units(total: 40, synced: 39, failed: 1, syncing: false).state, .done,
                       "a unit that failed for good does not keep the sync open")
        XCTAssertEqual(Units(total: 40, synced: 20, failed: 0, syncing: false).state, .waiting)
        XCTAssertEqual(Units(total: 0, synced: 0, failed: 0, syncing: false).state, .waiting,
                       "nothing was looked for yet")
    }
}
