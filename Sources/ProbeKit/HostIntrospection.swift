import Foundation
import AVFoundation
import AudioToolbox
import CoreMIDI
import os
#if canImport(UIKit)
import UIKit
#endif

// HostDiagnostics is the measured snapshot of everything an AUv3 appex can see
// about its surroundings while hosted (inside AUM). It is the data side of the
// "what can the brain read?" analysis (see docs/auv3-extension.md and the host
// diagnostics redesign). The schema is split into three provenance classes:
//
//   - SANCTIONED (AUv3 host blocks): the transport flags/position and full
//     musical context the host blocks hand the render thread, plus the render
//     `AudioTimeStamp` (sampleTime/hostTime/rateScalar). These are realtime-only
//     reads, captured on the render thread and published via the engine's
//     lock/ring, then merged in here by the reporter.
//   - AU SURFACE (off-thread reads on the `AUAudioUnit`): the appex's own
//     identity, capabilities, render config, MIDI protocol negotiation, and
//     MIDI-CI profiles — everything the AUv3 API exposes about the loaded unit.
//   - BACKDOORS (system frameworks reachable from the appex sandbox):
//       * AVAudioSession — full route, channel, latency, and other-audio surface.
//       * CoreMIDI — every visible endpoint/device and its properties (reveals
//         whether the appex can see AUM's virtual ports or other apps' endpoints).
//       * ProcessInfo / UIDevice — the runtime environment (thermal, power, OS).
//
// The struct is Codable so it round-trips to JSON for the `/diagnostics`
// WebSocket stream and the os_log fallback dump (read on Linux via
// idevicesyslog), and renders verbatim in the AU's introspection panel. All
// collectors below are pure reads, safe to call off the render thread (from the
// reporter timer / UI); the sanctioned fields are merged in by the reporter from
// the render-thread snapshot.
//
// `HostIntrospection` remains as a source-compatible alias for the older name.
public struct HostDiagnostics: Codable, Sendable, Equatable {
    /// os_log channel for the whole probe (subsystem shared with idevicesyslog).
    public static let log = Logger(subsystem: "com.teemow.auv3probe", category: "introspection")

    /// Wire-contract version of this envelope (bump on breaking schema changes).
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var capturedAt: Date
    public var source: String
    public var transport: Transport
    public var musicalContext: MusicalContext
    public var renderTime: RenderTimestamp
    public var render: Render
    public var audioUnit: AudioUnitInfo
    public var midi: MIDINegotiation
    public var audioSession: AudioSession
    public var coreMIDI: CoreMIDISnapshot
    public var environment: Environment

    public init(schemaVersion: Int = HostDiagnostics.currentSchemaVersion,
                capturedAt: Date = Date(),
                source: String = "",
                transport: Transport = Transport(),
                musicalContext: MusicalContext = MusicalContext(),
                renderTime: RenderTimestamp = RenderTimestamp(),
                render: Render = Render(),
                audioUnit: AudioUnitInfo = AudioUnitInfo(),
                midi: MIDINegotiation = MIDINegotiation(),
                audioSession: AudioSession = AudioSession(),
                coreMIDI: CoreMIDISnapshot = CoreMIDISnapshot(),
                environment: Environment = Environment()) {
        self.schemaVersion = schemaVersion
        self.capturedAt = capturedAt
        self.source = source
        self.transport = transport
        self.musicalContext = musicalContext
        self.renderTime = renderTime
        self.render = render
        self.audioUnit = audioUnit
        self.midi = midi
        self.audioSession = audioSession
        self.coreMIDI = coreMIDI
        self.environment = environment
    }

    // MARK: - Sanctioned (AUv3 host blocks), captured on the render thread

    /// AUHostTransportStateBlock readback.
    public struct Transport: Codable, Sendable, Equatable {
        public var available = false
        public var moving = false
        public var recording = false
        public var cycling = false
        public var samplePosition: Double = 0
        public var cycleStartBeat: Double = 0
        public var cycleEndBeat: Double = 0
        public init() {}
    }

