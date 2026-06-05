import Foundation
import Combine
import SwiftUI

// Receiver is the app's connection state, now driven entirely by Bonjour
// discovery (DaemonDiscovery) — there is no typed host anymore. Both app flows
// (plugins + sessions) get their DaemonClient from the auto-discovered daemon,
// and the shared DaemonStatusView shows the live IP / reachability / version /
// capabilities. It is injected as an EnvironmentObject from RootView.
//
// Lives in ProbeKit so the same DaemonClient factory is reused everywhere.
@MainActor
public final class Receiver: ObservableObject {
    private let discovery = DaemonDiscovery.shared
    private var cancellable: AnyCancellable?

    public init() {
        discovery.start()
        // Re-publish when discovery changes so views gated on `isConfigured` /
        // `client` refresh. The live status display is handled by the shared
        // DaemonStatusView, which observes DaemonDiscovery directly.
        cancellable = discovery.$status.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// True once a daemon has been discovered on the LAN.
    public var isConfigured: Bool { discovery.currentHost != nil }

    /// A client for the discovered daemon, or nil while still searching.
    public var client: DaemonClient? {
        discovery.currentHost.flatMap { DaemonClient(host: $0) }
    }
}
