import SwiftUI
import UniformTypeIdentifiers

// The single-screen probe UI, rendered in the signalwave design language (see
// docs/signalwave.md): a charcoal "sniffer console" that lists every installed
// AUv3 like a packet capture, exposes what each one broadcasts, and probes the
// armed rows from a fixed action bar.
//
// Layout is hand-built (not a system Form) so it can adopt the full aesthetic:
// deep charcoal field, monospaced lowercase chrome, a single cyber-green signal
// accent, slate hairline dividers, hard edges. UI chrome is lowercased; raw data
// (plugin names, FourCC codes, counts) is shown verbatim — "no obfuscation".

struct ContentView: View {
    @StateObject private var model = ProbeModel()
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
        ZStack {
            Signalwave.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().overlay(Signalwave.grid)

                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        receiverSection
                        pluginsSection
                    }
                    .padding(16)
                    .padding(.bottom, 8)
                }

                actionBar
            }
        }
        .tint(Signalwave.green)
        .preferredColorScheme(.dark)
        .onAppear { if model.units.isEmpty { model.refresh() } }
        .fileExporter(
            isPresented: $model.isExporting,
            document: model.exportDocument,
            contentType: .json,
            defaultFilename: model.exportFilename
        ) { _ in }
        .sheet(item: inspectedBinding) { item in
            ProbeInspectorView(dump: item.dump)
        }
    }

    /// Bridges `model.inspectedID` (a plain id) to a `.sheet(item:)` binding by
    /// pairing it with its stashed dump; clearing the binding dismisses the
    /// sheet by nilling `inspectedID`.
    private var inspectedBinding: Binding<InspectedPlugin?> {
        Binding(
            get: {
                guard let id = model.inspectedID, let dump = model.dump(id) else { return nil }
                return InspectedPlugin(id: id, dump: dump)
            },
            set: { newValue in model.inspectedID = newValue?.id }
        )
    }

    // MARK: - Header / wordmark

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            WaveGlyph()
                .frame(width: 40, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("auv3probe")
                    .font(Signalwave.mono(.title3, weight: .bold))
                    .foregroundStyle(Signalwave.fg)
                Text("auv3 parameter-tree sniffer")
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

    // MARK: - Receiver

    private var receiverSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("receiver")

            HStack(spacing: 8) {
                Text(">")
                    .font(Signalwave.mono(.body, weight: .bold))
                    .foregroundStyle(Signalwave.green)
                TextField("host:7800", text: $model.host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(Signalwave.mono(.body))
                    .foregroundStyle(Signalwave.fg)
                    .tint(Signalwave.green)
            }
            .signalField()

            HStack(spacing: 12) {
                Button {
                    Task { await model.testConnection() }
                } label: {
                    Label("test connection", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(.signalGhost)
                .disabled(model.isBusy || model.host.trimmingCharacters(in: .whitespaces).isEmpty)

                if model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Signalwave.green)
                }
                Spacer()
            }

            if let message = model.connectionMessage {
                consoleLine(
                    message,
                    icon: model.connectionOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    color: model.connectionOK ? Signalwave.green : Signalwave.amber)
            }

            Text("// receiver on your lan (default :7800). last host is remembered.")
                .font(Signalwave.mono(.caption2))
                .foregroundStyle(Signalwave.dim)
        }
    }

    // MARK: - Plugins

    private var pluginsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SectionHeader("plugins")
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
                Text("// no plugins match “\(query)”")
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
                        pluginRow(unit)
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
            Text("// no auv3 plugins found")
                .font(Signalwave.mono(.subheadline, weight: .semibold))
                .foregroundStyle(Signalwave.fg)
            Text("install auv3 instruments/effects, then rescan. third-party plugins need the inter-app audio entitlement.")
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
    private func pluginRow(_ unit: DiscoveredAudioUnit) -> some View {
        let status = model.statuses[unit.id] ?? .idle
        let isSelected = model.selected.contains(unit.id)

        HStack(alignment: .top, spacing: 12) {
            // Arming target: the checkbox + left signal bar toggle batch select.
            // The probe-armed marker reads like a checkbox in a capture list.
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

            // Inspect target: tapping the name/body probes this one locally
            // (no send) and opens the inspector overlay.
            Button {
                Task { await model.inspect(unit) }
            } label: {
                HStack(alignment: .top, spacing: 8) {
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
            .accessibilityHint("probes locally and shows what would be sent")

            if status.isWorking {
                ProgressView()
                    .controlSize(.small)
                    .tint(Signalwave.green)
            } else if model.hasDump(unit.id) {
                Button {
                    model.prepareExport(for: unit.id)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(Signalwave.green)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("save dump to files")
            }
        }
        .padding(12)
        .background(isSelected ? Signalwave.surface : Color.clear)
        .overlay(alignment: .leading) {
            // A left signal bar marks an armed row; tapping it also toggles arm.
            Rectangle()
                .fill(isSelected ? Signalwave.green : Color.clear)
                .frame(width: 2)
                .contentShape(Rectangle())
                .onTapGesture { model.toggle(unit.id) }
        }
    }

    private func subtitle(_ unit: DiscoveredAudioUnit) -> String {
        var parts = [unit.typeCode, unit.manufacturer]
        if !unit.version.isEmpty { parts.append("v\(unit.version)") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private func statusLabel(_ status: RowStatus) -> some View {
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

    private func consoleLine(_ text: String, icon: String, color: Color) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: icon)
        }
        .font(Signalwave.mono(.footnote))
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
                Task { await model.probeAndSendSelected() }
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

            if !model.canSend {
                Text("// no receiver host — plugins are probed and can be exported via the save button.")
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
        if n == 0 { return model.canSend ? "probe & send" : "probe" }
        return model.canSend ? "probe & send \(n)" : "probe \(n)"
    }
}

/// Identifiable pairing of an inspected plugin id with its stashed dump, used to
/// drive `.sheet(item:)` (a plain id/String is not `Identifiable`).
private struct InspectedPlugin: Identifiable {
    let id: String
    let dump: ProbeDump
}
