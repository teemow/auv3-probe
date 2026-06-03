import Foundation
import AVFoundation
import AudioToolbox

// AudioUnitProber enumerates the AUv3 components installed on the device and,
// for a chosen one, walks its AUParameterTree into a ProbeDump. Enumeration is
// instance-independent (any instance of a plugin has the same tree as the one
// AUM hosts), so no audio engine is needed — we instantiate, read the tree, and
// throw the instance away. See docs/research/auv3-feedback.md in the main repo.

/// A plugin discovered by `AVAudioUnitComponentManager`. `Identifiable` so it
/// drops straight into a SwiftUI `List` with multi-select.
struct DiscoveredAudioUnit: Identifiable, Hashable {
    let id: String
    let name: String
    let manufacturer: String
    let typeName: String
    let componentDescription: AudioComponentDescription

    init(component: AVAudioUnitComponent) {
        let desc = component.audioComponentDescription
        self.componentDescription = desc
        self.name = component.name
        self.manufacturer = component.manufacturerName
        self.typeName = FourCharCode.string(from: desc.componentType)
        // type/subtype/manufacturer FourCCs uniquely identify a component.
        self.id = "\(FourCharCode.string(from: desc.componentType))"
            + "/\(FourCharCode.string(from: desc.componentSubType))"
            + "/\(FourCharCode.string(from: desc.componentManufacturer))"
    }

    // AudioComponentDescription is not Hashable/Equatable, so key both off the
    // already-unique component id rather than synthesizing over all fields.
    static func == (lhs: DiscoveredAudioUnit, rhs: DiscoveredAudioUnit) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum ProbeError: LocalizedError {
    case instantiationFailed(String)
    case noParameterTree

    var errorDescription: String? {
        switch self {
        case .instantiationFailed(let why):
            return "could not instantiate audio unit: \(why)"
        case .noParameterTree:
            return "audio unit exposes no parameter tree"
        }
    }
}

enum AudioUnitProber {
    /// The component types we care about: instruments (`aumu`), effects
    /// (`aufx`) and music effects (`aumf`).
    static let probedTypes: [OSType] = [
        kAudioUnitType_MusicDevice,   // aumu
        kAudioUnitType_Effect,        // aufx
        kAudioUnitType_MusicEffect,   // aumf
    ]

    /// Enumerate installed AUv3s of the probed types, sorted by name.
    static func discover() -> [DiscoveredAudioUnit] {
        let manager = AVAudioUnitComponentManager.shared()
        let probed = Set(probedTypes)
        let components = manager.components { component, _ in
            probed.contains(component.audioComponentDescription.componentType)
        }
        return components
            .map(DiscoveredAudioUnit.init)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Instantiate `unit`, read its parameter tree, and return a ProbeDump.
    static func probe(_ unit: DiscoveredAudioUnit) async throws -> ProbeDump {
        let avUnit = try await instantiate(unit.componentDescription)
        let auUnit = avUnit.auAudioUnit
        guard let tree = auUnit.parameterTree else {
            throw ProbeError.noParameterTree
        }

        let parameters = tree.allParameters.map(makeParam)
        let desc = unit.componentDescription
        let component = ProbeComponent(
            type: FourCharCode.string(from: desc.componentType),
            subtype: FourCharCode.string(from: desc.componentSubType),
            manufacturer: FourCharCode.string(from: desc.componentManufacturer)
        )
        return ProbeDump(component: component, name: unit.name, parameters: parameters)
    }

    // MARK: - Mapping

    private static func makeParam(_ p: AUParameter) -> ProbeParam {
        let flags = p.flags
        let unitName = (p.unitName?.isEmpty == false) ? p.unitName : nil
        let valueStrings = p.valueStrings?.isEmpty == false ? p.valueStrings : nil
        return ProbeParam(
            address: UInt64(p.address),
            keyPath: p.keyPath,
            identifier: p.identifier,
            displayName: p.displayName,
            min: Double(p.minValue),
            max: Double(p.maxValue),
            value: Double(p.value),
            unit: unitString(p.unit),
            unitName: unitName,
            valueStrings: valueStrings,
            writable: flags.contains(.flag_IsWritable),
            readable: flags.contains(.flag_IsReadable)
        )
    }

    private static func instantiate(_ desc: AudioComponentDescription) async throws -> AVAudioUnit {
        try await withCheckedThrowingContinuation { continuation in
            AVAudioUnit.instantiate(with: desc, options: []) { avUnit, error in
                if let error = error {
                    continuation.resume(throwing: ProbeError.instantiationFailed(error.localizedDescription))
                } else if let avUnit = avUnit {
                    continuation.resume(returning: avUnit)
                } else {
                    continuation.resume(throwing: ProbeError.instantiationFailed("no unit and no error"))
                }
            }
        }
    }

    /// Render an `AudioUnitParameterUnit` to a stable lowercase token, matching
    /// the human-readable units recorded in the dump (e.g. "generic", "hertz").
    private static func unitString(_ unit: AudioUnitParameterUnit) -> String {
        switch unit {
        case .generic: return "generic"
        case .indexed: return "indexed"
        case .boolean: return "boolean"
        case .percent: return "percent"
        case .seconds: return "seconds"
        case .sampleFrames: return "sampleFrames"
        case .phase: return "phase"
        case .rate: return "rate"
        case .hertz: return "hertz"
        case .cents: return "cents"
        case .relativeSemiTones: return "relativeSemiTones"
        case .midiNoteNumber: return "midiNoteNumber"
        case .midiController: return "midiController"
        case .decibels: return "decibels"
        case .linearGain: return "linearGain"
        case .degrees: return "degrees"
        case .equalPowerCrossfade: return "equalPowerCrossfade"
        case .mixerFaderCurve1: return "mixerFaderCurve1"
        case .pan: return "pan"
        case .meters: return "meters"
        case .absoluteCents: return "absoluteCents"
        case .octaves: return "octaves"
        case .BPM: return "bpm"
        case .beats: return "beats"
        case .milliseconds: return "milliseconds"
        case .ratio: return "ratio"
        case .customUnit: return "customUnit"
        @unknown default: return "generic"
        }
    }
}

extension FourCharCode {
    /// Render a FourCharCode (`OSType`) as its 4-character string (e.g. "aumu").
    /// Non-printable bytes become "?" so the output stays human-readable.
    static func string(from code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        let chars = bytes.map { byte -> Character in
            (byte >= 0x20 && byte < 0x7F) ? Character(UnicodeScalar(byte)) : "?"
        }
        return String(chars)
    }
}
