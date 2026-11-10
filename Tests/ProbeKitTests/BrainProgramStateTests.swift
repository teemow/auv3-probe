import XCTest
import ProbeKit

// A host keeps ProbeMidiBrain's program in its session and hands it back
// through the AU's `fullState`: JSON bytes under `BrainProgram.fullStateKey`.
// AUM saves it that way, and the mcp-midi-controller daemon authors the same
// key into the sessions it writes. These are both shapes, byte for byte.
final class BrainProgramStateTests: XCTestCase {
    /// What the daemon authors for a song: a program that does nothing, so the
    /// brain sends no scene changes of its own.
    private let authoredEmpty =
        #"{"sections":[],"footswitches":[],"outputChannel":16,"sceneChangeMode":"programChange","sceneCC":0}"#

    /// What AUM saved for a brain running the demo program
    /// (docs/captureprobe_2.aumproj).
    private let savedByAUM =
        #"{"sceneChangeMode":"programChange","sceneCC":0,"footswitches":[{"number":64,"kind":"controlChange","action":{"next":{}},"id":"C3B8B28D-B318-4BC1-93DD-FFE344029E9A","channel":0}],"outputChannel":1,"sections":[{"startBeat":0,"scene":0,"name":"intro","id":"893FD90D-1FD6-4EB1-85F6-1DEB8D216DE7"},{"startBeat":16,"scene":1,"name":"main","id":"81F82F27-C4AC-471B-884A-0D439CC04887"}]}"#

    /// A node's state as AUM stores it: the component identity next to the
    /// plugin's own keys.
    private func state(program: Any?) -> [String: Any] {
        var state: [String: Any] = [
            "type": 1_635_085_673, "subtype": 1_885_490_537, "manufacturer": 1_416_458_103, "version": 1,
        ]
        state[BrainProgram.fullStateKey] = program
        return state
    }

    func testTheKeyIsTheOneTheDaemonAuthors() {
        XCTAssertEqual(BrainProgram.fullStateKey, "probeMidiBrainProgram")
    }

    func testRestoresTheEmptyProgramTheDaemonAuthors() {
        let restored = BrainProgram.restored(fromFullState: state(program: Data(authoredEmpty.utf8)))
        XCTAssertEqual(restored, BrainProgram(sections: [], footswitches: [], outputChannel: 16,
                                              sceneChangeMode: .programChange, sceneCC: 0))
    }

    func testRestoresAProgramSavedByAUM() throws {
        let restored = try XCTUnwrap(BrainProgram.restored(fromFullState: state(program: Data(savedByAUM.utf8))))
        XCTAssertEqual(restored.sections.map(\.name), ["intro", "main"])
        XCTAssertEqual(restored.sections.map(\.startBeat), [0, 16])
        XCTAssertEqual(restored.sections.map(\.scene), [0, 1])
        XCTAssertEqual(restored.footswitches.map(\.number), [64])
        XCTAssertEqual(restored.footswitches.map(\.action), [.next])
        XCTAssertEqual(restored.outputChannel, 1)
    }

    func testAProgramSurvivesTheRoundTrip() throws {
        let program = BrainProgram(
            sections: [SongSection(name: "verse", startBeat: 8, scene: 3)],
            footswitches: [FootswitchMapping(kind: .note, number: 60, channel: 2, action: .scene(5))],
            outputChannel: 9, sceneChangeMode: .controlChange, sceneCC: 21)
        let data = try XCTUnwrap(program.fullStateData)
        XCTAssertEqual(BrainProgram.restored(fromFullState: state(program: data)), program)
    }

    func testAStateWithoutAUsableProgramRestoresNone() {
        // Only the identity, as for a node saved before it had a program.
        XCTAssertNil(BrainProgram.restored(fromFullState: state(program: nil)))
        XCTAssertNil(BrainProgram.restored(fromFullState: nil))
        // Not bytes.
        XCTAssertNil(BrainProgram.restored(fromFullState: state(program: authoredEmpty)))
        // Bytes that are not a program.
        XCTAssertNil(BrainProgram.restored(fromFullState: state(program: Data(#"{"sections":[]}"#.utf8))))
        XCTAssertNil(BrainProgram.restored(fromFullState: state(program: Data())))
    }
}
