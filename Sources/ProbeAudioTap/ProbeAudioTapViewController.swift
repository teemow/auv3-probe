import Foundation
import CoreAudioKit
import SwiftUI
import UIKit
import ProbeKit

// The extension's principal class: an AUViewController + AUAudioUnitFactory that
// hosts the signalwave SwiftUI control surface for ProbeAudioTap.
@objc(ProbeAudioTapViewController)
public final class ProbeAudioTapViewController: AUViewController, AUAudioUnitFactory {
    private var tap: ProbeAudioTapAU?
    private var hostingController: UIHostingController<ProbeAudioTapView>?

    public override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = CGSize(width: 360, height: 300)
        view.backgroundColor = UIColor(Signalwave.bg)
        installUIIfReady()
    }

    public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        let unit = try ProbeAudioTapAU(componentDescription: componentDescription)
        tap = unit
        DispatchQueue.main.async { [weak self] in self?.installUIIfReady() }
        return unit
    }

    private func installUIIfReady() {
        guard isViewLoaded, let tap = tap, hostingController == nil else { return }

        let model = TapViewModel(audioUnit: tap)
        let host = UIHostingController(rootView: ProbeAudioTapView(model: model))
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
