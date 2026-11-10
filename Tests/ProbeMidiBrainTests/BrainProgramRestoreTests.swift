import XCTest
import AudioToolbox
import ProbeKit

// A host restores the brain's program through `fullState` whenever it likes.
// AUM does it right after creating the unit, and by then iOS may already have
// built the plugin's view. These tests drive the real audio unit and its view
// model the way a host does: create, maybe open the window, restore.
//
// An app extension cannot be imported, so project.yml compiles the extension's
// sources into this bundle.
final class BrainProgramRestoreTests: XCTestCase {
    /// What the daemon authors for a song: a program that does nothing, so the
    /// brain sends no scene changes of its own.
    private let authoredEmpty =
        #"{"sections":[],"footswitches":[],"outputChannel":16,"sceneChangeMode":"programChange","sceneCC":0}"#
    private let emptyProgram = BrainProgram(sections: [], footswitches: [], outputChannel: 16,
                                            sceneChangeMode: .programChange, sceneCC: 0)

    private let componentType = FourCharCode.from(string: "aumi")
    private let componentSubType = FourCharCode.from(string: "pbMi")
    private let componentManufacturer = FourCharCode.from(string: "Tmow")

    private func makeBrain() throws -> ProbeMidiBrainAU {
        try ProbeMidiBrainAU(componentDescription: AudioComponentDescription(
            componentType: componentType, componentSubType: componentSubType,
            componentManufacturer: componentManufacturer,
            componentFlags: 0, componentFlagsMask: 0))
    }

    /// A node's state as AUM stores it in a session (`AuStateDoc`) and hands it
    /// to `fullState`: the component identity next to the plugin's own keys.
    private func sessionState(program json: String?) -> [String: Any] {
        var state: [String: Any] = [
            "type": Int(componentType), "subtype": Int(componentSubType),
            "manufacturer": Int(componentManufacturer), "version": 1,
        ]
        if let json { state[BrainProgram.fullStateKey] = Data(json.utf8) }
        return state
    }

    // MARK: - The audio unit

    func testAFreshBrainRunsTheDemo() throws {
        XCTAssertEqual(try makeBrain().program.sections.map(\.name), ["intro", "main"])
    }

    func testRestoringAnAuthoredEmptyProgramReplacesTheDemo() throws {
        let brain = try makeBrain()
        brain.fullState = sessionState(program: authoredEmpty)
        XCTAssertEqual(brain.program, emptyProgram)
    }

    func testAStateWithoutAProgramKeepsTheCurrentOne() throws {
        let brain = try makeBrain()
        brain.updateProgram(emptyProgram)
        brain.fullState = sessionState(program: nil)
        XCTAssertEqual(brain.program, emptyProgram)
    }

    func testTheSavedStateRestoresIntoAnotherBrain() throws {
        let saved = try makeBrain()
        saved.updateProgram(emptyProgram)
        let state = try XCTUnwrap(saved.fullState)
        XCTAssertEqual(state[BrainProgram.fullStateKey] as? Data, emptyProgram.fullStateData)

        let loaded = try makeBrain()
        loaded.fullState = state
        XCTAssertEqual(loaded.program, emptyProgram)
    }

    // MARK: - The window

    /// The defect: AUM restored the session's empty program, the window went
    /// on listing the demo's sections.
    @MainActor
    func testAnOpenWindowFollowsARestore() throws {
        let brain = try makeBrain()
        let model = BrainViewModel(audioUnit: brain)
        XCTAssertEqual(model.program.sections.count, 2)

        brain.fullState = sessionState(program: authoredEmpty)
        model.poll()

        XCTAssertEqual(model.program, emptyProgram)
        XCTAssertEqual(brain.program, emptyProgram)
    }

    @MainActor
    func testAnEditReachesTheAudioUnitAtOnce() throws {
        let brain = try makeBrain()
        let model = BrainViewModel(audioUnit: brain)

        model.program.outputChannel = 7
        XCTAssertEqual(brain.program.outputChannel, 7)

        model.addSection()
        XCTAssertEqual(brain.program.sections.count, 3)

        // The next poll finds nothing to adopt and leaves the edits alone.
        model.poll()
        XCTAssertEqual(model.program.outputChannel, 7)
        XCTAssertEqual(model.program.sections.count, 3)
        XCTAssertEqual(brain.program, model.program)
    }

    /// An edit in a window that was open across a restore must build on the
    /// restored program, not write the earlier one back.
    @MainActor
    func testAnEditAfterARestoreBuildsOnTheRestoredProgram() throws {
        let brain = try makeBrain()
        let model = BrainViewModel(audioUnit: brain)

        brain.fullState = sessionState(program: authoredEmpty)
        model.poll()
        model.addSection()

        XCTAssertEqual(brain.program.sections.count, 1)
        XCTAssertEqual(brain.program.footswitches, [])
        XCTAssertEqual(brain.program.outputChannel, 16)
    }
}