    /// AUHostMusicalContextBlock readback (which fields does AUM actually fill?).
    public struct MusicalContext: Codable, Sendable, Equatable {
        public var available = false
        public var tempo: Double = 0
        public var timeSignatureNumerator: Double = 0
        public var timeSignatureDenominator: Int = 0
        public var currentBeatPosition: Double = 0
        public var sampleOffsetToNextBeat: Int = 0
        public var currentMeasureDownbeatPosition: Double = 0
        public init() {}
    }

    /// The render `AudioTimeStamp` the host passes the render block — captured on
    /// the render thread alongside the host blocks. Reveals whether AUM provides
    /// a host clock (`mHostTime`) and a non-1.0 `mRateScalar` (varispeed).
    public struct RenderTimestamp: Codable, Sendable, Equatable {
        public var available = false
        public var sampleTime: Double = 0
        public var hostTime: UInt64 = 0
        public var rateScalar: Double = 0
        public init() {}
    }

    // MARK: - AU surface (off-thread reads on the AUAudioUnit)

    /// AU render configuration the host negotiated (the existing slice; kept for
    /// the panel). The fuller identity/capability surface is in `AudioUnitInfo`.
    public struct Render: Codable, Sendable, Equatable {
        public var maximumFramesToRender: Int = 0
        public var midiOutputNames: [String] = []
        public var outputBusFormats: [String] = []
        public init() {}
    }

    /// The AUv3 unit's own identity + capabilities, read off-thread from the
    /// `AUAudioUnit`. Exhaustively mirrors the `AUAudioUnit` header surface.
    public struct AudioUnitInfo: Codable, Sendable, Equatable {
        public var available = false
        // AudioComponentDescription (FourCC strings + flags).
        public var componentType = ""
        public var componentSubType = ""
        public var componentManufacturer = ""
        public var componentFlags: UInt32 = 0
        public var componentFlagsMask: UInt32 = 0
        // Names.
        public var componentName = ""
        public var audioUnitName = ""
        public var audioUnitShortName = ""
        public var manufacturerName = ""
        public var contextName = ""
        public var componentVersion: UInt32 = 0
        // Capabilities.
        public var musicDeviceOrEffect = false
        public var virtualMIDICableCount = 0
        public var channelCapabilities: [Int] = []
        public var supportsMPE = false
        public var channelMap: [Int] = []
        public var latency: Double = 0
        public var tailTime: Double = 0
        public var maximumFramesToRender: UInt32 = 0
        public var renderResourcesAllocated = false
        public var isRenderingOffline = false
        public var canProcessInPlace = false
        public var providesUserInterface = false
        public var supportsUserPresets = false
        public var factoryPresets: [String] = []
        public var userPresets: [String] = []
        public var parameterTree = ParameterTreeSummary()
        public init() {}

        /// A bounded summary of the AU's `AUParameterTree` (full counts + a capped
        /// list, so a 3000-parameter plugin doesn't bloat the snapshot).
        public struct ParameterTreeSummary: Codable, Sendable, Equatable {
            public var available = false
            public var count = 0
            public var truncated = false
            public var parameters: [Parameter] = []
            public init() {}

            public struct Parameter: Codable, Sendable, Equatable {
                public var address: UInt64
                public var identifier: String
                public var displayName: String
                public var minValue: Float
                public var maxValue: Float
                public var value: Float
                public var unit: Int
                public var unitName: String
                public init(address: UInt64 = 0, identifier: String = "", displayName: String = "",
                            minValue: Float = 0, maxValue: Float = 0, value: Float = 0,
                            unit: Int = 0, unitName: String = "") {
                    self.address = address
                    self.identifier = identifier
                    self.displayName = displayName
                    self.minValue = minValue
                    self.maxValue = maxValue
                    self.value = value
                    self.unit = unit
                    self.unitName = unitName
                }
            }
        }
    }

    /// MIDI protocol negotiation + MIDI-CI profile state, read off-thread from the
    /// `AUAudioUnit`. Reveals whether AUM is driving the unit with MIDI 1.0 or 2.0
    /// and which MIDI-CI profiles are enabled per cable/channel.
    public struct MIDINegotiation: Codable, Sendable, Equatable {
        public var available = false
        public var hostMIDIProtocol = ""
        public var audioUnitMIDIProtocol = ""
        public var profiles: [Profile] = []
        public init() {}

