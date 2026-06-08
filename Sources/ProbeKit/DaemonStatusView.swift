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

    public init() {}

    public var body: some View {
        let status = discovery.status
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                WaveGlyph(color: dotColor(status)).frame(width: 26, height: 16)
                Text("mcp-midi-controller")
                    .font(Signalwave.mono(.footnote, weight: .semibold))
                    .foregroundStyle(Signalwave.fg)
                Spacer()
                Text(status.version.map { "v\($0)" } ?? "")
                    .font(Signalwave.mono(.caption2))
                    .foregroundStyle(Signalwave.dim)
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .signalField()
        .onAppear { discovery.start() }
    }

    private func dotColor(_ status: DaemonDiscovery.Status) -> Color {
        if status.reachable { return Signalwave.green }
        if status.discovered { return Signalwave.amber }
        return Signalwave.dim
    }

    private func statusLine(_ status: DaemonDiscovery.Status) -> String {
        guard let host = status.host else { return "searching the lan…" }
        return status.reachable ? "connected · \(host)" : "discovered · \(host) (unreachable)"
    }
}
