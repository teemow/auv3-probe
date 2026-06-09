import SwiftUI
import ProbeKit

// The audio-units tab, rendered in the signalwave design language (see
// docs/signalwave.md): a charcoal "sniffer console" that lists every installed
// AUv3 like a packet capture and shows the live sync state of each.
//
// There is no select/read step. The moment the shared Receiver reports the
// daemon reachable, every unit is read and POSTed automatically; the tab is a
// status console plus a per-unit inspector. "resync" re-scans (picking up newly
// installed plugins) and pushes again.

struct AudioUnitsView: View {
    @EnvironmentObject private var receiver: Receiver
    @StateObject private var model = AudioUnitsModel()
    @State private var query = ""

    private var filteredUnits: [DiscoveredAudioUnit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.units }
        return model.units.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.manufacturer.localizedCaseInsensitiveContains(q)
        }
    }

    /// Units that have completed a sync (sent or empty).
    private var syncedCount: Int {
        model.units.reduce(0) { count, unit in
            (model.statuses[unit.id]?.isDone ?? false) ? count + 1 : count
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Signalwave.grid)

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    unitsSection
                }
                .padding(16)
                .padding(.bottom, 8)
            }

            statusBar
        }
        .background(Signalwave.bg.ignoresSafeArea())
        .onAppear {
            if model.units.isEmpty { model.refresh() }
            triggerAutoSync()
        }
        .onChange(of: receiver.isReachable) { _ in triggerAutoSync() }
        .onChange(of: receiver.host) { _ in triggerAutoSync() }
        .sheet(item: inspectedBinding) { item in
            AudioUnitInspectorView(details: item.details)
        }
    }

    /// Fire an auto-sync when the daemon is reachable. The model itself guards
    /// against re-syncing the same host or overlapping runs.
    private func triggerAutoSync() {
        guard receiver.isReachable,
              let client = receiver.client,
              let host = receiver.host else { return }
        Task { await model.autoSync(client: client, host: host) }
    }

    /// Bridges `model.inspectedID` to a `.sheet(item:)` binding by pairing it
    /// with its stashed details; clearing the binding dismisses the sheet.
    private var inspectedBinding: Binding<InspectedAudioUnit?> {
        Binding(
            get: {
                guard let id = model.inspectedID, let details = model.details(id) else { return nil }
                return InspectedAudioUnit(id: id, details: details)
            },
            set: { newValue in model.inspectedID = newValue?.id }
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("audio units")
                    .font(Signalwave.mono(.title3, weight: .bold))
                    .foregroundStyle(Signalwave.fg)
                Text("auv3 · auto-synced to mcp-midi-controller")
                    .font(Signalwave.mono(.caption2))
                    .foregroundStyle(Signalwave.dim)
            }

            Spacer()

            Button {
                Task { await model.resync(client: receiver.client, host: receiver.host) }
            } label: {
                Label("resync", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.signalGhost)
            .disabled(model.isBusy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Units

    private var unitsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SectionHeader("audio units")
                Spacer()
                Text("\(syncedCount)/\(model.units.count) synced")
                    .font(Signalwave.mono(.footnote))
                    .foregroundStyle(Signalwave.dim)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.footnote)
                    .foregroundStyle(Signalwave.dim)
                TextField("filter", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(Signalwave.mono(.subheadline))
                    .foregroundStyle(Signalwave.fg)
                    .tint(Signalwave.green)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Signalwave.dim)
                    }
                    .buttonStyle(.plain)
                }
            }
            .signalField()

            if model.units.isEmpty {
                emptyState
            } else if filteredUnits.isEmpty {
                Text("// no audio units match “\(query)”")
                    .font(Signalwave.mono(.subheadline))
                    .foregroundStyle(Signalwave.dim)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(filteredUnits.enumerated()), id: \.element.id) { index, unit in
                        if index > 0 {
                            Rectangle()
                                .fill(Signalwave.grid)
                                .frame(height: 1)
                        }
                        unitRow(unit)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Signalwave.grid, lineWidth: 1)
                )
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("// no auv3 audio units found")
                .font(Signalwave.mono(.subheadline, weight: .semibold))
                .foregroundStyle(Signalwave.fg)
            Text("install auv3 instruments/effects, then resync. third-party units need the inter-app audio entitlement.")
                .font(Signalwave.mono(.caption))
                .foregroundStyle(Signalwave.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Signalwave.grid, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func unitRow(_ unit: DiscoveredAudioUnit) -> some View {
        let status = model.statuses[unit.id] ?? .idle

        Button {
            Task { await model.inspect(unit) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                icon(unit)
                VStack(alignment: .leading, spacing: 3) {
                    Text(unit.name)
                        .font(Signalwave.mono(.body))
                        .foregroundStyle(Signalwave.fg)
                    Text(subtitle(unit))
                        .font(Signalwave.mono(.caption))
                        .foregroundStyle(Signalwave.dim)
                    if !status.text.isEmpty {
                        statusLabel(status)
                    }
                }

                Spacer(minLength: 8)

                if status.isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Signalwave.green)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(Signalwave.dim)
                        .padding(.top, 2)
                }
            }
            .contentShape(Rectangle())
            .padding(12)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("inspect \(unit.name)")
        .accessibilityHint("reads this audio unit locally and shows what was synced")
    }

    @ViewBuilder
    private func icon(_ unit: DiscoveredAudioUnit) -> some View {
        Group {
            if let image = unit.icon {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Signalwave.surface)
                    .overlay(
                        Image(systemName: "waveform")
                            .font(.system(size: 14))
                            .foregroundStyle(Signalwave.dim)
                    )
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Signalwave.grid, lineWidth: 1)
        )
    }

    private func subtitle(_ unit: DiscoveredAudioUnit) -> String {
        var parts = [unit.typeCode, unit.manufacturer]
        if !unit.version.isEmpty { parts.append("v\(unit.version)") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private func statusLabel(_ status: AudioUnitRowStatus) -> some View {
        let color: Color = status.isError ? Signalwave.amber : (status.isDone ? Signalwave.green : Signalwave.dim)
        let icon: String = status.isError
            ? "exclamationmark.triangle.fill"
            : (status.isDone ? "checkmark.circle.fill" : "ellipsis.circle")
        Label {
            Text(status.text)
        } icon: {
            Image(systemName: icon)
        }
        .font(Signalwave.mono(.caption))
        .foregroundStyle(color)
    }

    // MARK: - Status bar

    private var statusBar: some View {
        VStack(spacing: 8) {
            statusLine
            if let summary = model.runSummary {
                Text("> \(summary)")
                    .font(Signalwave.mono(.footnote))
                    .foregroundStyle(Signalwave.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(Signalwave.bg)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Signalwave.grid)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if model.isBusy {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(Signalwave.green)
                Text("syncing \(syncedCount)/\(model.units.count)…")
                    .font(Signalwave.mono(.footnote))
                    .foregroundStyle(Signalwave.fg)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if !receiver.isConfigured {
            consoleNote("waiting for mcp-midi-controller — units sync automatically once it is found.")
        } else if !receiver.isReachable {
            consoleNote("daemon discovered — connecting, then syncing automatically…")
        } else if model.runSummary == nil {
            consoleNote("connected — syncing automatically.")
        } else {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Signalwave.green)
                Text("synced to mcp-midi-controller")
                    .font(Signalwave.mono(.footnote))
                    .foregroundStyle(Signalwave.fg)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func consoleNote(_ text: String) -> some View {
        Text("// \(text)")
            .font(Signalwave.mono(.caption))
            .foregroundStyle(Signalwave.dim)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Identifiable pairing of an inspected unit id with its stashed details, used to
/// drive `.sheet(item:)` (a plain String is not `Identifiable`).
private struct InspectedAudioUnit: Identifiable {
    let id: String
    let details: AudioUnitDetails
}