        /// MIDI-CI profile state for one (cable, channel), from
        /// `profileState(forCable:channel:)`. Only non-empty states are kept.
        public struct Profile: Codable, Sendable, Equatable {
            public var cable: Int
            public var channel: Int
            public var enabled: [String]
            public var disabled: [String]
            public init(cable: Int = 0, channel: Int = 0, enabled: [String] = [], disabled: [String] = []) {
                self.cable = cable
                self.channel = channel
                self.enabled = enabled
                self.disabled = disabled
            }
        }
    }

    // MARK: - Backdoors (system frameworks)

    /// AVAudioSession state visible from the appex (full route/channel/latency).
    public struct AudioSession: Codable, Sendable, Equatable {
        public var sampleRate: Double = 0
        public var preferredSampleRate: Double = 0
        public var ioBufferDuration: Double = 0
        public var preferredIOBufferDuration: Double = 0
        public var category: String = ""
        public var categoryOptions: [String] = []
        public var mode: String = ""
        public var routeSharingPolicy: String = ""
        public var isOtherAudioPlaying = false
        public var secondaryAudioShouldBeSilencedHint = false
        public var outputLatency: Double = 0
        public var inputLatency: Double = 0
        public var inputAvailable = false
        public var inputNumberOfChannels = 0
        public var outputNumberOfChannels = 0
        public var preferredInputNumberOfChannels = 0
        public var preferredOutputNumberOfChannels = 0
        public var maximumInputNumberOfChannels = 0
        public var maximumOutputNumberOfChannels = 0
        public var inputGain: Double = 0
        public var isInputGainSettable = false
        public var inputPorts: [String] = []
        public var outputPorts: [String] = []
        public var availableInputs: [String] = []
        public init() {}
    }

    /// The CoreMIDI graph as the appex can enumerate it, with per-endpoint and
    /// per-device properties.
    public struct CoreMIDISnapshot: Codable, Sendable, Equatable {
        public var sources: [Endpoint] = []
        public var destinations: [Endpoint] = []
        public var devices: [Device] = []
        public var externalDevices: [Device] = []
        public init() {}

        public struct Endpoint: Codable, Sendable, Equatable {
            public var name: String
            public var displayName: String
            public var entity: String
            public var device: String
            public var uniqueID: Int32
            public var manufacturer: String
            public var model: String
            public var protocolID: Int
            public var receiveChannels: Int32
            public var transmitChannels: Int32
            public var offline: Bool
            public var isPrivate: Bool
            public var driverOwner: String
            public init(name: String = "", displayName: String = "", entity: String = "",
                        device: String = "", uniqueID: Int32 = 0, manufacturer: String = "",
                        model: String = "", protocolID: Int = 0, receiveChannels: Int32 = 0,
                        transmitChannels: Int32 = 0, offline: Bool = false, isPrivate: Bool = false,
                        driverOwner: String = "") {
                self.name = name
                self.displayName = displayName
                self.entity = entity
                self.device = device
                self.uniqueID = uniqueID
                self.manufacturer = manufacturer
                self.model = model
                self.protocolID = protocolID
                self.receiveChannels = receiveChannels
                self.transmitChannels = transmitChannels
                self.offline = offline
                self.isPrivate = isPrivate
                self.driverOwner = driverOwner
            }
        }

        public struct Device: Codable, Sendable, Equatable {
            public var name: String
            public var manufacturer: String
            public var model: String
            public var driverOwner: String
            public var uniqueID: Int32
            public var offline: Bool
            public var isPrivate: Bool
            public init(name: String = "", manufacturer: String = "", model: String = "",
                        driverOwner: String = "", uniqueID: Int32 = 0,
                        offline: Bool = false, isPrivate: Bool = false) {
                self.name = name
                self.manufacturer = manufacturer
                self.model = model
                self.driverOwner = driverOwner
                self.uniqueID = uniqueID
                self.offline = offline
                self.isPrivate = isPrivate
            }
        }
    }

    /// Runtime environment (ProcessInfo + UIDevice) — thermal/power pressure and
    /// OS/device identity that can affect realtime behaviour.
    public struct Environment: Codable, Sendable, Equatable {
        public var thermalState = ""
        public var lowPowerModeEnabled = false
        public var physicalMemory: UInt64 = 0
        public var activeProcessorCount = 0
        public var processorCount = 0
        public var systemUptime: Double = 0
        public var osVersion = ""
        public var deviceModel = ""
        public var deviceSystemName = ""
        public var deviceSystemVersion = ""
        public init() {}
    }

