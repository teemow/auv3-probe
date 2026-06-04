import Foundation

// The data model the ProbeMidiBrain (`aumi`) extension authors and evaluates:
// a song laid out as ordered sections (each pinned to a musical position), plus
// a footswitch map (incoming MIDI -> scene action). It is a plain value type so
// it can be (a) authored in SwiftUI, (b) persisted in the AU's `fullState`, and
// (c) snapshotted and read by the realtime render thread without allocating.
//
// "Scenes" here are AUM sessions/scenes recalled by MIDI: AUM is fully MIDI
// controllable and can load a full session from a single MIDI message, so the
// brain emits a Program Change (or CC) at section boundaries and on footswitch
// actions, and AUM (or downstream AUs) react.
//
// Lives in ProbeKit so both the extension and a future app authoring tab share
// one model + one evaluator.

/// How the brain encodes a scene change on its MIDI output.
public enum SceneChangeMode: String, Codable, Equatable, Sendable, CaseIterable {
    /// MIDI Program Change with the scene index as the program number.
    case programChange
    /// MIDI Control Change on `sceneCC` with the scene index as the value.
    case controlChange
}

/// One section of the song, pinned to an absolute musical position (in beats
/// from the start of the host timeline). When the transport crosses a section's
/// `startBeat`, the brain recalls `scene`.
public struct SongSection: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Absolute beat position where this section begins (0 = bar 1, beat 1).
    public var startBeat: Double
    /// Scene/session index to recall at this boundary (0-based program number).
    public var scene: Int

    public init(id: UUID = UUID(), name: String, startBeat: Double, scene: Int) {
        self.id = id
        self.name = name
        self.startBeat = startBeat
        self.scene = scene
    }
}

/// The kind of incoming MIDI that triggers a footswitch action.
public enum TriggerKind: String, Codable, Equatable, Sendable, CaseIterable {
    case note
    case controlChange
    case programChange
}

/// What a footswitch press does.
public enum SceneAction: Codable, Equatable, Sendable {
    /// Recall a specific scene index.
    case scene(Int)
    /// Advance to the next section's scene.
    case next
    /// Return to the previous section's scene.
    case previous
}

/// One footswitch mapping: an incoming MIDI message (the "threefoot" pedal,
/// routed in by AUM) -> a scene action the brain emits.
public struct FootswitchMapping: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: TriggerKind
    /// Note number / CC number / program number to match (0-127).
    public var number: Int
    /// MIDI channel to match (1-16), or 0 to match any channel.
    public var channel: Int
    public var action: SceneAction

    public init(id: UUID = UUID(), kind: TriggerKind, number: Int, channel: Int, action: SceneAction) {
        self.id = id
        self.kind = kind
        self.number = number
        self.channel = channel
        self.action = action
    }
}

/// The full program the brain runs: the song structure, the footswitch map, and
/// the output encoding. Persisted in the AU `fullState`.
public struct BrainProgram: Codable, Equatable, Sendable {
    public var sections: [SongSection]
    public var footswitches: [FootswitchMapping]
    /// MIDI channel (1-16) the brain emits scene changes on.
    public var outputChannel: Int
    public var sceneChangeMode: SceneChangeMode
    /// CC number used when `sceneChangeMode == .controlChange`.
    public var sceneCC: Int

    public init(sections: [SongSection] = [],
                footswitches: [FootswitchMapping] = [],
                outputChannel: Int = 1,
                sceneChangeMode: SceneChangeMode = .programChange,
                sceneCC: Int = 0) {
        self.sections = sections
        self.footswitches = footswitches
        self.outputChannel = outputChannel
        self.sceneChangeMode = sceneChangeMode
        self.sceneCC = sceneCC
    }

    /// A small starter program so a freshly-inserted brain does something
    /// visible: two sections (intro at bar 1, main at bar 5 in 4/4) and a single
    /// footswitch (CC64 = sustain pedal style) that advances the scene.
    public static var demo: BrainProgram {
        BrainProgram(
            sections: [
                SongSection(name: "intro", startBeat: 0, scene: 0),
                SongSection(name: "main", startBeat: 16, scene: 1),
            ],
            footswitches: [
                FootswitchMapping(kind: .controlChange, number: 64, channel: 0, action: .next),
            ]
        )
    }

    /// The sections sorted by start position — the order the evaluator walks.
    public var orderedSections: [SongSection] {
        sections.sorted { $0.startBeat < $1.startBeat }
    }

    /// Index (into `orderedSections`) of the section active at `beat`, or nil if
    /// `beat` precedes the first section.
    public func sectionIndex(atBeat beat: Double) -> Int? {
        let ordered = orderedSections
        var result: Int?
        for (i, section) in ordered.enumerated() where section.startBeat <= beat {
            result = i
        }
        return result
    }
}
