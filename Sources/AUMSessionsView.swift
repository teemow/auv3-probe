import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// AUM full-session project file (`.aumproj`). Declared as an imported type
    /// in Info.plist (UTImportedTypeDeclarations) so the file picker and the
    /// share sheet recognise it and can route to AUM.
    static let aumProject = UTType(importedAs: "com.kymatica.aum.aumproj", conformingTo: .data)

    /// AUM standalone MIDI mapping file (`.aum_midimap`).
    static let aumMidiMap = UTType(importedAs: "com.kymatica.aum.aum-midimap", conformingTo: .data)
}

// The AUM-sessions tab, rendered in the signalwave design language (see
// docs/signalwave.md) to match the audio-units console. It works fully
// standalone — no daemon required:
//   - "aum sessions": link AUM's folder once (a security-scoped bookmark), and
//     the .aumproj / .aum_midimap files in it are listed. Tap one to parse it
//     on-device (AUMSessionParser) and open the inspector.
//   - "open file": pick any session/mapping file to inspect it locally.
//
// When a daemon host is configured (top bar in RootView), an optional ferry
// appears: upload device sessions to the daemon, and pull daemon-generated
// files back into AUM. None of the inspect/list flow depends on it.

struct AUMSessionsView: View {
    @EnvironmentObject private var receiver: Receiver
    @StateObject private var model = AUMSessionsModel()
    @StateObject private var folder = AUMFolderBookmark()
    @State private var isLinkingFolder = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Signalwave.grid)

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    folderSection
                    if receiver.isConfigured {
                        daemonSection
                    }
                }
                .padding(16)
                .padding(.bottom, 8)
            }
            .sheet(item: $model.shareItem) { item in
                ShareSheet(items: [item.url]) { completed in
                    model.finishShare(completed: completed)
                }
            }
            .fileImporter(
                isPresented: $isLinkingFolder,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                do {
                    try folder.handlePick(result)
                    model.refreshFolder(folder)
                } catch {
                    model.folderMessage = error.localizedDescription
                }
            }
        }
        .background(Signalwave.bg.ignoresSafeArea())
        .onAppear { if folder.isBound && model.folderFiles.isEmpty { model.refreshFolder(folder) } }
        .fileImporter(
            isPresented: $model.isImporting,
            allowedContentTypes: [.aumProject, .aumMidiMap, .data],
            allowsMultipleSelection: false
        ) { result in
            Task { await model.inspectPicked(result) }
        }
        .sheet(item: $model.inspected) { item in
            AUMSessionInspectorView(entry: item.entry, map: item.map)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("aum sessions")
                    .font(Signalwave.mono(.title3, weight: .bold))
                    .foregroundStyle(Signalwave.fg)
                Text("read & inspect on-device")
                    .font(Signalwave.mono(.caption2))
                    .foregroundStyle(Signalwave.dim)
            }

            Spacer()

            Button {
                model.isImporting = true
            } label: {
                Label("open file", systemImage: "doc.badge.plus")
            }
            .buttonStyle(.signalGhost)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Device sessions (linked AUM folder)

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionHeader("sessions on device")
                Spacer()
                if folder.isBound {
                    Button {
                        isLinkingFolder = true
                    } label: {
                        Label("relink", systemImage: "folder.badge.gearshape")
                    }
                    .buttonStyle(.signalGhost)
                }
            }

            if folder.isBound {
                boundFolderCard
                deviceFilesList
            } else {
                Button {
                    isLinkingFolder = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.badge.plus")
                        Text("link aum folder")
                    }
                }
                .buttonStyle(.signalGhost)

                Text("// link aum's folder to list your sessions, or use “open file” to inspect any .aumproj.")
                    .font(Signalwave.mono(.caption2))
                    .foregroundStyle(Signalwave.dim)
            }

            if let summary = model.uploadSummary { uploadSummaryCard(summary) }
            if let info = model.uploadInfo {
                consoleLine(info, icon: "checkmark.circle.fill", color: Signalwave.green)
            }
            if let message = model.uploadMessage {
                consoleLine(message, icon: "exclamationmark.triangle.fill", color: Signalwave.amber)
            }
            if let message = model.openMessage {
                consoleLine(message, icon: "exclamationmark.triangle.fill", color: Signalwave.amber)
            }
            if let message = model.folderMessage {
                consoleLine(message, icon: "exclamationmark.triangle.fill", color: Signalwave.amber)
            }
        }
    }

    private var boundFolderCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(Signalwave.green)
                Text(folder.folderName ?? "aum")
                    .font(Signalwave.mono(.body))
                    .foregroundStyle(Signalwave.fg)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                if model.isScanningFolder {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Signalwave.green)
                } else {
                    Text("\(model.folderFiles.count)")
                        .font(Signalwave.mono(.footnote))
                        .foregroundStyle(Signalwave.dim)
                }
            }

            HStack(spacing: 8) {
                Button {
                    model.refreshFolder(folder)
                } label: {
                    Label("rescan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.signalGhost)
                .disabled(model.isScanningFolder)

                if receiver.isConfigured {
                    Button {
                        Task { await model.uploadAllFromFolder(client: receiver.client, folder: folder) }
                    } label: {
                        Label("upload all", systemImage: "square.and.arrow.up.on.square")
                    }
                    .buttonStyle(.signalGhost)
                    .disabled(model.isUploading || model.folderFiles.isEmpty)
                }

                Spacer()

                Button {
                    folder.clear()
                    model.folderFiles = []
                    model.folderMessage = nil
                } label: {
                    Label("forget", systemImage: "xmark")
                }
                .buttonStyle(.signalGhost(Signalwave.amber))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Signalwave.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Signalwave.grid, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var deviceFilesList: some View {
        if model.folderFiles.isEmpty {
            if !model.isScanningFolder {
                Text("// no .aumproj / .aum_midimap files in this folder.")
                    .font(Signalwave.mono(.subheadline))
                    .foregroundStyle(Signalwave.dim)
                    .padding(.vertical, 4)
            }
        } else {
            VStack(spacing: 0) {
                ForEach(Array(model.folderFiles.enumerated()), id: \.element.id) { index, file in
                    if index > 0 {
                        Rectangle().fill(Signalwave.grid).frame(height: 1)
                    }
                    deviceFileRow(file)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Signalwave.grid, lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func deviceFileRow(_ file: AUMFolderFile) -> some View {
        let status = model.statuses[file.id] ?? .idle
        let isInspecting = model.inspectingID == file.id

        HStack(alignment: .top, spacing: 12) {
            Button {
                Task { await model.inspectLocalFile(file, folder: folder) }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(file.name)
                            .font(Signalwave.mono(.body))
                            .foregroundStyle(Signalwave.fg)
                        Text("\(file.isMidiMap ? "midimap" : "session") · \(byteLabel(file.bytes))")
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
            .accessibilityLabel("inspect \(file.name)")
            .accessibilityHint("parses the session on-device and shows channels, nodes and mappings")

            if isInspecting {
                ProgressView()
                    .controlSize(.small)
                    .tint(Signalwave.green)
            } else if receiver.isConfigured {
                Button {
                    Task { await model.uploadFromFolder(file, client: receiver.client, folder: folder) }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(Signalwave.green)
                }
                .buttonStyle(.plain)
                .disabled(model.isUploading)
                .accessibilityLabel("upload \(file.name) to the daemon")
            }
        }
        .padding(12)
    }

    // MARK: - Daemon ferry (optional; only with a host)

    private var daemonSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SectionHeader("daemon files")
                Spacer()
                if model.isListing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Signalwave.green)
                } else {
                    Text("\(model.entries.count)")
                        .font(Signalwave.mono(.footnote))
                        .foregroundStyle(Signalwave.dim)
                }
                Button {
                    Task { await model.refreshSessions(client: receiver.client) }
                } label: {
                    Label("refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.signalGhost)
                .disabled(model.isListing)
            }

            if model.entries.isEmpty {
                Text(model.listMessage.map { "// \($0)" } ?? "// tap refresh to load files the daemon can return into aum.")
                    .font(Signalwave.mono(.subheadline))
                    .foregroundStyle(Signalwave.dim)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            Rectangle().fill(Signalwave.grid).frame(height: 1)
                        }
                        daemonRow(entry)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Signalwave.grid, lineWidth: 1)
                )

                if let message = model.listMessage {
                    consoleLine(message, icon: "exclamationmark.triangle.fill", color: Signalwave.amber)
                }
            }
        }
    }

    @ViewBuilder
    private func daemonRow(_ entry: AUMSessionEntry) -> some View {
        let status = model.statuses[entry.id] ?? .idle
        let isInspecting = model.inspectingID == entry.id

        HStack(alignment: .top, spacing: 12) {
            Button {
                Task { await model.inspect(entry, client: receiver.client) }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.filename)
                            .font(Signalwave.mono(.body))
                            .foregroundStyle(Signalwave.fg)
                        Text(daemonSubtitle(entry))
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
            .accessibilityLabel("inspect \(entry.filename)")

            if isInspecting || status.isWorking {
                ProgressView()
                    .controlSize(.small)
                    .tint(Signalwave.green)
            } else {
                Button {
                    Task { await model.download(entry, client: receiver.client, folder: folder) }
                } label: {
                    Image(systemName: folder.isBound ? "square.and.arrow.down" : "square.and.arrow.up")
                        .foregroundStyle(Signalwave.green)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(folder.isBound
                    ? "save \(entry.filename) into the linked aum folder"
                    : "share \(entry.filename) to open in aum")
            }
        }
        .padding(12)
    }

    private func daemonSubtitle(_ entry: AUMSessionEntry) -> String {
        var parts = [entry.isMidiMap ? "midimap" : "session"]
        if entry.generated { parts.append("generated") }
        parts.append(byteLabel(entry.bytes))
        return parts.joined(separator: " · ")
    }

    // MARK: - Shared bits

    private func uploadSummaryCard(_ summary: AUMSessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary.title.isEmpty ? "(untitled session)" : summary.title)
                .font(Signalwave.mono(.body))
                .foregroundStyle(Signalwave.fg)
            Text("v\(summary.version) · \(summary.channels) channels · \(summary.nodes) nodes · \(summary.mapped) mapped")
                .font(Signalwave.mono(.caption))
                .foregroundStyle(Signalwave.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Signalwave.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Signalwave.grid, lineWidth: 1)
        )
    }

    private func byteLabel(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }

    @ViewBuilder
    private func statusLabel(_ status: AUMSessionRowStatus) -> some View {
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
}
