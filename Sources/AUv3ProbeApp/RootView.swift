import SwiftUI
import ProbeKit

// RootView is the app shell: a shared daemon-host bar on top (the single Receiver
// that both flows use) and a TabView switching between the audio-units console
// (AUv3 parameter/preset reader) and the AUM-sessions ferry (project upload/
// inspect/download). The host is entered once here and injected into both tabs
// via the environment, so there is one place to point the app at your LAN daemon.

struct RootView: View {
    @StateObject private var receiver = Receiver()

    var body: some View {
        VStack(spacing: 0) {
            receiverBar
            Divider().overlay(Signalwave.grid)

            TabView {
                AudioUnitsView()
                    .tabItem { Label("audio units", systemImage: "dot.radiowaves.up.forward") }
                AUMSessionsView()
                    .tabItem { Label("aum sessions", systemImage: "folder") }
            }
        }
        .background(Signalwave.bg.ignoresSafeArea())
        .tint(Signalwave.green)
        .preferredColorScheme(.dark)
        .environmentObject(receiver)
    }

    // MARK: - Shared daemon status bar

    private var receiverBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                WaveGlyph()
                    .frame(width: 32, height: 20)
                Text("auv3probe")
                    .font(Signalwave.mono(.headline, weight: .bold))
                    .foregroundStyle(Signalwave.fg)
                Spacer()
            }

            // The one status element shared verbatim with both AUv3 extensions:
            // discovered IP, connection status, daemon capabilities + version.
            DaemonStatusView()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(Signalwave.bg)
    }
}
