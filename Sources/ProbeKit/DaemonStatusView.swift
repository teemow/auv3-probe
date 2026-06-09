import SwiftUI

// DaemonStatusView is the ONE UI element shared verbatim by all three surfaces —
// the container app and both AUv3 extensions. It shows what every process needs
// to know about the auto-discovered mcp-midi-controller:
//
//   - the discovered IP (host:port), or "searching…" while browsing
//   - connection status (reachable via healthz / discovered / offline)
//   - the daemon's advertised capabilities (Bonjour TXT)
//   - the daemon's version (Bonjour TXT)
//
// It is driven entirely by the shared DaemonDiscovery singleton, and starts
// browsing on appear, so dropping it into a view is all a surface needs to do.
// Rendered in the signalwave language so it looks identical everywhere.
public struct DaemonStatusView: View {
    @ObservedObject private var discovery = DaemonDiscovery.shared

    @State private var showManual = false
    @State private var manualText = ""

    public init() {}

    public var body: some View {
        let status = discovery.status
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                WaveGlyph(color: dotColor(status)).frame(width: 26, height: 16)
                Text("mcp-midi-controller")
                    .font(Signalwave.mono(.footnote, weight: .semibold))
                    .foregroundStyle(Signalwave.fg)
                if status.manual {
                    SignalChip(text: "manual", color: Signalwave.amber)
                }
                Spacer()
                Text(status.version.map { "v\($0)" } ?? "")
                    .font(Signalwave.mono(.caption2))
                    .foregroundStyle(Signalwave.dim)
                Button {
                    manualText = discovery.manualHost ?? ""
                    withAnimation(.easeOut(duration: 0.12)) { showManual.toggle() }
                } label: {
                    Image(systemName: showManual ? "chevron.up" : "slider.horizontal.3")
                        .font(.caption)
                        .foregroundStyle(Signalwave.dim)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("set host manually")
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor(status))
                    .frame(width: 8, height: 8)
                Text(statusLine(status))
                    .font(Signalwave.mono(.caption))
                    .foregroundStyle(status.discovered ? Signalwave.fg : Signalwave.dim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if !status.capabilities.isEmpty {
                FlowChips(chips: status.capabilities)
            }

            if showManual {
                manualEntry(status)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .signalField()
        .onAppear { discovery.start() }
    }

    // MARK: - Manual host entry (mDNS-blocked fallback)

    @ViewBuilder
    private func manualEntry(_ status: DaemonDiscovery.Status) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle().fill(Signalwave.grid).frame(height: 1).padding(.vertical, 2)

            HStack(spacing: 8) {
                Image(systemName: "network")
                    .font(.caption)
                    .foregroundStyle(Signalwave.dim)
                TextField("host or host:port", text: $manualText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit(applyManual)
                    .font(Signalwave.mono(.subheadline))
                    .foregroundStyle(Signalwave.fg)
                    .tint(Signalwave.green)
            }
            .signalField()

            HStack(spacing: 8) {
                Button("use", action: applyManual)
                    .buttonStyle(.signalGhost)
                    .disabled(manualText.trimmingCharacters(in: .whitespaces).isEmpty)
                if status.manual {
                    Button("auto") {
                        manualText = ""
                        discovery.setManualHost(nil)
                        withAnimation(.easeOut(duration: 0.12)) { showManual = false }
                    }
                    .buttonStyle(.signalGhost(Signalwave.amber))
                }
                Spacer()
            }

            Text("// fallback for lans where mdns is blocked. leave on auto to use bonjour discovery.")
                .font(Signalwave.mono(.caption2))
                .foregroundStyle(Signalwave.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func applyManual() {
        let trimmed = manualText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        discovery.setManualHost(trimmed)
        withAnimation(.easeOut(duration: 0.12)) { showManual = false }
    }

    private func dotColor(_ status: DaemonDiscovery.Status) -> Color {
        if status.reachable { return Signalwave.green }
        if status.discovered { return Signalwave.amber }
        return Signalwave.dim
    }

    private func statusLine(_ status: DaemonDiscovery.Status) -> String {
        guard let host = status.host else { return "searching the lan…" }
        let prefix = status.manual ? "manual" : (status.reachable ? "connected" : "discovered")
        if status.reachable { return "\(prefix) · \(host)" }
        return "\(prefix) · \(host) (unreachable)"
    }
}
