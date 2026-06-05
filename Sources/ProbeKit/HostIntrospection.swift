import Foundation
import AVFoundation
import CoreMIDI
import os

// HostIntrospection is the measured snapshot of everything an AUv3 appex can see
// about its surroundings while hosted (inside AUM). It is the data side of the
// "what can the brain read?" analysis (see the AUM control-surface plan):
//
//   - SANCTIONED (AUv3 API): the transport flags/position and full musical
//     context the host blocks hand the render thread, plus render config
//     (maximumFramesToRender, midiOutputNames, bus formats). These are filled in
//     by the AU/engine because only the render thread may call the host blocks.
//   - BACKDOORS (system frameworks reachable from the appex sandbox):
//       * AVAudioSession — sample rate, IO buffer, route ports, other-audio.
//       * CoreMIDI — every visible source/destination endpoint and its parent
//         entity/device. Reveals whether the appex can see AUM's virtual ports
//         or other apps' endpoints at all.
//
// The struct is Codable so it round-trips to JSON for the os_log dump (read on
// Linux via idevicesyslog) and renders verbatim in the AU's introspection panel.
// The AVAudioSession/CoreMIDI collectors are pure reads, safe to call off the
// render thread (from the UI/report timer); the sanctioned fields are merged in
// by the engine which captures them on the render thread.
public struct HostIntrospection: Codable, Sendable, Equatable {
    /// os_log channel for the whole probe (subsystem shared with idevicesyslog).
    public static let log = Logger(subsystem: "com.teemow.auv3probe", category: "introspection")

    public var capturedAt: Date
    public var transport: Transport
    public var musicalContext: MusicalContext
    public var render: Render
    public var audioSession: AudioSession
    public var coreMIDI: CoreMIDISnapshot

    public init(capturedAt: Date = Date(),
                transport: Transport = Transport(),
                musicalContext: MusicalContext = MusicalContext(),
                render: Render = Render(),
                audioSession: AudioSession = AudioSession(),
                coreMIDI: CoreMIDISnapshot = CoreMIDISnapshot()) {
        self.capturedAt = capturedAt
        self.transport = transport
        self.musicalContext = musicalContext
        self.render = render
        self.audioSession = audioSession
        self.coreMIDI = coreMIDI
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

    /// AU render configuration the host negotiated.
    public struct Render: Codable, Sendable, Equatable {
        public var maximumFramesToRender: Int = 0
        public var midiOutputNames: [String] = []
        public var outputBusFormats: [String] = []
        public init() {}
    }

    // MARK: - Backdoors (system frameworks)

    /// AVAudioSession state visible from the appex.
    public struct AudioSession: Codable, Sendable, Equatable {
        public var sampleRate: Double = 0
        public var ioBufferDuration: Double = 0
        public var category: String = ""
        public var mode: String = ""
        public var isOtherAudioPlaying = false
        public var outputLatency: Double = 0
        public var inputLatency: Double = 0
        public var inputPorts: [String] = []
        public var outputPorts: [String] = []
        public init() {}
    }

    /// The CoreMIDI graph as the appex can enumerate it.
    public struct CoreMIDISnapshot: Codable, Sendable, Equatable {
        public var sources: [Endpoint] = []
        public var destinations: [Endpoint] = []
        public init() {}

        public struct Endpoint: Codable, Sendable, Equatable {
            public var name: String
            public var displayName: String
            public var entity: String
            public var device: String
            public var uniqueID: Int32
            public init(name: String, displayName: String, entity: String, device: String, uniqueID: Int32) {
                self.name = name
                self.displayName = displayName
                self.entity = entity
                self.device = device
                self.uniqueID = uniqueID
            }
        }
    }

    /// Pretty JSON for the on-device display (the AU panel renders fields
    /// directly; this is the "copy the whole snapshot" form).
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
    /// stream reliably to `idevicesyslog` on Linux without truncation.
    public func log(prefix: String = "host-introspection") {
        let log = Self.log
        log.notice("\(prefix, privacy: .public) at=\(Self.compact(self.capturedAt), privacy: .public)")
        log.notice("\(prefix, privacy: .public) transport=\(Self.compact(self.transport), privacy: .public)")
        log.notice("\(prefix, privacy: .public) musical=\(Self.compact(self.musicalContext), privacy: .public)")
        log.notice("\(prefix, privacy: .public) render=\(Self.compact(self.render), privacy: .public)")
        log.notice("\(prefix, privacy: .public) audioSession=\(Self.compact(self.audioSession), privacy: .public)")
        log.notice("\(prefix, privacy: .public) coreMIDI counts src=\(self.coreMIDI.sources.count) dst=\(self.coreMIDI.destinations.count)")
        for (index, endpoint) in coreMIDI.sources.enumerated() {
            log.notice("\(prefix, privacy: .public) src[\(index)]=\(Self.compact(endpoint), privacy: .public)")
        }
        for (index, endpoint) in coreMIDI.destinations.enumerated() {
            log.notice("\(prefix, privacy: .public) dst[\(index)]=\(Self.compact(endpoint), privacy: .public)")
        }
    }
}

// MARK: - Collectors

/// Reads the backdoor surfaces (AVAudioSession, CoreMIDI). These are plain reads
/// with no realtime constraints — call them from the report timer / UI, never
/// the render thread.
public enum HostIntrospectionCollector {
    /// Snapshot the process's AVAudioSession (route ports, rate, other-audio).
    public static func audioSession() -> HostIntrospection.AudioSession {
        var info = HostIntrospection.AudioSession()
        let session = AVAudioSession.sharedInstance()
        info.sampleRate = session.sampleRate
        info.ioBufferDuration = session.ioBufferDuration
        info.category = session.category.rawValue
        info.mode = session.mode.rawValue
        info.isOtherAudioPlaying = session.isOtherAudioPlaying
        info.outputLatency = session.outputLatency
        info.inputLatency = session.inputLatency
        let route = session.currentRoute
        info.inputPorts = route.inputs.map { "\($0.portName) [\($0.portType.rawValue)]" }
        info.outputPorts = route.outputs.map { "\($0.portName) [\($0.portType.rawValue)]" }
        return info
    }

    /// Enumerate every CoreMIDI source and destination the appex can see, with
    /// each endpoint's parent entity/device (to reveal AUM virtual ports etc.).
    public static func coreMIDI() -> HostIntrospection.CoreMIDISnapshot {
        var snapshot = HostIntrospection.CoreMIDISnapshot()
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
        return snapshot
    }

    private static func describe(_ endpoint: MIDIEndpointRef) -> HostIntrospection.CoreMIDISnapshot.Endpoint {
        var entityRef = MIDIEntityRef()
        MIDIEndpointGetEntity(endpoint, &entityRef)
        var deviceRef = MIDIDeviceRef()
        if entityRef != 0 {
            MIDIEntityGetDevice(entityRef, &deviceRef)
        }
        return HostIntrospection.CoreMIDISnapshot.Endpoint(
            name: stringProperty(endpoint, kMIDIPropertyName),
            displayName: stringProperty(endpoint, kMIDIPropertyDisplayName),
            entity: entityRef != 0 ? stringProperty(entityRef, kMIDIPropertyName) : "",
            device: deviceRef != 0 ? stringProperty(deviceRef, kMIDIPropertyName) : "",
            uniqueID: integerProperty(endpoint, kMIDIPropertyUniqueID)
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
}
