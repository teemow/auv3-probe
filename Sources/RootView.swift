import SwiftUI

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

    // MARK: - Shared daemon host bar

    private var receiverBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                WaveGlyph()
                    .frame(width: 32, height: 20)
                Text("auv3probe")
                    .font(Signalwave.mono(.headline, weight: .bold))
                    .foregroundStyle(Signalwave.fg)
                Spacer()
                if receiver.isTesting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Signalwave.green)
                }
            }

            HStack(spacing: 8) {
                Text(">")
                    .font(Signalwave.mono(.body, weight: .bold))
                    .foregroundStyle(Signalwave.green)
                TextField("host:7800", text: $receiver.host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(Signalwave.mono(.body))
                    .foregroundStyle(Signalwave.fg)
                    .tint(Signalwave.green)
                Button {
                    Task { await receiver.testConnection() }
                } label: {
                    Label("test", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(.signalGhost)
                .disabled(receiver.isTesting || !receiver.isConfigured)
            }
            .signalField()

            if let message = receiver.connectionMessage {
                Label {
                    Text(message)
                } icon: {
                    Image(systemName: receiver.connectionOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                }
                .font(Signalwave.mono(.caption2))
                .foregroundStyle(receiver.connectionOK ? Signalwave.green : Signalwave.amber)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(Signalwave.bg)
    }
}
