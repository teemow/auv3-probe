// swift-tools-version: 6.0
import PackageDescription

// SwiftPM manifest used by the Linux build path (xtool) — see
// docs/building-on-linux.md. It lives in the repo and points straight at the
// real `Sources/`, so the xtool build and the canonical XcodeGen build share one
// copy of the sources (no duplication). The macOS/XcodeGen build is still driven
// by project.yml and ignores this file.
let package = Package(
    name: "AUv3Probe",
    platforms: [.iOS(.v16), .macOS(.v14)],
    products: [.library(name: "AUv3Probe", targets: ["AUv3Probe"])],
    targets: [.target(name: "AUv3Probe", path: "Sources")],
    // The sources target the XcodeGen build (iOS 16 / Swift 5). Swift 6 strict
    // concurrency flags the AVAudioUnit.instantiate continuation bridge as a data
    // race; keep the original Swift 5 semantics for the xtool build too.
    swiftLanguageModes: [.v5]
)
