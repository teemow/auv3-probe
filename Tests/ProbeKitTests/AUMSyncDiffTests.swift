import XCTest
@testable import ProbeKit

// The session sync's diff: what a cycle makes of a file, given the AUM folder's
// listing, the controller's manifest and the index of the last sync. The names
// are made up.
final class AUMSyncDiffTests: XCTestCase {
    private let path = "Songs/Example.aumproj"
    private let staged = "2026-01-02T03:04:05Z"

    private func device(_ path: String? = nil, bytes: Int = 2000, modified: Double? = 5000,
                        hash: String? = nil, midiMap: Bool = false) -> AUMSyncDeviceFile {
        AUMSyncDeviceFile(path: path ?? self.path, bytes: bytes, modified: modified,
                          isMidiMap: midiMap, contentHash: hash)
    }

    private func controller(_ path: String? = nil, bytes: Int = 2000, modified: String? = nil) -> AUMSyncControllerFile {
        AUMSyncControllerFile(path: path ?? self.path, bytes: bytes, modified: modified ?? staged)
    }

    /// The index entry of a file both sides hold as synced.
    private func synced(deviceModified: Double? = 5000, bytes: Int = 2000, hash: String? = "aa",
                        listed: Bool? = true) -> AUMSyncIndexEntry {
        AUMSyncIndexEntry(deviceModified: deviceModified, deviceBytes: bytes,
                          controllerModified: staged, controllerBytes: bytes,
                          contentHash: hash, controllerListed: listed)
    }

    // MARK: - The app's own writes

    // A pull that replaces a file records the bytes it wrote. Whatever the
    // file's date says afterwards (iOS answered with the replaced file's date
    // when asked right after the write), the same bytes are no change.
    func testAFileThePullWroteIsNotADeviceChange() {
        let index = synced(deviceModified: 1400)
        XCTAssertTrue(AUMSyncDiff.needsContentCheck(device(), index: index),
                      "a moved date with the size kept is settled by the bytes")

        let decision = AUMSyncDiff.decide(device: device(hash: "aa"), controller: controller(), index: index)
        XCTAssertEqual(decision.action, .none, "the file the app fetched is not uploaded back")
        XCTAssertEqual(decision.index?.deviceModified, 5000, "the index takes the file's date")
    }

    // The same, with the controller staging the file again in between: that is
    // a pull, not a conflict nobody made.
    func testAFileThePullWroteIsNoConflictWhenTheControllerStagesAgain() {
        let decision = AUMSyncDiff.decide(
            device: device(hash: "aa"),
            controller: controller(bytes: 2100, modified: "2026-01-02T03:09:00Z"),
            index: synced(deviceModified: 1400))
        XCTAssertEqual(decision.action, .pull(updatesExisting: true))
    }

    func testASaveThatKeepsTheSizeIsADeviceChange() {
        let decision = AUMSyncDiff.decide(device: device(hash: "bb"), controller: controller(),
                                          index: synced(deviceModified: 1400))
        XCTAssertEqual(decision.action, .push)
    }

    func testAnUnchangedDateNeedsNoLookAtTheBytes() {
        XCTAssertFalse(AUMSyncDiff.needsContentCheck(device(), index: synced()))
        XCTAssertFalse(AUMSyncDiff.needsContentCheck(device(bytes: 2400), index: synced()),
                       "another size is a change without reading")
        XCTAssertFalse(AUMSyncDiff.needsContentCheck(device(), index: nil))
    }

    // An index written before the app recorded the bytes' hash has only the
    // date to go by.
    func testAnIndexWithoutAHashGoesByTheDate() {
        let index = synced(deviceModified: 1400, hash: nil)
        XCTAssertFalse(AUMSyncDiff.needsContentCheck(device(), index: index))
        XCTAssertEqual(AUMSyncDiff.decide(device: device(), controller: controller(), index: index).action, .push)
    }

    func testDatesWithinASecondAreTheSame() {
        let decision = AUMSyncDiff.decide(device: device(modified: 5000.7), controller: controller(), index: synced())
        XCTAssertEqual(decision.action, .none)
    }

    // MARK: - Uploads the controller lists under another name

    // The controller took the upload and lists it under another path (it read a
    // `+` in the path as a space, or its file system folds case). The device's
    // file is then "device only" in every cycle; it is uploaded once, not in
    // every cycle.
    func testAnUploadTheControllerDoesNotListIsNotSentAgain() {
        let own = "Band + Friends/Set.aumproj"
        let plan = AUMSyncDiff.plan(
            device: [device(own)],
            controller: [controller("Band   Friends/Set.aumproj")],
            index: [own: synced(listed: false)])
        XCTAssertEqual(action(plan, own), .unlisted(alias: nil))
        XCTAssertEqual(plan.index[own], synced(listed: false), "the upload stays on record")
    }

    func testAnUploadKeptUnderAnotherCaseNamesWhereItIs() {
        let own = "Band/Night drive.aumproj", theirs = "Band/Night Drive.aumproj"
        let plan = AUMSyncDiff.plan(
            device: [device(own), device(theirs)],
            controller: [controller(theirs)],
            index: [own: synced(listed: false), theirs: synced()])
        XCTAssertEqual(action(plan, own), .unlisted(alias: theirs))
        XCTAssertEqual(action(plan, theirs), AUMSyncAction.none)
    }

