import SwiftUI

// The single-screen probe UI: enter the receiver host, test it, pick the
// installed AUv3s to probe, then Probe & Send. Each row shows its own status
// and a Save-to-Files action for manual transfer when the receiver is down.

struct ContentView: View {
    @StateObject private var model = ProbeModel()

    var body: some View {
        NavigationView {
            Form {
                receiverSection
                pluginsSection
            }
            .navigationTitle("AUv3 Probe")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Rescan") { model.refresh() }
                        .disabled(model.isBusy)
                }
            }
            .onAppear { if model.units.isEmpty { model.refresh() } }
            .fileExporter(
                isPresented: $model.isExporting,
                document: model.exportDocument,
                contentType: .json,
                defaultFilename: model.exportFilename
            ) { _ in }
        }
        .navigationViewStyle(.stack)
    }

    private var receiverSection: some View {
        Section("Receiver") {
            TextField("host:7800", text: $model.host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

            HStack {
                Button("Test connection") {
                    Task { await model.testConnection() }
                }
                .disabled(model.isBusy || model.host.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                if model.isBusy { ProgressView() }
            }

            if let message = model.connectionMessage {
                Label(message, systemImage: model.connectionOK ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundColor(model.connectionOK ? .green : .orange)
                    .font(.footnote)
            }
        }
    }

    private var pluginsSection: some View {
        Section {
            if model.units.isEmpty {
                Text("No AUv3 instruments or effects found.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(model.units) { unit in
                    pluginRow(unit)
                }
            }
        } header: {
            HStack {
                Text("Plugins (\(model.selected.count)/\(model.units.count))")
                Spacer()
                Button("All") { model.selectAll() }.font(.footnote)
                Button("None") { model.selectNone() }.font(.footnote)
            }
        } footer: {
            Button {
                Task { await model.probeAndSendSelected() }
            } label: {
                Label("Probe & Send", systemImage: "paperplane")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isBusy || model.selected.isEmpty)
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func pluginRow(_ unit: DiscoveredAudioUnit) -> some View {
        let status = model.statuses[unit.id] ?? .idle
        Button {
            model.toggle(unit.id)
        } label: {
            HStack(alignment: .top) {
                Image(systemName: model.selected.contains(unit.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(unit.name).foregroundColor(.primary)
                    Text("\(unit.manufacturer) · \(unit.typeName)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if !status.text.isEmpty {
                        Text(status.text)
                            .font(.caption)
                            .foregroundColor(status.isError ? .orange : (status.isDone ? .green : .secondary))
                    }
                }
                Spacer()
                if model.hasDump(unit.id) {
                    Button {
                        model.prepareExport(for: unit.id)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
