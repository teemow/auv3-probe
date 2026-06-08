import Foundation
import AVFoundation
import AudioToolbox
import UIKit

// Captures a plugin's icon on-device and archives it the way AUM stores it.
//
// Source (validated on-device against a real AUM session, see the auv3-probe app
// plan): AudioComponentCopyIcon(comp) — the current, non-deprecated iOS 14+ API
// (AVAudioUnitComponent.icon / .iconURL are macOS-only). For an app-extension AU
// it returns the containing app's icon, which is exactly what AUM persists as
// AUMNodeArchive.componentIcon. Third-party plugins return a 120x120 @1x image
// that matches AUM's stored bytes verbatim.
enum ComponentIcon {
    /// The on-device UIImage for a component, or nil if none is available.
    static func image(for desc: AudioComponentDescription) -> UIImage? {
        var d = desc
        guard let comp = AudioComponentFindNext(nil, &d) else { return nil }
        return AudioComponentCopyIcon(comp)
    }

    /// Archive a UIImage the way AUM stores it: `NSKeyedArchiver` of the UIImage
    /// root object, so the daemon can decode it as a standalone archive and graft
    /// the UIImage subgraph into an authored node's `componentIcon`.
    static func archived(_ image: UIImage) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: image, requiringSecureCoding: false)
    }
}
