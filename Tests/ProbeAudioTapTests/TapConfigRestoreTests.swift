import XCTest
import AudioToolbox
import ProbeKit

// A host restores the tap's config through `fullState` whenever it likes. AUM
// does it right after creating the unit, and by then iOS may already have built
// the plugin's view. These tests drive the real audio unit and its view model
// the way a host does: create, maybe open the window, restore.
//
// An app extension cannot be imported, so project.yml compiles the extension's
// sources into this bundle.
final class TapConfigRestoreTests: XCTestCase {
    private let componentType = FourCharCode.from(string: "aufx")
    private let componentSubType = FourCharCode.from(string: "pbAu")
    private let componentManufacturer = FourCharCode.from(string: "Tmow")

    private func makeTap() throws -> ProbeAudioTapAU {
        try ProbeAudioTapAU(componentDescription: AudioComponentDescription(
            componentType: componentType, componentSubType: componentSubType,
            componentManufacturer: componentManufacturer,
            componentFlags: 0, componentFlagsMask: 0))
    }

    /// A node's state as AUM stores it in a session (`AuStateDoc`) and hands it
    /// to `fullState`: the component identity next to the plugin's own keys.
    private func sessionState(config json: String?) -> [String: Any] {
        var state: [String: Any] = [
            "type": Int(componentType), "subtype": Int(componentSubType),
            "manufacturer": Int(componentManufacturer), "version": 1,
        ]
        if let json { state[TapConfig.fullStateKey] = Data(json.utf8) }
        return state
    }

    // MARK: - The audio unit

    func testTheKeyIsTheOneTheDaemonAuthors() {
        XCTAssertEqual(TapConfig.fullStateKey, "probeAudioTapConfig")
    }

    func testAFreshTapStreams() throws {
        XCTAssertTrue(try makeTap().config.streaming)
    }

    func testRestoringASessionAppliesItsStreamingFlag() throws {
        let tap = try makeTap()
        tap.fullState = sessionState(config: #"{"streaming":false}"#)
        XCTAssertFalse(tap.config.streaming)

        // What the daemon authors for a tap.
        tap.fullState = sessionState(config: #"{"streaming":true}"#)
        XCTAssertTrue(tap.config.streaming)
    }

    /// Sessions saved by earlier builds carry a host and a decimation.
    func testAnOlderSessionsExtraKeysAreIgnored() throws {
        let tap = try makeTap()
        tap.fullState = sessionState(config: #"{"host":"example.local:7800","streaming":false,"decimation":4}"#)
        XCTAssertFalse(tap.config.streaming)
    }

    func testAStateWithoutAUsableConfigKeepsTheCurrentOne() throws {
        let tap = try makeTap()
        tap.updateConfig(TapConfig(streaming: false))

        tap.fullState = sessionState(config: nil)
        XCTAssertFalse(tap.config.streaming)
        tap.fullState = sessionState(config: #"{"decimation":4}"#)
        XCTAssertFalse(tap.config.streaming)
    }

    func testTheSavedStateRestoresIntoAnotherTap() throws {
        let saved = try makeTap()
        saved.updateConfig(TapConfig(streaming: false))
        let state = try XCTUnwrap(saved.fullState)
        XCTAssertTrue(state[TapConfig.fullStateKey] is Data)

        let loaded = try makeTap()
        loaded.fullState = state
        XCTAssertEqual(loaded.config, TapConfig(streaming: false))
    }

    // MARK: - The window

    /// The defect: the host restored a stopped tap, the button went on reading
    /// "stop streaming".
    @MainActor
    func testAnOpenWindowFollowsARestore() throws {
        let tap = try makeTap()
        let model = TapViewModel(audioUnit: tap)
        XCTAssertTrue(model.config.streaming)

        tap.fullState = sessionState(config: #"{"streaming":false}"#)
        model.poll()

        XCTAssertFalse(model.config.streaming)
        XCTAssertFalse(tap.config.streaming)
    }

    @MainActor
    func testAToggleReachesTheAudioUnitAtOnce() throws {
        let tap = try makeTap()
        let model = TapViewModel(audioUnit: tap)

        model.config.streaming.toggle()
        XCTAssertFalse(tap.config.streaming)

        // The next poll finds nothing to adopt and leaves the toggle alone.
        model.poll()
        XCTAssertFalse(model.config.streaming)

        model.config.streaming.toggle()
        XCTAssertTrue(tap.config.streaming)
    }

    /// One tap on the button of a window that was open across a restore must
    /// start a stopped tap, not stop it a second time.
    @MainActor
    func testAToggleAfterARestoreStartsFromTheRestoredConfig() throws {
        let tap = try makeTap()
        let model = TapViewModel(audioUnit: tap)

        tap.fullState = sessionState(config: #"{"streaming":false}"#)
        model.poll()
        model.config.streaming.toggle()

        XCTAssertTrue(tap.config.streaming)
    }
}