    func testAnUnlistedFileIsSentAgainOnceItChanges() {
        let decision = AUMSyncDiff.decide(device: device(bytes: 2600), controller: nil, index: synced(listed: false))
        XCTAssertEqual(decision.action, .push)
    }

    func testAnUploadIsListedOnceAManifestShowsIt() {
        let decision = AUMSyncDiff.decide(device: device(), controller: controller(), index: synced(listed: false))
        XCTAssertEqual(decision.action, .none)
        XCTAssertEqual(decision.index?.controllerListed, true)
    }

    // Deletions do not propagate: a file the controller listed and lists no
    // more is restored from the device's copy.
    func testAFileTheControllerDeletedIsRestored() {
        XCTAssertEqual(AUMSyncDiff.decide(device: device(), controller: nil, index: synced()).action, .push)
        XCTAssertEqual(AUMSyncDiff.decide(device: device(), controller: nil, index: synced(listed: nil)).action, .push,
                       "an index from before the app recorded listings restores too")
    }

    // MARK: - Conflicts

    func testBothSidesChangedIsAConflict() {
        let decision = AUMSyncDiff.decide(
            device: device(bytes: 2600),
            controller: controller(bytes: 2100, modified: "2026-01-02T03:09:00Z"),
            index: synced())
        XCTAssertEqual(decision.action, .conflict)
        XCTAssertEqual(decision.index, synced(), "a conflict leaves the index as it was")
    }

    func testAHeldConflictIsNotTurnedIntoACopy() {
        let decision = AUMSyncDiff.decide(device: device(bytes: 2600), controller: controller(),
                                          index: synced(), held: true)
        XCTAssertEqual(decision.action, .conflict)
    }

    // A side was picked while a cycle ran on an older listing: once both sides
    // match the index, the conflict is over, whoever still holds it.
    func testAHeldConflictEndsWhenBothSidesMatchTheIndex() {
        let decision = AUMSyncDiff.decide(device: device(), controller: controller(), index: synced(), held: true)
        XCTAssertEqual(decision.action, .none)
    }

    // MARK: - First sync, one side only, midimaps

    func testFilesNeverSyncedAreTheSameAtEqualSizes() {
        let decision = AUMSyncDiff.decide(device: device(), controller: controller(), index: nil)
        XCTAssertEqual(decision.action, .none)
        XCTAssertEqual(decision.index?.deviceModified, 5000)
        XCTAssertEqual(decision.index?.controllerModified, staged)
        XCTAssertEqual(decision.index?.controllerListed, true)
    }

    func testFilesNeverSyncedConflictAtDifferentSizes() {
        let decision = AUMSyncDiff.decide(device: device(bytes: 2600), controller: controller(), index: nil)
        XCTAssertEqual(decision.action, .conflict)
        XCTAssertNil(decision.index)
    }

    func testANewFileOnOneSideIsCopiedToTheOther() {
        XCTAssertEqual(AUMSyncDiff.decide(device: device(), controller: nil, index: nil).action, .push)
        XCTAssertEqual(AUMSyncDiff.decide(device: nil, controller: controller(), index: nil).action,
                       .pull(updatesExisting: false))
    }

    func testAChangeOnTheControllerIsPulled() {
        let decision = AUMSyncDiff.decide(
            device: device(), controller: controller(modified: "2026-01-02T03:09:00Z"), index: synced())
        XCTAssertEqual(decision.action, .pull(updatesExisting: true))
    }

    func testAMidimapIsNeverUploaded() {
        let map = "Maps/Example.aum_midimap"
        let alone = AUMSyncDiff.decide(device: device(map, midiMap: true), controller: nil, index: synced())
        XCTAssertEqual(alone.action, .none)
        XCTAssertNil(alone.index)

        let changed = AUMSyncDiff.decide(device: device(map, bytes: 2600, midiMap: true),
                                         controller: controller(map), index: synced())
        XCTAssertEqual(changed.action, .none)
    }

    // MARK: - The plan

    func testThePlanIsInPathOrderAndForgetsFilesGoneFromBothSides() {
        let plan = AUMSyncDiff.plan(
            device: [device("b.aumproj"), device("a.aumproj")],
            controller: [controller("c.aumproj"), controller("a.aumproj")],
            index: ["a.aumproj": synced(), "gone.aumproj": synced()],
            held: [])
        XCTAssertEqual(plan.actions.map(\.path), ["a.aumproj", "b.aumproj", "c.aumproj"])
        XCTAssertEqual(action(plan, "a.aumproj"), AUMSyncAction.none)
        XCTAssertEqual(action(plan, "b.aumproj"), .push)
        XCTAssertEqual(action(plan, "c.aumproj"), .pull(updatesExisting: false))
        XCTAssertEqual(Set(plan.index.keys), ["a.aumproj"])
    }

    func testNormalizeDropsEmptyParts() {
        XCTAssertEqual(AUMSyncDiff.normalize("/Songs//Example.aumproj"), "Songs/Example.aumproj")
    }

    private func action(_ plan: AUMSyncPlan, _ path: String) -> AUMSyncAction? {
        plan.actions.first { $0.path == path }?.action
    }
}