    /// Pretty JSON for the on-device display and the wire stream (the AU panel
    /// renders fields directly; this is the "copy/send the whole snapshot" form).
    public func prettyJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return "<introspection encode failed>"
        }
        return string
    }

    /// Compact single-line JSON of the whole envelope, for the `/diagnostics`
    /// WebSocket TEXT frame (no whitespace; smallest wire footprint).
    public func jsonData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(self)
    }

    /// Compact single-line JSON for one Encodable section. Short enough that the
    /// unified-log never truncates it (the whole-snapshot pretty form exceeds the
    /// os_log per-message string cap and gets cut with `<…>`).
    private static func compact<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    /// Dump the snapshot to os_log under `com.teemow.auv3probe`, ONE compact line
    /// per section (and one line per CoreMIDI endpoint), all at `.notice` so they
    /// stream reliably to `idevicesyslog` on Linux without truncation. This is the
    /// fallback sink when the `/diagnostics` stream is unavailable.
    public func log(prefix: String = "host-introspection") {
        let log = Self.log
        log.notice("\(prefix, privacy: .public) at=\(Self.compact(self.capturedAt), privacy: .public) v=\(self.schemaVersion) source=\(self.source, privacy: .public)")
        log.notice("\(prefix, privacy: .public) transport=\(Self.compact(self.transport), privacy: .public)")
        log.notice("\(prefix, privacy: .public) musical=\(Self.compact(self.musicalContext), privacy: .public)")
        log.notice("\(prefix, privacy: .public) renderTime=\(Self.compact(self.renderTime), privacy: .public)")
        log.notice("\(prefix, privacy: .public) render=\(Self.compact(self.render), privacy: .public)")
        log.notice("\(prefix, privacy: .public) audioUnit=\(Self.compact(self.audioUnit), privacy: .public)")
        log.notice("\(prefix, privacy: .public) midi=\(Self.compact(self.midi), privacy: .public)")
        log.notice("\(prefix, privacy: .public) audioSession=\(Self.compact(self.audioSession), privacy: .public)")
        log.notice("\(prefix, privacy: .public) environment=\(Self.compact(self.environment), privacy: .public)")
        log.notice("\(prefix, privacy: .public) coreMIDI counts src=\(self.coreMIDI.sources.count) dst=\(self.coreMIDI.destinations.count) dev=\(self.coreMIDI.devices.count) ext=\(self.coreMIDI.externalDevices.count)")
        for (index, endpoint) in coreMIDI.sources.enumerated() {
            log.notice("\(prefix, privacy: .public) src[\(index)]=\(Self.compact(endpoint), privacy: .public)")
        }
        for (index, endpoint) in coreMIDI.destinations.enumerated() {
            log.notice("\(prefix, privacy: .public) dst[\(index)]=\(Self.compact(endpoint), privacy: .public)")
        }
    }
}

/// Source-compatible alias for the previous name of the envelope.
public typealias HostIntrospection = HostDiagnostics

// MARK: - Collectors

/// Reads the off-thread diagnostic surfaces (AU identity/capabilities, MIDI
/// negotiation, AVAudioSession, CoreMIDI, environment). These are plain reads
/// with no realtime constraints — call them from the reporter timer / UI, never
/// the render thread. The sanctioned host-block fields (transport, musical
/// context, render timestamp) are captured separately on the render thread and
/// merged in by the reporter.
public enum HostDiagnosticsCollector {
    // MARK: AU surface

