// swift-tools-version: 6.0
import PackageDescription

// SwiftPM manifest used by the Linux build path (xtool) — see
// docs/building-on-linux.md and docs/auv3-extension.md. It lives in the repo and
// points straight at the real `Sources/`, so the xtool build and the canonical
// XcodeGen build share one copy of the sources (no duplication). The
// macOS/XcodeGen build is still driven by project.yml and ignores this file.
//
// Four targets, one directory each (SwiftPM requires a dir per target):
//   - ProbeKit      shared library (design system, LAN client, data contracts,
//                   realtime-safe AUv3 helpers) used by the app and both AUv3
//                   extensions.
//   - AUv3ProbeApp  the container app (@main). xtool's `product:`.
//   - ProbeMidiBrain  the `aumi` MIDI-processor app extension.
//   - ProbeAudioTap   the `aufx` audio-effect app extension.
//
// The two extension products are referenced from xtool.yml's `extensions:` list;
// xtool packs each into the app bundle's PlugIns/<name>.appex.
let package = Package(
    name: "AUv3Probe",
    platforms: [.iOS(.v16), .macOS(.v14)],
    products: [
        .library(name: "AUv3ProbeApp", targets: ["AUv3ProbeApp"]),
        .library(name: "ProbeMidiBrain", targets: ["ProbeMidiBrain"]),
        .library(name: "ProbeAudioTap", targets: ["ProbeAudioTap"]),
    ],
    dependencies: [
        // Lock-free SPSC ring buffer for the ProbeAudioTap render block needs
        // correct atomics on the iOS 16 floor (the stdlib `Synchronization`
        // module is iOS 18+). swift-atomics is Apple-maintained and works on
        // both build paths (SwiftPM/xtool here, XcodeGen via project.yml packages).
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "ProbeKit",
            dependencies: [.product(name: "Atomics", package: "swift-atomics")],
            path: "Sources/ProbeKit"
        ),
        .target(name: "AUv3ProbeApp", dependencies: ["ProbeKit"], path: "Sources/AUv3ProbeApp"),
        .target(name: "ProbeMidiBrain", dependencies: ["ProbeKit"], path: "Sources/ProbeMidiBrain"),
        .target(name: "ProbeAudioTap", dependencies: ["ProbeKit"], path: "Sources/ProbeAudioTap"),
    ],
    // The sources target the XcodeGen build (iOS 16 / Swift 5). Swift 6 strict
    // concurrency flags the AVAudioUnit.instantiate continuation bridge as a data
    // race; keep the original Swift 5 semantics for the xtool build too.
    swiftLanguageModes: [.v5]
)
