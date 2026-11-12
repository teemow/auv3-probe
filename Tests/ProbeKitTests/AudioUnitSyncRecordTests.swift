import XCTest
@testable import ProbeKit

// What the audio units tab remembers of the daemon it sent the units to. The
// hosts are from the documentation range (192.0.2.0/24).
final class AudioUnitSyncRecordTests: XCTestCase {
    private typealias Installed = AudioUnitSyncRecord.Installed
    private let daemon = "192.0.2.10:7800"
    private let synth = Installed(id: "aumu/synt/demo", version: "1.0.0")
    private let delay = Installed(id: "aufx/dely/demo", version: "2.1.0")
    private let broken = Installed(id: "aumf/brkn/demo", version: "0.9.0")

    private func recorded() -> AudioUnitSyncRecord {
        var record = AudioUnitSyncRecord(daemon: daemon)
        record.note(synth, outcome: .sent(params: 12, writable: 10), daemon: daemon)
        record.note(delay, outcome: .empty, daemon: daemon)
        record.note(broken, outcome: .failed("could not instantiate audio unit"), daemon: daemon)
        return record
    }

    func testAStartSendsNothingTheDaemonHolds() {
        let record = recorded()
        XCTAssertEqual(record.pending([synth, delay], daemon: daemon), [])
        XCTAssertEqual(record.outcome(of: synth, daemon: daemon), .sent(params: 12, writable: 10))
        XCTAssertEqual(record.outcome(of: delay, daemon: daemon), .empty)
    }

    // A failure is on record, so the tab can show it before anything is read,
    // and the unit is tried again: it may instantiate this time.
    func testAUnitThatFailedIsTriedAgain() {
        let record = recorded()
        XCTAssertEqual(record.outcome(of: broken, daemon: daemon), .failed("could not instantiate audio unit"))
        XCTAssertEqual(record.pending([synth, delay, broken], daemon: daemon), [broken])
    }

    func testNewAndUpdatedUnitsAreSent() {
        let record = recorded()
        let updated = Installed(id: synth.id, version: "1.1.0")
        let new = Installed(id: "aumu/newu/demo", version: "1.0.0")
        XCTAssertEqual(record.pending([updated, delay, new], daemon: daemon), [updated, new])
    }

    func testAnotherDaemonGetsEverything() {
        let record = recorded()
        let other = "192.0.2.20:7800"
        XCTAssertEqual(record.pending([synth, delay], daemon: other), [synth, delay])
        XCTAssertNil(record.outcome(of: synth, daemon: other))
    }

    func testANoteForAnotherDaemonStartsTheRecordOver() {
        var record = recorded()
        let other = "192.0.2.20:7800"
        record.note(synth, outcome: .empty, daemon: other)
        XCTAssertEqual(record.daemon, other)
        XCTAssertEqual(record.units.count, 1)
        XCTAssertEqual(record.pending([synth, delay], daemon: other), [delay])
    }

    // A run iPadOS cut short left only the units it got to.
    func testARunCutShortIsTakenUpWhereItStopped() {
        var record = AudioUnitSyncRecord(daemon: daemon)
        record.note(synth, outcome: .sent(params: 12, writable: 10), daemon: daemon)
        XCTAssertEqual(record.pending([synth, delay, broken], daemon: daemon), [delay, broken])
    }

    func testPruneDropsUninstalledUnits() {
        var record = recorded()
        record.prune(to: [synth])
        XCTAssertEqual(Array(record.units.keys), [synth.id])
    }

    func testTheRecordSurvivesItsStorage() throws {
        let record = recorded()
        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(AudioUnitSyncRecord.self, from: data), record)
    }
}
