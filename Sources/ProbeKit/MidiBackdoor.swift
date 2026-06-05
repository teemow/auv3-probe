#if DEBUG
import Foundation
import CoreMIDI
import os

// MidiBackdoor is a DEV-ONLY experiment for the AUM control-surface analysis: it
// answers "can the appex drive AUM *outside* the AU graph?" by creating its own
// CoreMIDI client and sending a CC straight to a chosen destination endpoint
// (e.g. an "AUM" virtual port) — bypassing the sanctioned midiOutputEventBlock.
//
// It is gated behind `#if DEBUG` so it never ships in a release build, and is
// inert until explicitly used from the AU's debug panel. The result of a send
// is reported back as an OSStatus string so the test is observable on-device and
// in os_log (idevicesyslog, subsystem com.teemow.auv3probe).
//
// This is NOT realtime code: it is invoked from the UI thread on a button tap.
public final class MidiBackdoor: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.teemow.auv3probe", category: "backdoor")

    private var client = MIDIClientRef()
    private var outputPort = MIDIPortRef()

    public init() {}

    deinit {
        if outputPort != 0 { MIDIPortDispose(outputPort) }
        if client != 0 { MIDIClientDispose(client) }
    }

    /// A destination endpoint the appex can see, with the same metadata the
    /// introspection collector reports, so the UI can let the user pick one.
    public struct Destination: Identifiable, Equatable, Sendable {
        public let id: Int
        public let endpoint: MIDIEndpointRef
        public let name: String
        public let displayName: String
        public let device: String

        public var label: String {
            let primary = displayName.isEmpty ? name : displayName
            return device.isEmpty ? primary : "\(device) · \(primary)"
        }
    }

    /// Enumerate every CoreMIDI destination currently visible to the appex.
    public func destinations() -> [Destination] {
        let count = MIDIGetNumberOfDestinations()
        return (0..<count).map { index in
            let endpoint = MIDIGetDestination(index)
            return Destination(
                id: index,
                endpoint: endpoint,
                name: Self.stringProperty(endpoint, kMIDIPropertyName),
                displayName: Self.stringProperty(endpoint, kMIDIPropertyDisplayName),
                device: Self.deviceName(endpoint)
            )
        }
    }

    /// Send a single Control Change directly to `destination`, bypassing the AU
    /// graph. Returns a human-readable result (and logs it). `channel` is 1-16.
    @discardableResult
    public func sendCC(to destination: Destination, channel: Int = 1, cc: Int, value: Int) -> String {
        guard ensureClient() else {
            let message = "backdoor: MIDIClient/port creation failed"
            Self.log.error("\(message, privacy: .public)")
            return message
        }
        let status = UInt8(0xB0 | (UInt8(max(1, min(16, channel)) - 1) & 0x0F))
        let bytes: [UInt8] = [status, UInt8(max(0, min(127, cc))), UInt8(max(0, min(127, value)))]

        var packetList = MIDIPacketList()
        let packet = MIDIPacketListInit(&packetList)
        _ = bytes.withUnsafeBufferPointer { buffer in
            MIDIPacketListAdd(&packetList, 1024, packet, 0, buffer.count, buffer.baseAddress!)
        }
        let result = MIDISend(outputPort, destination.endpoint, &packetList)
        let summary: String
        if result == noErr {
            summary = "sent CC \(cc)=\(value) ch\(channel) -> \(destination.label)"
            Self.log.notice("backdoor: \(summary, privacy: .public)")
        } else {
            summary = "backdoor send failed (OSStatus \(result)) -> \(destination.label)"
            Self.log.error("\(summary, privacy: .public)")
        }
        return summary
    }

    // MARK: - CoreMIDI client lifecycle

    private func ensureClient() -> Bool {
        if client == 0 {
            let status = MIDIClientCreate("com.teemow.auv3probe.backdoor" as CFString, nil, nil, &client)
            guard status == noErr else { return false }
        }
        if outputPort == 0 {
            let status = MIDIOutputPortCreate(client, "backdoor.out" as CFString, &outputPort)
            guard status == noErr else { return false }
        }
        return true
    }

    private static func stringProperty(_ object: MIDIObjectRef, _ property: CFString) -> String {
        var value: Unmanaged<CFString>?
        let status = MIDIObjectGetStringProperty(object, property, &value)
        guard status == noErr, let cf = value?.takeRetainedValue() else { return "" }
        return cf as String
    }

    private static func deviceName(_ endpoint: MIDIEndpointRef) -> String {
        var entity = MIDIEntityRef()
        MIDIEndpointGetEntity(endpoint, &entity)
        guard entity != 0 else { return "" }
        var device = MIDIDeviceRef()
        MIDIEntityGetDevice(entity, &device)
        guard device != 0 else { return "" }
        return stringProperty(device, kMIDIPropertyName)
    }
}
#endif
