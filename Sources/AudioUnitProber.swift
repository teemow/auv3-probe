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
    /// The 4-char component type code (e.g. "aumu", "aufx").
    let typeCode: String
    /// Human-readable type label (e.g. "Instrument", "Effect").
    let typeName: String
    /// Component tags (e.g. "Effects", "Distortion") for categorization.
    let tags: [String]
    let version: String
    let componentDescription: AudioComponentDescription

    init(component: AVAudioUnitComponent) {
        let desc = component.audioComponentDescription
        self.componentDescription = desc
        self.name = component.name
        self.manufacturer = component.manufacturerName
        self.typeCode = FourCharCode.string(from: desc.componentType)
        self.typeName = component.typeName
        self.tags = component.allTagNames
        self.version = component.versionString
        // type/subtype/manufacturer FourCCs uniquely identify a component.
        self.id = "\(FourCharCode.string(from: desc.componentType))"
            + "/\(FourCharCode.string(from: desc.componentSubType))"
            + "/\(FourCharCode.string(from: desc.componentManufacturer))"
    }

    /// The stable id the receiver uses to name staged dumps. Mirrors
    /// `ProbeDump.probeID` so a failed probe (which produces no dump) reports the
    /// same id as a successful one would.
    var probeID: String {
        let subtype = FourCharCode.string(from: componentDescription.componentSubType)
        return ProbeDump.sanitizeID(subtype.isEmpty ? name : subtype)
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

    var errorDescription: String? {
        switch self {
        case .instantiationFailed(let why):
            return "could not instantiate audio unit: \(why)"
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

    /// Instantiate `unit`, read its parameter tree + metadata, and return a
    /// ProbeDump. A unit with no parameter tree returns a dump with zero
    /// parameters (it is valid diagnostic data, not an error) rather than
    /// throwing — only a failed instantiation throws.
    static func probe(_ unit: DiscoveredAudioUnit) async throws -> ProbeDump {
        let avUnit = try await instantiate(unit.componentDescription)
        let auUnit = avUnit.auAudioUnit

        var parameters: [ProbeParam] = []
        if let tree = auUnit.parameterTree {
            parameters = flatten(tree)
        }

        let desc = unit.componentDescription
        let component = ProbeComponent(
            type: FourCharCode.string(from: desc.componentType),
            subtype: FourCharCode.string(from: desc.componentSubType),
            manufacturer: FourCharCode.string(from: desc.componentManufacturer),
            manufacturerName: unit.manufacturer.isEmpty ? nil : unit.manufacturer,
            version: unit.version.isEmpty ? nil : unit.version,
            typeName: unit.typeName.isEmpty ? nil : unit.typeName,
            tags: unit.tags.isEmpty ? nil : unit.tags
        )

        let presets = (auUnit.factoryPresets ?? []).map {
            ProbePreset(number: $0.number, name: $0.name)
        }
        // User presets are only meaningful when the unit supports them; reading
        // the array is safe regardless, but gate to avoid surprises on units
        // that don't.
        let userPresets = auUnit.supportsUserPresets
            ? auUnit.userPresets.map { ProbePreset(number: $0.number, name: $0.name) }
            : []
        let shortName = auUnit.audioUnitShortName

        let channelCaps = (auUnit.channelCapabilities ?? []).map { Int(truncating: $0) }
        let latency = auUnit.latency
        let tailTime = auUnit.tailTime

        return ProbeDump(
            component: component,
            name: unit.name,
            parameters: parameters,
            shortName: (shortName?.isEmpty == false) ? shortName : nil,
            factoryPresets: presets.isEmpty ? nil : presets,
            userPresets: userPresets.isEmpty ? nil : userPresets,
            channelCapabilities: channelCaps.isEmpty ? nil : channelCaps,
            latency: latency > 0 ? latency : nil,
            tailTime: tailTime > 0 ? tailTime : nil,
            supportsUserPresets: auUnit.supportsUserPresets ? true : nil
        )
    }

    /// Number of non-finite values that were sanitized in a dump (for the run
    /// report). Counted here so the model does not re-walk the tree.
    static func sanitizedCount(_ dump: ProbeDump) -> Int {
        dump.parameters.reduce(0) { $0 + ($1.nonFinite != nil ? 1 : 0) }
    }

    // MARK: - Tree walking

    /// Walk the parameter tree depth-first, preserving order and recording each
    /// parameter's parent group displayName, then return a flat [ProbeParam].
    private static func flatten(_ tree: AUParameterTree) -> [ProbeParam] {
        var out: [ProbeParam] = []
        walk(nodes: tree.children, group: nil, into: &out)
        // Fallback: a tree that exposes parameters only via allParameters and
        // not as children still gets dumped.
        if out.isEmpty {
            out = tree.allParameters.map { makeParam($0, group: nil) }
        }
        return out
    }

    private static func walk(nodes: [AUParameterNode], group: String?, into out: inout [ProbeParam]) {
        for node in nodes {
            if let g = node as? AUParameterGroup {
                let name = g.displayName.isEmpty ? g.identifier : g.displayName
                walk(nodes: g.children, group: name, into: &out)
            } else if let p = node as? AUParameter {
                out.append(makeParam(p, group: group))
            }
        }
    }

    // MARK: - Mapping

    private static func makeParam(_ p: AUParameter, group: String?) -> ProbeParam {
        let flags = p.flags
        let unitName = (p.unitName?.isEmpty == false) ? p.unitName : nil
        let valueStrings = p.valueStrings?.isEmpty == false ? p.valueStrings : nil

        let (minV, minNF) = finite(p.minValue)
        let (maxV, maxNF) = finite(p.maxValue)
        let (valV, valNF) = finite(p.value)
        var nonFiniteNotes: [String] = []
        if let n = minNF { nonFiniteNotes.append("min=\(n)") }
        if let n = maxNF { nonFiniteNotes.append("max=\(n)") }
        if let n = valNF { nonFiniteNotes.append("value=\(n)") }

        let isMeta = flags.contains(.flag_IsGlobalMeta) || flags.contains(.flag_IsElementMeta)

        let dependents = (p.dependentParameters ?? []).map { UInt64(truncating: $0) }

        return ProbeParam(
            address: UInt64(p.address),
            keyPath: p.keyPath,
            identifier: p.identifier,
            displayName: p.displayName,
            min: minV,
            max: maxV,
            value: valV,
            unit: unitString(p.unit),
            unitName: unitName,
            valueStrings: valueStrings,
            writable: flags.contains(.flag_IsWritable),
            readable: flags.contains(.flag_IsReadable),
            group: (group?.isEmpty == false) ? group : nil,
            flags: flags.rawValue,
            displayLogarithmic: flags.contains(.flag_DisplayLogarithmic) ? true : nil,
            displayExponential: flags.contains(.flag_DisplayExponential) ? true : nil,
            isHighResolution: flags.contains(.flag_IsHighResolution) ? true : nil,
            isRampable: flags.contains(.flag_CanRamp) ? true : nil,
            isMeta: isMeta ? true : nil,
            dependentParameters: dependents.isEmpty ? nil : dependents,
            nonFinite: nonFiniteNotes.isEmpty ? nil : nonFiniteNotes.joined(separator: " ")
        )
    }

    /// Map a (possibly non-finite) AUValue to a finite Double for transport.
    /// JSON and Go's encoding/json cannot carry ±Inf / NaN, so they are clamped
    /// to finite sentinels; the second return value names what was clamped (nil
    /// when the value was already finite).
    private static func finite(_ v: AUValue) -> (Double, String?) {
        if v.isNaN { return (0, "nan") }
        if v == .infinity { return (Double(Float.greatestFiniteMagnitude), "+inf") }
        if v == -.infinity { return (Double(-Float.greatestFiniteMagnitude), "-inf") }
        return (Double(v), nil)
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
        case .midi2Controller: return "midi2Controller"
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