    /// Read the AUv3 unit's identity + capabilities from its `AUAudioUnit`.
    public static func audioUnit(_ au: AUAudioUnit) -> HostDiagnostics.AudioUnitInfo {
        var info = HostDiagnostics.AudioUnitInfo()
        info.available = true
        let cd = au.componentDescription
        info.componentType = FourCharCode.string(from: cd.componentType)
        info.componentSubType = FourCharCode.string(from: cd.componentSubType)
        info.componentManufacturer = FourCharCode.string(from: cd.componentManufacturer)
        info.componentFlags = cd.componentFlags
        info.componentFlagsMask = cd.componentFlagsMask
        info.componentName = au.componentName ?? ""
        info.audioUnitName = au.audioUnitName ?? ""
        info.audioUnitShortName = au.audioUnitShortName ?? ""
        info.manufacturerName = au.manufacturerName ?? ""
        info.contextName = au.contextName ?? ""
        info.componentVersion = au.componentVersion
        info.musicDeviceOrEffect = au.isMusicDeviceOrEffect
        info.virtualMIDICableCount = au.virtualMIDICableCount
        info.channelCapabilities = (au.channelCapabilities ?? []).map { $0.intValue }
        info.supportsMPE = au.supportsMPE
        info.channelMap = (au.channelMap ?? []).map { $0.intValue }
        info.latency = au.latency
        info.tailTime = au.tailTime
        info.maximumFramesToRender = au.maximumFramesToRender
        info.renderResourcesAllocated = au.renderResourcesAllocated
        info.isRenderingOffline = au.isRenderingOffline
        info.canProcessInPlace = au.canProcessInPlace
        info.providesUserInterface = au.providesUserInterface
        info.supportsUserPresets = au.supportsUserPresets
        info.factoryPresets = (au.factoryPresets ?? []).map { $0.name }
        info.userPresets = au.userPresets.map { $0.name }
        info.parameterTree = parameterTreeSummary(au.parameterTree)
        return info
    }

    /// A bounded summary of the AU's parameter tree (full count, capped list).
    public static func parameterTreeSummary(_ tree: AUParameterTree?,
                                            cap: Int = 128) -> HostDiagnostics.AudioUnitInfo.ParameterTreeSummary {
        var summary = HostDiagnostics.AudioUnitInfo.ParameterTreeSummary()
        guard let tree = tree else { return summary }
        summary.available = true
        let all = tree.allParameters
        summary.count = all.count
        summary.truncated = all.count > cap
        summary.parameters = all.prefix(cap).map { p in
            HostDiagnostics.AudioUnitInfo.ParameterTreeSummary.Parameter(
                address: p.address,
                identifier: p.identifier,
                displayName: p.displayName,
                minValue: p.minValue,
                maxValue: p.maxValue,
                value: p.value,
                unit: Int(p.unit.rawValue),
                unitName: p.unitName ?? ""
            )
        }
        return summary
    }

    /// Read the AU's MIDI protocol negotiation and MIDI-CI profile state. Probes
    /// each cable (up to the unit's `virtualMIDICableCount`, min 1) across all 16
    /// channels; only non-empty profile states are kept.
    public static func midiNegotiation(_ au: AUAudioUnit, channels: Int = 16) -> HostDiagnostics.MIDINegotiation {
        var info = HostDiagnostics.MIDINegotiation()
        info.available = true
        info.hostMIDIProtocol = protocolName(au.hostMIDIProtocol)
        info.audioUnitMIDIProtocol = protocolName(au.audioUnitMIDIProtocol)
        let cableCount = max(1, au.virtualMIDICableCount)
        for cable in 0..<min(cableCount, 16) {
            for channel in 0..<max(0, min(channels, 16)) {
                let state = au.profileState(forCable: UInt8(cable), channel: MIDIChannelNumber(channel))
                if state.enabledProfiles.isEmpty && state.disabledProfiles.isEmpty { continue }
                info.profiles.append(HostDiagnostics.MIDINegotiation.Profile(
                    cable: cable,
                    channel: channel + 1,
                    enabled: state.enabledProfiles.map(profileLabel),
                    disabled: state.disabledProfiles.map(profileLabel)
                ))
            }
        }
        return info
    }

    private static func protocolName(_ proto: MIDIProtocolID) -> String {
        switch proto {
        case ._1_0: return "MIDI 1.0"
        case ._2_0: return "MIDI 2.0"
        @unknown default: return "unknown(\(proto.rawValue))"
        }
    }

    private static func profileLabel(_ profile: MIDICIProfile) -> String {
        let hex = profile.profileID.map { String(format: "%02X", $0) }.joined(separator: " ")
        return profile.name.isEmpty ? hex : "\(profile.name) [\(hex)]"
    }

    // MARK: AVAudioSession

