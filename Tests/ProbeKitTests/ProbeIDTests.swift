import XCTest
import ProbeKit

// The daemon stages each audio unit's dump as `<id>.json` with the Go
// `device.ProbeID` (github.com/teemow/midi-device); `AudioUnitDetails.fileID`
// mirrors it. These are the same vectors as midi-device's TestProbeIDVectors,
// so a change to either side shows up as a failure here or there.
final class ProbeIDTests: XCTestCase {
    private let vectors: [(type: String, subtype: String, manufacturer: String, name: String, want: String)] = [
        ("aufx", "dely", "acme", "Delay", "aufx-dely-acme"),
        ("aumu", "Ab12", "XyZw", "Synth", "aumu-_ab12-_xy_zw"),
        ("aumi", "Ab12", "XyZw", "Synth MIDI", "aumi-_ab12-_xy_zw"),
        ("aumu", "AB12", "XyZw", "Synth (old)", "aumu-_a_b12-_xy_zw"),
        ("aumi", "a b_", "Mn-1", "Odd", "aumi-a__20b__5f-_mn__2d1"),
        ("aumf", "", "acme", "No Subtype", "aumf--acme"),
        // No component type: the earlier subtype/name id.
        ("", "Dist", "", "Distortion", "dist"),
        ("", "", "", "My Plugin", "my_plugin"),
        ("", "", "", "", ""),
    ]

    private func details(_ type: String, _ subtype: String, _ manufacturer: String,
                         name: String) -> AudioUnitDetails {
        AudioUnitDetails(
            component: AudioUnitComponent(type: type, subtype: subtype, manufacturer: manufacturer),
            name: name, parameters: [])
    }

    func testVectorsMatchGoProbeID() {
        for v in vectors {
            XCTAssertEqual(details(v.type, v.subtype, v.manufacturer, name: v.name).fileID, v.want,
                           "fileID of \(v.type)/\(v.subtype)/\(v.manufacturer) \"\(v.name)\"")
        }
    }

    /// Units that share a subtype must not share a staged file, even on a
    /// case-insensitive filesystem.
    func testUnitsSharingASubtypeGetDistinctIDs() {
        let pairs: [(AudioUnitDetails, AudioUnitDetails)] = [
            // An instrument and a MIDI processor from one vendor.
            (details("aumu", "Ab12", "XyZw", name: "Same"), details("aumi", "Ab12", "XyZw", name: "Same")),
            // Two manufacturers.
            (details("aufx", "dely", "acme", name: "Same"), details("aufx", "dely", "Acme", name: "Same")),
            // The same subtype registered twice in different letter case.
            (details("aumu", "Ab12", "XyZw", name: "Same"), details("aumu", "AB12", "XyZw", name: "Same")),
        ]
        for (a, b) in pairs {
            XCTAssertNotEqual(a.fileID.lowercased(), b.fileID.lowercased(),
                              "\(a.component) and \(b.component) collide")
        }
    }

    /// Every component over a small alphabet gets its own id, compared without
    /// case, and every id only uses the device-type id characters.
    func testComponentIDIsInjective() {
        let alphabet = ["a", "A", "f", "F", "2", "_", "-", " "]
        var codes = [""]
        for x in alphabet {
            codes.append(x)
            for y in alphabet { codes.append(x + y) }
        }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_-")
        var seen: [String: String] = [:]
        for sub in codes {
            for mfr in codes {
                let id = AudioUnitDetails.componentID(
                    AudioUnitComponent(type: "aumu", subtype: sub, manufacturer: mfr))
                XCTAssertTrue(id.allSatisfy { allowed.contains($0) }, "id \(id) has a character outside [a-z0-9_-]")
                let key = id.lowercased()
                if let prev = seen[key] {
                    XCTFail("\(sub)/\(mfr) and \(prev) share id \(id)")
                    return
                }
                seen[key] = "\(sub)/\(mfr)"
            }
        }
    }
}
