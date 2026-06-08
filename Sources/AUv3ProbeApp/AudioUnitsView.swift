import SwiftUI
import UniformTypeIdentifiers
import ProbeKit

// The audio-units tab, rendered in the signalwave design language (see
// docs/signalwave.md): a charcoal "sniffer console" that lists every installed
// AUv3 like a packet capture, exposes the details (parameters/presets) each one
// carries, and reads the armed rows from a fixed action bar.
//
// The daemon host lives in the shared Receiver (top bar in RootView), so this
// view reads it from the environment rather than owning a host field. UI chrome
// is lowercased; raw data (unit names, FourCC codes, counts) is shown verbatim.

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

            actionBar
        }
        .background(Signalwave.bg.ignoresSafeArea())
        .onAppear { if model.units.isEmpty { model.refresh() } }
        .fileExporter(
            isPresented: $model.isExporting,
            document: model.exportDocument,
            contentType: .json,
            defaultFilename: model.exportFilename
        ) { _ in }
        .sheet(item: inspectedBinding) { item in
            AudioUnitInspectorView(details: item.details)
        }
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
                Text("auv3 · parameters & presets")
                    .font(Signalwave.mono(.caption2))
                    .foregroundStyle(Signalwave.dim)
            }

            Spacer()

            Button {
                model.refresh()
            } label: {
                Label("rescan", systemImage: "arrow.clockwise")
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
                Text("\(model.selected.count)/\(model.units.count)")
                    .font(Signalwave.mono(.footnote))
                    .foregroundStyle(Signalwave.dim)
                Button("all") { model.selectAll() }
                    .buttonStyle(.signalGhost)
                    .disabled(model.units.isEmpty)
                Button("none") { model.selectNone() }
                    .buttonStyle(.signalGhost)
                    .disabled(model.selected.isEmpty)
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
            Text("install auv3 instruments/effects, then rescan. third-party units need the inter-app audio entitlement.")
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
        let isSelected = model.selected.contains(unit.id)

        HStack(alignment: .top, spacing: 12) {
            Button {
                model.toggle(unit.id)
            } label: {
                Text(isSelected ? "[x]" : "[ ]")
                    .font(Signalwave.mono(.body, weight: .bold))
                    .foregroundStyle(isSelected ? Signalwave.green : Signalwave.dim)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSelected ? "disarm \(unit.name)" : "arm \(unit.name)")

            Button {
                Task { await model.inspect(unit) }
            } label: {
                HStack(alignment: .top, spacing: 8) {
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

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(Signalwave.dim)
                        .padding(.top, 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("inspect \(unit.name)")
            .accessibilityHint("reads this audio unit locally and shows what would be sent")

            if status.isWorking {
                ProgressView()
                    .controlSize(.small)
                    .tint(Signalwave.green)
            } else if model.hasDetails(unit.id) {
                Button {
                    model.prepareExport(for: unit.id)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(Signalwave.green)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("save details to files")
            }
        }
        .padding(12)
        .background(isSelected ? Signalwave.surface : Color.clear)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(isSelected ? Signalwave.green : Color.clear)
                .frame(width: 2)
                .frame(width: 10, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { model.toggle(unit.id) }
        }
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

    // MARK: - Action bar

    private var actionBar: some View {
        VStack(spacing: 10) {
            if let summary = model.runSummary {
                Text("> \(summary)")
                    .font(Signalwave.mono(.footnote))
                    .foregroundStyle(Signalwave.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                Task { await model.scanAndSendSelected(client: receiver.client) }
            } label: {
                HStack(spacing: 10) {
                    if model.isBusy {
                        ProgressView().tint(Signalwave.bg)
                    } else {
                        Image(systemName: "dot.radiowaves.up.forward")
                    }
                    Text(sendLabel)
                }
            }
            .buttonStyle(.signalPrimary)
            .disabled(model.isBusy || model.selected.isEmpty)

            if !receiver.isConfigured {
                Text("// no mcp-midi-controller host — units are read and can be exported via the save button.")
                    .font(Signalwave.mono(.caption2))
                    .foregroundStyle(Signalwave.dim)
                    .multilineTextAlignment(.leading)
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

    private var sendLabel: String {
        let n = model.selected.count
        if model.isBusy { return "working…" }
        let configured = receiver.isConfigured
        if n == 0 { return configured ? "read & send" : "read" }
        return configured ? "read & send \(n)" : "read \(n)"
    }
}

/// Identifiable pairing of an inspected unit id with its stashed details, used to
/// drive `.sheet(item:)` (a plain String is not `Identifiable`).
private struct InspectedAudioUnit: Identifiable {
    let id: String
    let details: AudioUnitDetails
}