    /// Snapshot the process's AVAudioSession (route, channels, latencies, etc.).
    public static func audioSession() -> HostDiagnostics.AudioSession {
        var info = HostDiagnostics.AudioSession()
        let session = AVAudioSession.sharedInstance()
        info.sampleRate = session.sampleRate
        info.preferredSampleRate = session.preferredSampleRate
        info.ioBufferDuration = session.ioBufferDuration
        info.preferredIOBufferDuration = session.preferredIOBufferDuration
        info.category = session.category.rawValue
        info.categoryOptions = categoryOptionNames(session.categoryOptions)
        info.mode = session.mode.rawValue
        info.routeSharingPolicy = routeSharingPolicyName(session.routeSharingPolicy)
        info.isOtherAudioPlaying = session.isOtherAudioPlaying
        info.secondaryAudioShouldBeSilencedHint = session.secondaryAudioShouldBeSilencedHint
        info.outputLatency = session.outputLatency
        info.inputLatency = session.inputLatency
        info.inputAvailable = session.isInputAvailable
        info.inputNumberOfChannels = session.inputNumberOfChannels
        info.outputNumberOfChannels = session.outputNumberOfChannels
        info.preferredInputNumberOfChannels = session.preferredInputNumberOfChannels
        info.preferredOutputNumberOfChannels = session.preferredOutputNumberOfChannels
        info.maximumInputNumberOfChannels = session.maximumInputNumberOfChannels
        info.maximumOutputNumberOfChannels = session.maximumOutputNumberOfChannels
        info.inputGain = Double(session.inputGain)
        info.isInputGainSettable = session.isInputGainSettable
        let route = session.currentRoute
        info.inputPorts = route.inputs.map(portLabel)
        info.outputPorts = route.outputs.map(portLabel)
        info.availableInputs = (session.availableInputs ?? []).map(portLabel)
        return info
    }

    private static func portLabel(_ port: AVAudioSessionPortDescription) -> String {
        "\(port.portName) [\(port.portType.rawValue)]"
    }

    private static func categoryOptionNames(_ options: AVAudioSession.CategoryOptions) -> [String] {
        var names: [String] = []
        if options.contains(.mixWithOthers) { names.append("mixWithOthers") }
        if options.contains(.duckOthers) { names.append("duckOthers") }
        if options.contains(.interruptSpokenAudioAndMixWithOthers) { names.append("interruptSpokenAudioAndMixWithOthers") }
        if options.contains(.allowBluetooth) { names.append("allowBluetooth") }
        if options.contains(.allowBluetoothA2DP) { names.append("allowBluetoothA2DP") }
        if options.contains(.allowAirPlay) { names.append("allowAirPlay") }
        if options.contains(.defaultToSpeaker) { names.append("defaultToSpeaker") }
        if options.contains(.overrideMutedMicrophoneInterruption) { names.append("overrideMutedMicrophoneInterruption") }
        return names
    }

    private static func routeSharingPolicyName(_ policy: AVAudioSession.RouteSharingPolicy) -> String {
        switch policy {
        case .default: return "default"
        case .longFormAudio: return "longFormAudio"
        case .longFormVideo: return "longFormVideo"
        case .independent: return "independent"
        @unknown default: return "unknown(\(policy.rawValue))"
        }
    }

    // MARK: CoreMIDI

    /// Enumerate every CoreMIDI source/destination endpoint and every device /
    /// external device the appex can see, with their properties (manufacturer,
    /// model, protocol, channel masks, offline/private, driver owner).
    public static func coreMIDI() -> HostDiagnostics.CoreMIDISnapshot {
        var snapshot = HostDiagnostics.CoreMIDISnapshot()
        let sourceCount = MIDIGetNumberOfSources()
        snapshot.sources.reserveCapacity(sourceCount)
        for i in 0..<sourceCount {
            snapshot.sources.append(describe(MIDIGetSource(i)))
        }
        let destinationCount = MIDIGetNumberOfDestinations()
        snapshot.destinations.reserveCapacity(destinationCount)
        for i in 0..<destinationCount {
            snapshot.destinations.append(describe(MIDIGetDestination(i)))
        }
        let deviceCount = MIDIGetNumberOfDevices()
        snapshot.devices.reserveCapacity(deviceCount)
        for i in 0..<deviceCount {
            snapshot.devices.append(describeDevice(MIDIGetDevice(i)))
        }
        let externalCount = MIDIGetNumberOfExternalDevices()
        snapshot.externalDevices.reserveCapacity(externalCount)
        for i in 0..<externalCount {
            snapshot.externalDevices.append(describeDevice(MIDIGetExternalDevice(i)))
        }
        return snapshot
    }

