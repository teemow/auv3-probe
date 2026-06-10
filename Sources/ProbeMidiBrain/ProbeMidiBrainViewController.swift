import Foundation
import CoreAudioKit
import SwiftUI
import UIKit
import ProbeKit

// The extension's principal class (NSExtensionPrincipalClass in Info.plist): an
// AUViewController that is also the AUAudioUnitFactory. The host instantiates
// it, asks it to create the audio unit, and presents its view. We host the
// signalwave SwiftUI authoring surface inside it.
//
// @objc(...) pins the class name so Info.plist can resolve it under SwiftPM
// module mangling.
@objc(ProbeMidiBrainViewController)
public final class ProbeMidiBrainViewController: AUViewController, AUAudioUnitFactory {
    private var brain: ProbeMidiBrainAU?
    private var hostingController: UIHostingController<ProbeMidiBrainView>?

    public override func viewDidLoad() {
        super.viewDidLoad()
        // Tall enough for the session control surface on top of the authoring
        // panels (was 480×620 before the surface existed).
        preferredContentSize = CGSize(width: 520, height: 760)
        view.backgroundColor = UIColor(Signalwave.bg)
        installUIIfReady()
    }

    public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        let unit = try ProbeMidiBrainAU(componentDescription: componentDescription)
        brain = unit
        // The view may already be loaded (host presented UI first); install now.
        DispatchQueue.main.async { [weak self] in self?.installUIIfReady() }
        return unit
    }

    private func installUIIfReady() {
        guard isViewLoaded, let brain = brain, hostingController == nil else { return }

        let model = BrainViewModel(audioUnit: brain)
        let host = UIHostingController(rootView: ProbeMidiBrainView(model: model))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        hostingController = host
    }
}
