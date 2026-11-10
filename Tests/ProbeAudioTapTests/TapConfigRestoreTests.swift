import XCTest
import AudioToolbox
import ProbeKit

// A host restores the tap's config through `fullState` whenever it likes. AUM
// does it right after creating the unit, and by then iOS may already have built
// the plugin's view. These tests drive the real audio unit and its view model
// the way a host does: create, maybe open the window, restore. The config
// carries whether the tap streams and the name it streams under.
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

    // MARK: - The name

    func testAFreshTapHasNoName() throws {
        let tap = try makeTap()
        XCTAssertNil(tap.config.name)
        XCTAssertNil(tap.config.streamName)
    }

    /// What the daemon authors for a tap of a song's session: the session and
    /// the strip the tap sits on.
    func testRestoringASessionAppliesItsName() throws {
        let tap = try makeTap()
        tap.fullState = sessionState(config: #"{"streaming":true,"name":"Songs/Night Drive/master"}"#)
        XCTAssertEqual(tap.config, TapConfig(streaming: true, name: "Songs/Night Drive/master"))
    }

    /// A session from before taps had names decodes, and to a tap without one:
    /// the name belongs to the session, so one restored earlier does not stay.
    func testAnOlderSessionWithoutANameStillDecodes() throws {
        let tap = try makeTap()
        tap.fullState = sessionState(config: #"{"streaming":true,"name":"Songs/Night Drive/master"}"#)

        tap.fullState = sessionState(config: #"{"streaming":false}"#)
        XCTAssertEqual(tap.config, TapConfig(streaming: false, name: nil))
    }

    func testTheSavedStateKeepsTheName() throws {
        let saved = try makeTap()
        saved.updateConfig(TapConfig(streaming: true, name: "Songs/Night Drive/bass"))

        let loaded = try makeTap()
        loaded.fullState = try XCTUnwrap(saved.fullState)
        XCTAssertEqual(loaded.config, TapConfig(streaming: true, name: "Songs/Night Drive/bass"))
    }

    /// A tap without a name saves the config an earlier build wrote.
    func testATapWithoutANameSavesNoNameKey() throws {
        let data = try XCTUnwrap(TapConfig(streaming: true).fullStateData)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Array(json.keys), ["streaming"])
    }

    func testANameOfOnlyWhitespaceIsNoName() {
        XCTAssertNil(TapConfig(name: "").streamName)
        XCTAssertNil(TapConfig(name: " \n").streamName)
        XCTAssertEqual(TapConfig(name: " Songs/Night Drive/master ").streamName, "Songs/Night Drive/master")
    }

    // MARK: - What a named tap sends

    /// The daemon keeps the streams of a session's taps apart by the name in
    /// the path they dial.
    func testANamedTapDialsUnderItsName() throws {
        let client = try XCTUnwrap(DaemonClient(host: "192.0.2.10:7800"))
        let named = client.webSocketURL(path: "audio-stream",
                                        query: TapStreamer.query(name: "Songs/Night Drive/master"))
        XCTAssertEqual(named?.absoluteString,
                       "ws://192.0.2.10:7800/audio-stream?name=Songs%2FNight%20Drive%2Fmaster")

        let unnamed = client.webSocketURL(path: "audio-stream", query: TapStreamer.query(name: nil))
        XCTAssertEqual(unnamed?.absoluteString, "ws://192.0.2.10:7800/audio-stream")
    }

    func testTheFormatMessageCarriesTheNameAsItsSource() {
        let named = TapStreamer.formatMessage(channels: 2, sampleRate: 48_000, name: "Songs/Night Drive/master")
        XCTAssertEqual(named["source"] as? String, "Songs/Night Drive/master")
        XCTAssertEqual(named["type"] as? String, "format")
        XCTAssertEqual(named["channels"] as? Int, 2)

        let unnamed = TapStreamer.formatMessage(channels: 2, sampleRate: 48_000, name: nil)
        XCTAssertEqual(unnamed["source"] as? String, "ProbeAudioTap")
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

    /// The name comes with the session, after the window may be up already.
    @MainActor
    func testAnOpenWindowShowsTheRestoredName() throws {
        let tap = try makeTap()
        let model = TapViewModel(audioUnit: tap)
        XCTAssertNil(model.name)

        tap.fullState = sessionState(config: #"{"streaming":true,"name":"Songs/Night Drive/master"}"#)
        model.poll()
        XCTAssertEqual(model.name, "Songs/Night Drive/master")

        // The button changes the streaming flag and leaves the name alone.
        model.config.streaming.toggle()
        XCTAssertEqual(tap.config, TapConfig(streaming: false, name: "Songs/Night Drive/master"))
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