    private static func describe(_ endpoint: MIDIEndpointRef) -> HostDiagnostics.CoreMIDISnapshot.Endpoint {
        var entityRef = MIDIEntityRef()
        MIDIEndpointGetEntity(endpoint, &entityRef)
        var deviceRef = MIDIDeviceRef()
        if entityRef != 0 {
            MIDIEntityGetDevice(entityRef, &deviceRef)
        }
        return HostDiagnostics.CoreMIDISnapshot.Endpoint(
            name: stringProperty(endpoint, kMIDIPropertyName),
            displayName: stringProperty(endpoint, kMIDIPropertyDisplayName),
            entity: entityRef != 0 ? stringProperty(entityRef, kMIDIPropertyName) : "",
            device: deviceRef != 0 ? stringProperty(deviceRef, kMIDIPropertyName) : "",
            uniqueID: integerProperty(endpoint, kMIDIPropertyUniqueID),
            manufacturer: stringProperty(endpoint, kMIDIPropertyManufacturer),
            model: stringProperty(endpoint, kMIDIPropertyModel),
            protocolID: Int(integerProperty(endpoint, kMIDIPropertyProtocolID)),
            receiveChannels: integerProperty(endpoint, kMIDIPropertyReceiveChannels),
            transmitChannels: integerProperty(endpoint, kMIDIPropertyTransmitChannels),
            offline: integerProperty(endpoint, kMIDIPropertyOffline) != 0,
            isPrivate: integerProperty(endpoint, kMIDIPropertyPrivate) != 0,
            driverOwner: stringProperty(endpoint, kMIDIPropertyDriverOwner)
        )
    }

    private static func describeDevice(_ device: MIDIDeviceRef) -> HostDiagnostics.CoreMIDISnapshot.Device {
        HostDiagnostics.CoreMIDISnapshot.Device(
            name: stringProperty(device, kMIDIPropertyName),
            manufacturer: stringProperty(device, kMIDIPropertyManufacturer),
            model: stringProperty(device, kMIDIPropertyModel),
            driverOwner: stringProperty(device, kMIDIPropertyDriverOwner),
            uniqueID: integerProperty(device, kMIDIPropertyUniqueID),
            offline: integerProperty(device, kMIDIPropertyOffline) != 0,
            isPrivate: integerProperty(device, kMIDIPropertyPrivate) != 0
        )
    }

    private static func stringProperty(_ object: MIDIObjectRef, _ property: CFString) -> String {
        var value: Unmanaged<CFString>?
        let status = MIDIObjectGetStringProperty(object, property, &value)
        guard status == noErr, let cf = value?.takeRetainedValue() else { return "" }
        return cf as String
    }

    private static func integerProperty(_ object: MIDIObjectRef, _ property: CFString) -> Int32 {
        var value: Int32 = 0
        MIDIObjectGetIntegerProperty(object, property, &value)
        return value
    }

    // MARK: Environment

    /// Snapshot the runtime environment (thermal/power pressure, memory, cores,
    /// OS/device identity).
    public static func environment() -> HostDiagnostics.Environment {
        var env = HostDiagnostics.Environment()
        let info = ProcessInfo.processInfo
        env.thermalState = thermalStateName(info.thermalState)
        env.lowPowerModeEnabled = info.isLowPowerModeEnabled
        env.physicalMemory = info.physicalMemory
        env.activeProcessorCount = info.activeProcessorCount
        env.processorCount = info.processorCount
        env.systemUptime = info.systemUptime
        env.osVersion = info.operatingSystemVersionString
        #if canImport(UIKit)
        let device = UIDevice.current
        env.deviceModel = device.model
        env.deviceSystemName = device.systemName
        env.deviceSystemVersion = device.systemVersion
        #endif
        return env
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }
}

/// Source-compatible alias for the previous name of the collector.
public typealias HostIntrospectionCollector = HostDiagnosticsCollector
