import Foundation
import SwiftUI

// Receiver is the shared connection state for both flows (plugins + sessions):
// the daemon host the user typed and the result of the last connectivity test.
// It is injected as an EnvironmentObject from RootView so the single host field
// in the top bar drives both tabs, and each flow gets its DaemonClient from here
// rather than parsing the host itself.
//
// The host is a local LAN address typed by the user and persisted to
// UserDefaults so it survives launches. It is never committed to git (public
// repo rule); persisting it on-device is fine.

@MainActor
final class Receiver: ObservableObject {
    private static let hostKey = "receiverHost"

    @Published var host: String {
        didSet { UserDefaults.standard.set(host, forKey: Self.hostKey) }
    }

    @Published var connectionOK = false
    @Published var connectionMessage: String?
    @Published var isTesting = false

    init() {
        host = UserDefaults.standard.string(forKey: Self.hostKey) ?? ""
    }

    /// True when a non-empty host has been entered.
    var isConfigured: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A client for the current host, or nil when the host is empty/unparseable.
    var client: DaemonClient? { DaemonClient(host: host) }

    /// Test connectivity via `GET /healthz`, publishing the outcome.
    func testConnection() async {
        guard let client = client else {
            connectionOK = false
            connectionMessage = "Enter a host (e.g. host:7800)"
            return
        }
        isTesting = true
        defer { isTesting = false }
        do {
            try await client.healthz()
            connectionOK = true
            connectionMessage = "Connected to \(client.baseURL.host ?? "mcp-midi-controller")"
        } catch {
            connectionOK = false
            connectionMessage = error.localizedDescription
        }
    }
}
