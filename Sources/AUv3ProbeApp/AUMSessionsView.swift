import SwiftUI
import UniformTypeIdentifiers
import ProbeKit

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

    // A single file picker drives both "open a file" and "link the AUM folder";
    // `pickingFolder` selects the mode. (Two separate `.fileImporter`s on one
    // view silently collide — only one ever presents.)
    @State private var isPicking = false
    @State private var pickingFolder = false

    // The selected top-level subfolder filter for the linked AUM folder, or nil
    // for "all". AUM nests sessions per set, so this narrows the list to one set.
    @State private var folderFilter: String?

    // Confirmation for clearing all staged files on mcp-midi-controller.
    @State private var showClearConfirm = false

    // The mcp-midi-controller entry the user is choosing a destination folder for
    // (drives the destination picker sheet). Only used when a folder is linked.
    @State private var destinationFor: AUMSessionEntry?

    private func pickFile() {
        pickingFolder = false
        isPicking = true
    }

    private func linkFolder() {
        pickingFolder = true
        isPicking = true
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Signalwave.grid)

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    folderSection
                    daemonSection
                }
                .padding(16)
                .padding(.bottom, 8)
            }
            .sheet(item: $model.shareItem) { item in
                ShareSheet(items: [item.url]) { completed in
                    model.finishShare(completed: completed)
                }
            }
        }
        .background(Signalwave.bg.ignoresSafeArea())
        .onAppear {
            if folder.isBound && model.folderFiles.isEmpty { model.refreshFolder(folder) }
            if receiver.isConfigured && model.entries.isEmpty {
                Task { await model.refreshSessions(client: receiver.client) }
            }
            triggerAutoSync()
        }
        .onChange(of: receiver.isReachable) { _ in triggerAutoSync() }
        .onChange(of: receiver.host) { _ in triggerAutoSync() }
        .fileImporter(
            isPresented: $isPicking,
            allowedContentTypes: pickingFolder ? [.folder] : [.aumProject, .aumMidiMap, .data],
            allowsMultipleSelection: false
        ) { result in
            if pickingFolder {
                do {
                    try folder.handlePick(result)
                    model.refreshFolder(folder)
                } catch {
                    model.folderMessage = error.localizedDescription
                }
            } else {
                Task { await model.inspectPicked(result) }
            }
        }
        .sheet(item: $model.inspected) { item in
            AUMSessionInspectorView(entry: item.entry, map: item.map)
        }
        .sheet(item: $destinationFor) { entry in
            destinationPicker(entry)
        }
    }

    /// Fire an auto-sync of the linked AUM folder when the daemon is reachable
    /// (the session sibling of the audio-units auto-sync). The model itself
    /// guards against re-syncing the same host, overlapping runs, and the
    /// no-folder case.
    private func triggerAutoSync() {
        guard receiver.isReachable,
              let client = receiver.client,
              let host = receiver.host else { return }
        Task { await model.autoSync(client: client, host: host, folder: folder) }
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
                pickFile()
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
                        linkFolder()
                    } label: {
                        Label("relink", systemImage: "folder.badge.gearshape")
                    }
                    .buttonStyle(.signalGhost)
                }
            }

            if folder.isBound {
                boundFolderCard
                subfolderFilterBar
                deviceFilesList
            } else {
                HStack(spacing: 8) {
                    Button {
                        linkFolder()
                    } label: {
                        Label("link aum folder", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.signalGhost)

                    Button {
                        pickFile()
                    } label: {
                        Label("open one file", systemImage: "doc.badge.plus")
                    }
                    .buttonStyle(.signalGhost)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("// link — remember aum's folder: lists every session for one-tap inspect, upload & write-back.")
                    Text("// open one file — a one-off: inspect a single .aumproj/.aum_midimap, nothing is remembered.")
                }
                .font(Signalwave.mono(.caption2))
                .foregroundStyle(Signalwave.dim)
                .fixedSize(horizontal: false, vertical: true)
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
                    Text(folderFilter == nil
                         ? "\(model.folderFiles.count)"
                         : "\(visibleFolderFiles.count)/\(model.folderFiles.count)")
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
                        Task { await model.uploadAllFromFolder(visibleFolderFiles, client: receiver.client, folder: folder) }
                    } label: {
                        Label(folderFilter == nil ? "upload all" : "upload shown",
                              systemImage: "square.and.arrow.up.on.square")
                    }
                    .buttonStyle(.signalGhost)
                    .disabled(model.isUploading || visibleFolderFiles.isEmpty)
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

    // MARK: - Subfolder filter

    /// The file's top-level subfolder within the linked root ("" for root-level
    /// files). AUM groups sessions one set per folder, so this is the natural
    /// filter granularity.
    private func topFolder(_ file: AUMFolderFile) -> String {
        let sub = file.subfolder
        guard !sub.isEmpty else { return "" }
        return sub.components(separatedBy: "/").first ?? sub
    }

    /// Distinct top-level subfolders with their file counts, root first then
    /// alphabetical.
    private var subfolderGroups: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for file in model.folderFiles { counts[topFolder(file), default: 0] += 1 }
        return counts.map { (name: $0.key, count: $0.value) }
            .sorted {
                if $0.name.isEmpty != $1.name.isEmpty { return $0.name.isEmpty }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    /// The files shown after applying `folderFilter`. Falls back to all when the
    /// selected folder no longer matches anything (e.g. after a rescan).
    private var visibleFolderFiles: [AUMFolderFile] {
        guard let filter = folderFilter else { return model.folderFiles }
        let filtered = model.folderFiles.filter { topFolder($0) == filter }
        return filtered.isEmpty ? model.folderFiles : filtered
    }

    @ViewBuilder
    private var subfolderFilterBar: some View {
        let groups = subfolderGroups
        if groups.count > 1 {
            WrapLayout(spacing: 6, lineSpacing: 6) {
                folderChip("all (\(model.folderFiles.count))", isActive: folderFilter == nil) {
                    folderFilter = nil
                }
                ForEach(groups, id: \.name) { group in
                    folderChip("\(group.name.isEmpty ? "/" : group.name) (\(group.count))",
                               isActive: folderFilter == group.name) {
                        folderFilter = (folderFilter == group.name) ? nil : group.name
                    }
                }
            }
        }
    }

    private func folderChip(_ title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Signalwave.mono(.caption2, weight: .semibold))
                .foregroundStyle(isActive ? Signalwave.bg : Signalwave.green)
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(isActive ? Signalwave.green : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(Signalwave.green.opacity(0.4), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var deviceFilesList: some View {
        if model.folderFiles.isEmpty {
            if !model.isScanningFolder {
                Text("// no .aumproj / .aum_midimap files here or in any subfolder.")
                    .font(Signalwave.mono(.subheadline))
                    .foregroundStyle(Signalwave.dim)
                    .padding(.vertical, 4)
            }
        } else {
            VStack(spacing: 0) {
                ForEach(Array(visibleFolderFiles.enumerated()), id: \.element.id) { index, file in
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
                        if !file.subfolder.isEmpty {
                            Text("\(file.subfolder)/")
                                .font(Signalwave.mono(.caption2))
                                .foregroundStyle(Signalwave.dim)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Text([file.isMidiMap ? "midimap" : "session", byteLabel(file.bytes), dateLabel(file.modified)]
                            .compactMap { $0 }
                            .joined(separator: " · "))
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

            if isInspecting || status.isWorking {
                ProgressView()
                    .controlSize(.small)
                    .tint(Signalwave.green)
            } else if receiver.isConfigured {
                Button {
                    Task { await model.uploadFromFolder(file, client: receiver.client, folder: folder) }
                } label: {
                    Image(systemName: status.isDone ? "checkmark.circle" : "square.and.arrow.up")
                        .foregroundStyle(Signalwave.green)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(status.isDone
                    ? "re-upload \(file.name) to mcp-midi-controller"
                    : "upload \(file.name) to mcp-midi-controller")
            }
        }
        .padding(12)
    }

    // MARK: - Daemon ferry (optional; only with a host)

    @ViewBuilder
    private var daemonSection: some View {
        if receiver.isConfigured {
            daemonFerry
        } else {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("mcp-midi-controller")
                Text("// waiting for mcp-midi-controller on the lan… upload / pull-back appears here once it is discovered. set a host manually from the bar above if mdns is blocked.")
                    .font(Signalwave.mono(.caption2))
                    .foregroundStyle(Signalwave.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var daemonFerry: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SectionHeader("mcp-midi-controller")
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

                if !model.entries.isEmpty {
                    Button {
                        showClearConfirm = true
                    } label: {
                        Label("clear", systemImage: "trash")
                    }
                    .buttonStyle(.signalGhost(Signalwave.amber))
                    .disabled(model.isListing)
                }
            }
            .confirmationDialog(
                "Delete all staged sessions from mcp-midi-controller? This does not touch any files on this iPad.",
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear mcp-midi-controller", role: .destructive) {
                    Task { await model.clearSessions(client: receiver.client) }
                }
                Button("Cancel", role: .cancel) {}
            }

            if model.entries.isEmpty {
                Text(model.listMessage.map { "// \($0)" } ?? "// tap refresh to load files mcp-midi-controller can return into aum.")
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
                // One labeled menu instead of three icon-only buttons (two of
                // which used to change meaning with the folder-link state). Each
                // action now reads as plain text, so nothing is ambiguous.
                Menu {
                    if folder.isBound && !entry.isMidiMap {
                        Button {
                            Task { await model.pushAndOpen(entry, client: receiver.client, folder: folder) }
                        } label: {
                            Label("push into aum & open", systemImage: "play.circle")
                        }
                    }

                    if folder.isBound {
                        Button {
                            destinationFor = entry
                        } label: {
                            Label("save into aum folder…", systemImage: "square.and.arrow.down")
                        }
                    } else {
                        Button {
                            Task { await model.download(entry, client: receiver.client, folder: folder) }
                        } label: {
                            Label("share to open in aum", systemImage: "square.and.arrow.up")
                        }
                    }

                    Divider()

                    Button(role: .destructive) {
                        Task { await model.deleteEntry(entry, client: receiver.client) }
                    } label: {
                        Label("delete from mcp-midi-controller", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Signalwave.green)
                        .padding(.leading, 4)
                }
                .tint(Signalwave.green)
                .accessibilityLabel("actions for \(entry.filename)")
            }
        }
        .padding(12)
    }

    private func daemonSubtitle(_ entry: AUMSessionEntry) -> String {
        // Mirror the device row: kind · bytes · date (· generated).
        var parts = [entry.isMidiMap ? "midimap" : "session", byteLabel(entry.bytes)]
        if let date = dateLabel(rfc3339: entry.modified) {
            parts.append(date)
        }
        if entry.generated {
            parts.append("generated")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Destination picker (where a downloaded session lands in AUM)

    @ViewBuilder
    private func destinationPicker(_ entry: AUMSessionEntry) -> some View {
        let existing = model.folderFiles.first { $0.name == entry.filename }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("// where in \(folder.folderName ?? "aum") should this go?")
                        .font(Signalwave.mono(.caption))
                        .foregroundStyle(Signalwave.dim)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 8)

                    destinationOption(
                        entry,
                        subfolder: "",
                        title: "/ (root)",
                        isCurrent: existing.map { $0.subfolder.isEmpty } ?? false
                    )
                    ForEach(model.folderSubfolders, id: \.self) { sub in
                        Rectangle().fill(Signalwave.grid).frame(height: 1)
                            .padding(.leading, 16)
                        destinationOption(
                            entry,
                            subfolder: sub,
                            title: sub,
                            isCurrent: existing?.subfolder == sub
                        )
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Signalwave.grid, lineWidth: 1)
                        .padding(.horizontal, 0)
                )
            }
            .background(Signalwave.bg.ignoresSafeArea())
            .navigationTitle(entry.filename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { destinationFor = nil }
                }
            }
        }
    }

    private func destinationOption(_ entry: AUMSessionEntry, subfolder: String, title: String, isCurrent: Bool) -> some View {
        Button {
            destinationFor = nil
            Task { await model.saveToFolder(entry, into: subfolder, client: receiver.client, folder: folder) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .foregroundStyle(Signalwave.dim)
                Text(title)
                    .font(Signalwave.mono(.body))
                    .foregroundStyle(Signalwave.fg)
                    .lineLimit(1)
                    .truncationMode(.head)
                if isCurrent {
                    Text("current")
                        .font(Signalwave.mono(.caption2))
                        .foregroundStyle(Signalwave.amber)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.down.to.line")
                    .font(.caption)
                    .foregroundStyle(Signalwave.green)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Shared bits

    private func uploadSummaryCard(_ summary: AUMSessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary.title.isEmpty ? "(untitled session)" : summary.title)
                .font(Signalwave.mono(.body))
                .foregroundStyle(Signalwave.fg)
            Text("v\(summary.version) · \(summary.channels) channels · \(summary.mappings) mapped")
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

    private static let fileDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func dateLabel(_ date: Date?) -> String? {
        guard let date = date else { return nil }
        return Self.fileDateFormatter.string(from: date)
    }

    /// Formats the receiver's RFC3339 `modified` string with the same style as
    /// local file dates, so device and mcp-midi-controller rows read identically.
    /// Reuses the controller client's formatter — the wire format is the same.
    private func dateLabel(rfc3339: String) -> String? {
        guard !rfc3339.isEmpty,
              let date = DaemonClient.rfc3339.date(from: rfc3339) else { return nil }
        return dateLabel(date)
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
