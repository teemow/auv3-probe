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
// docs/signalwave.md): one folder browser over the single logical session
// library described in docs/aum-sessions-tab.md. The iPad's linked AUM folder
// and mcp-midi-controller's staging dir are two replicas kept identical by
// AUMSyncEngine; each file appears once, with a sync badge instead of the old
// upload/download buttons.
//
//   - Browser: NavigationStack drill-down through the AUM folder's real
//     subfolders. Tap a session to open it in AUM (Universal Link); inspect
//     lives in each row's menu. (No per-row controller delete here: the device
//     copy would resync it right back — see fileRow.)
//   - Pinned folder + last visited: any folder can be pinned to the top of
//     root, and the browser reopens where it was (both UserDefaults).
//   - Inbox: files that arrived/changed from the controller since last viewed.
//   - Sync: automatic — on reachability, foreground, tab appear, and a light
//     foreground poll (cheap thanks to the manifest rev).
//
// Fully standalone with no daemon: the browser shows the device copy, and
// tap-to-inspect (on-device parser) keeps working. With no AUM folder linked,
// the onboarding copy plus a controller fallback list (inspect / share into
// AUM) remain.

struct AUMSessionsView: View {
    @EnvironmentObject private var receiver: Receiver
    @StateObject private var model = AUMSessionsModel()
    @StateObject private var folder = AUMFolderBookmark()
    @StateObject private var engine = AUMSyncEngine()
    @Environment(\.scenePhase) private var scenePhase

    // A single file picker drives both "open a file" and "link the AUM folder";
    // `pickingFolder` selects the mode. (Two separate `.fileImporter`s on one
    // view silently collide — only one ever presents.)
    @State private var isPicking = false
    @State private var pickingFolder = false

    // Browser navigation: each element is a folder's relative path; the stack
    // is the chain from root ("Live sets" → "Live sets/ambient" → …).
    @State private var navPath: [String] = []
    @State private var restoredLastFolder = false

    /// A folder pinned to the top of the root view, and where the browser was
    /// last (both relative paths, "" = none/root). User settings, never
    /// hardcoded — set lists, band folders etc. are private rig data.
    @AppStorage("aumPinnedFolder") private var pinnedFolder = ""
    @AppStorage("aumLastFolder") private var lastVisitedFolder = ""

    // Confirmation for clearing all staged files on mcp-midi-controller.
    @State private var showClearConfirm = false

    /// Lightweight foreground poll. The manifest rev makes an idle tick a
    /// single tiny request, so a short interval is affordable.
    private let pollTimer = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    private func pickFile() {
        pickingFolder = false
        isPicking = true
    }

    private func linkFolder() {
        pickingFolder = true
        isPicking = true
    }

    /// Fire one sync cycle. Cheap when nothing changed (manifest rev 304 +
    /// local enumeration), so every trigger funnels through here.
    private func triggerSync() {
        engine.kick(client: receiver.client, folder: folder)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Signalwave.grid)

            if folder.isBound {
                NavigationStack(path: $navPath) {
                    browser(prefix: "")
                        .toolbar(.hidden, for: .navigationBar)
                        .navigationDestination(for: String.self) { prefix in
                            browser(prefix: prefix)
                                .navigationTitle((prefix as NSString).lastPathComponent)
                                .navigationBarTitleDisplayMode(.inline)
                                .toolbarBackground(Signalwave.bg, for: .navigationBar)
                                .toolbarBackground(.visible, for: .navigationBar)
                        }
                }
            } else {
                ScrollView {
                    unlinkedSection
                        .padding(16)
                }
            }

            Divider().overlay(Signalwave.grid)
            controllerFooter
        }
        .background(Signalwave.bg.ignoresSafeArea())
        .onAppear {
            restoreLastVisitedFolder()
            triggerSync()
        }
        .onChange(of: receiver.isReachable) { _ in triggerSync() }
        .onChange(of: receiver.host) { _ in triggerSync() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { triggerSync() }
        }
        .onReceive(pollTimer) { _ in
            if scenePhase == .active { triggerSync() }
        }
        .onChange(of: navPath) { path in
            lastVisitedFolder = path.last ?? ""
        }
        .fileImporter(
            isPresented: $isPicking,
            allowedContentTypes: pickingFolder ? [.folder] : [.aumProject, .aumMidiMap, .data],
            allowsMultipleSelection: false
        ) { result in
            if pickingFolder {
                do {
                    try folder.handlePick(result)
                    // A different folder is a different library: old
                    // fingerprints must not be diffed against it.
                    engine.reset()
                    navPath = []
                    triggerSync()
                } catch {
                    model.actionMessage = error.localizedDescription
                }
            } else {
                Task { await model.inspectPicked(result) }
            }
        }
        .sheet(item: $model.inspected) { item in
            AUMSessionInspectorView(entry: item.entry, map: item.map)
        }
        .sheet(item: $model.shareItem) { item in
            ShareSheet(items: [item.url]) { completed in
                model.finishShare(completed: completed)
            }
        }
    }

    /// Reopen the browser at the folder it was last in (once, on first appear).
    private func restoreLastVisitedFolder() {
        guard !restoredLastFolder else { return }
        restoredLastFolder = true
        guard folder.isBound, !lastVisitedFolder.isEmpty else { return }
        // Push the whole chain so back walks up the hierarchy.
        var chain: [String] = []
        var prefix = ""
        for segment in lastVisitedFolder.split(separator: "/") {
            prefix = prefix.isEmpty ? String(segment) : "\(prefix)/\(segment)"
            chain.append(prefix)
        }
        navPath = chain
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("aum sessions")
                    .font(Signalwave.mono(.title3, weight: .bold))
                    .foregroundStyle(Signalwave.fg)
                syncStatusLine
            }

            Spacer()

            if folder.isBound {
                Button {
                    triggerSync()
                } label: {
                    Label("sync", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.signalGhost)
                .disabled(engine.isSyncing)
            }

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

    /// The header's one-line sync state: "synced · 134 files · 8:24",
    /// "pulling 3…", "controller offline — browsing device copy", …
    @ViewBuilder
    private var syncStatusLine: some View {
        let (text, color): (String, Color) = {
            if engine.conflictCount > 0, !engine.isSyncing {
                return ("\(engine.conflictCount) conflict\(engine.conflictCount == 1 ? "" : "s") — pick a side below", Signalwave.amber)
            }
            switch engine.status {
            case .idle:
                return ("read & inspect on-device", Signalwave.dim)
            case .syncing(let what):
                return (what, Signalwave.dim)
            case .synced(let files, let at):
                return ("synced · \(files) file\(files == 1 ? "" : "s") · \(Self.timeFormatter.string(from: at))", Signalwave.dim)
            case .offline:
                return ("controller offline — browsing device copy", Signalwave.dim)
            case .failed(let why):
                return (why, Signalwave.amber)
            }
        }()
        Text(text)
            .font(Signalwave.mono(.caption2))
            .foregroundStyle(color)
    }

    // MARK: - Browser (linked folder)

    /// One level of the folder browser: the subfolders and files directly
    /// under `prefix` ("" = the AUM folder root).
    private func browser(prefix: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if prefix.isEmpty {
                    inboxStrip
                    pinnedSection
                }

                let folders = subfolders(of: prefix)
                let files = files(in: prefix)

                if !folders.isEmpty {
                    signalList(folders) { folderRow($0) }
                }

                if !files.isEmpty {
                    signalList(files) { fileRow($0) }
                }

                if folders.isEmpty && files.isEmpty {
                    Text("// no sessions here yet. authored sessions sync in automatically once the controller is reachable.")
                        .font(Signalwave.mono(.subheadline))
                        .foregroundStyle(Signalwave.dim)
                        .padding(.vertical, 4)
                }

                if let message = model.actionMessage {
                    consoleLine(message, icon: "exclamationmark.triangle.fill", color: Signalwave.amber)
                }
            }
            .padding(16)
            .padding(.bottom, 8)
        }
        .background(Signalwave.bg.ignoresSafeArea())
    }

    /// One subfolder listing entry: name, recursive file count, attention dot.
    private struct Subfolder: Identifiable, Equatable {
        let path: String       // relative path from the AUM root
        let name: String       // last segment, what the row shows
        let count: Int         // files anywhere underneath

        var id: String { path }
    }

    /// The direct subfolders of `prefix`, with recursive file counts.
    private func subfolders(of prefix: String) -> [Subfolder] {
        var counts: [String: Int] = [:]
        for file in engine.deviceFiles {
            let rel = file.relativePath
            let rest: String
            if prefix.isEmpty {
                rest = rel
            } else if rel.hasPrefix(prefix + "/") {
                rest = String(rel.dropFirst(prefix.count + 1))
            } else {
                continue
            }
            let segments = rest.split(separator: "/")
            guard segments.count > 1 else { continue }   // a file directly here
            counts[String(segments[0]), default: 0] += 1
        }
        return counts
            .map { name, count in
                Subfolder(
                    path: prefix.isEmpty ? name : "\(prefix)/\(name)",
                    name: name,
                    count: count
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The files sitting directly in `prefix` (not in deeper subfolders).
    private func files(in prefix: String) -> [AUMFolderFile] {
        engine.deviceFiles.filter { $0.subfolder == prefix }
    }

    private func folderRow(_ sub: Subfolder, pinnedRow: Bool = false) -> some View {
        NavigationLink(value: sub.path) {
            HStack(spacing: 10) {
                Image(systemName: pinnedRow ? "pin.fill" : "folder")
                    .foregroundStyle(pinnedRow ? Signalwave.green : Signalwave.dim)
                Text(sub.name)
                    .font(Signalwave.mono(.body))
                    .foregroundStyle(Signalwave.fg)
                    .lineLimit(1)
                    .truncationMode(.head)
                if engine.needsAttention(under: sub.path) {
                    Circle()
                        .fill(Signalwave.amber)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel("has changes that need attention")
                }
                Spacer(minLength: 8)
                Text("\(sub.count)")
                    .font(Signalwave.mono(.footnote))
                    .foregroundStyle(Signalwave.dim)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Signalwave.dim)
            }
            .contentShape(Rectangle())
            .padding(12)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if pinnedFolder == sub.path {
                Button {
                    pinnedFolder = ""
                } label: {
                    Label("unpin", systemImage: "pin.slash")
                }
            } else {
                Button {
                    pinnedFolder = sub.path
                } label: {
                    Label("pin to top", systemImage: "pin")
                }
            }
        }
    }

    // MARK: - Pinned folder

    @ViewBuilder
    private var pinnedSection: some View {
        if !pinnedFolder.isEmpty {
            let count = engine.deviceFiles.filter {
                $0.relativePath.hasPrefix(pinnedFolder + "/")
            }.count
            folderRow(
                Subfolder(
                    path: pinnedFolder,
                    name: (pinnedFolder as NSString).lastPathComponent,
                    count: count
                ),
                pinnedRow: true
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Signalwave.green.opacity(0.4), lineWidth: 1)
            )
        }
    }

    // MARK: - Inbox (new/changed from controller)

    @ViewBuilder
    private var inboxStrip: some View {
        if !engine.inbox.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionHeader("from the controller")
                    Spacer()
                    Button {
                        engine.clearInbox()
                    } label: {
                        Text("dismiss all")
                    }
                    .buttonStyle(.signalGhost)
                }
                signalList(engine.inbox, stroke: Signalwave.green.opacity(0.4)) { inboxRow($0) }
            }
        }
    }

    private func inboxRow(_ item: AUMInboxItem) -> some View {
        HStack(spacing: 10) {
            Button {
                engine.dismissInbox(item)
                if item.path.lowercased().hasSuffix(".aumproj") {
                    Task { await model.openInAUM(relativePath: item.path) }
                } else if let file = engine.deviceFiles.first(where: { $0.relativePath == item.path }) {
                    Task { await model.inspectLocalFile(file, folder: folder) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: item.updated ? "arrow.triangle.2.circlepath.circle" : "sparkle")
                        .foregroundStyle(Signalwave.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.filename)
                            .font(Signalwave.mono(.body))
                            .foregroundStyle(Signalwave.fg)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Text(item.updated
                             ? "updated from controller — tap to reload in aum"
                             : "new from controller — tap to open in aum")
                            .font(Signalwave.mono(.caption2))
                            .foregroundStyle(Signalwave.dim)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                engine.dismissInbox(item)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(Signalwave.dim)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("dismiss \(item.filename)")
        }
        .padding(12)
    }

    // MARK: - File rows

    @ViewBuilder
    private func fileRow(_ file: AUMFolderFile) -> some View {
        let state = engine.state(forPath: file.relativePath)
        let isInspecting = model.inspectingID == file.id

        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    if file.isMidiMap {
                        Task { await model.inspectLocalFile(file, folder: folder) }
                    } else {
                        if let item = engine.inbox.first(where: { $0.path == file.relativePath }) {
                            engine.dismissInbox(item)
                        }
                        Task { await model.openInAUM(relativePath: file.relativePath) }
                    }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(file.name)
                                .font(Signalwave.mono(.body))
                                .foregroundStyle(Signalwave.fg)
                            Text([file.isMidiMap ? "midimap" : "session", byteLabel(file.bytes), dateLabel(file.modified)]
                                .compactMap { $0 }
                                .joined(separator: " · "))
                                .font(Signalwave.mono(.caption))
                                .foregroundStyle(Signalwave.dim)
                            syncBadge(state, path: file.relativePath)
                        }

                        Spacer(minLength: 8)

                        Image(systemName: file.isMidiMap ? "chevron.right" : "play.circle")
                            .font(file.isMidiMap ? .caption : .body)
                            .foregroundStyle(file.isMidiMap ? Signalwave.dim : Signalwave.green)
                            .padding(.top, 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(file.isMidiMap
                    ? "inspect \(file.name)"
                    : "open \(file.name) in aum")

                if isInspecting || state.isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Signalwave.green)
                } else {
                    Menu {
                        Button {
                            Task { await model.inspectLocalFile(file, folder: folder) }
                        } label: {
                            Label("inspect", systemImage: "doc.text.magnifyingglass")
                        }
                        if !file.isMidiMap {
                            Button {
                                Task { await model.openInAUM(relativePath: file.relativePath) }
                            } label: {
                                Label("open in aum", systemImage: "play.circle")
                            }
                        }
                        // No "delete from controller" here: the file exists on
                        // the device, so the next sync cycle would immediately
                        // restore it (v1 deletions don't propagate). The action
                        // lives only on the unlinked fallback list, where no
                        // device copy can resurrect the file.
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(Signalwave.green)
                            .padding(.leading, 4)
                    }
                    .tint(Signalwave.green)
                    .accessibilityLabel("actions for \(file.name)")
                }
            }
            .padding(12)

            if state == .conflict {
                conflictResolver(path: file.relativePath)
            }
        }
    }

    /// The per-row sync badge. `synced` stays silent (the subtle default);
    /// everything else reads as one short console line.
    @ViewBuilder
    private func syncBadge(_ state: AUMFileSyncState, path: String) -> some View {
        switch state {
        case .synced:
            if engine.isInInbox(path: path) {
                badgeLabel("new from controller", icon: "sparkle", color: Signalwave.green)
            }
        case .pushing:
            badgeLabel("pushing…", icon: "arrow.up.circle", color: Signalwave.dim)
        case .pulling:
            badgeLabel("pulling…", icon: "arrow.down.circle", color: Signalwave.dim)
        case .conflict:
            badgeLabel("conflict — both sides changed", icon: "exclamationmark.triangle.fill", color: Signalwave.amber)
        case .error(let why):
            badgeLabel(why, icon: "exclamationmark.triangle.fill", color: Signalwave.amber)
        }
    }

    private func badgeLabel(_ text: String, icon: String, color: Color) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: icon)
        }
        .font(Signalwave.mono(.caption))
        .foregroundStyle(color)
    }

    /// The expanded conflict row: pick which replica survives. No silent
    /// overwrite — this is the only way a conflicted file moves again.
    private func conflictResolver(path: String) -> some View {
        HStack(spacing: 8) {
            Button {
                Task {
                    await engine.resolveConflict(
                        path: path, keepDevice: true,
                        client: receiver.client, folder: folder)
                }
            } label: {
                Label("keep device", systemImage: "ipad")
            }
            .buttonStyle(.signalGhost)

            Button {
                Task {
                    await engine.resolveConflict(
                        path: path, keepDevice: false,
                        client: receiver.client, folder: folder)
                }
            } label: {
                Label("keep controller", systemImage: "desktopcomputer")
            }
            .buttonStyle(.signalGhost(Signalwave.amber))

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    // MARK: - Unlinked state (onboarding + controller fallback)

    private var unlinkedSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("sessions on device")

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
                    Text("// link — remember aum's folder: one browser over every session, kept in sync with the controller automatically.")
                    Text("// open one file — a one-off: inspect a single .aumproj/.aum_midimap, nothing is remembered.")
                }
                .font(Signalwave.mono(.caption2))
                .foregroundStyle(Signalwave.dim)
                .fixedSize(horizontal: false, vertical: true)
            }

            if receiver.isConfigured {
                unlinkedControllerList
            }

            if let message = model.actionMessage {
                consoleLine(message, icon: "exclamationmark.triangle.fill", color: Signalwave.amber)
            }
        }
    }

    /// With no folder linked the app cannot mirror, but the staged files can
    /// still be browsed, inspected, and shared into AUM (share sheet).
    @ViewBuilder
    private var unlinkedControllerList: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("on mcp-midi-controller")

            if engine.controllerEntries.isEmpty {
                Text("// nothing staged yet. link the aum folder above for automatic sync.")
                    .font(Signalwave.mono(.subheadline))
                    .foregroundStyle(Signalwave.dim)
            } else {
                signalList(engine.controllerEntries) { controllerEntryRow($0) }
            }
        }
    }

    @ViewBuilder
    private func controllerEntryRow(_ entry: AUMSessionEntry) -> some View {
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
                        Text([entry.isMidiMap ? "midimap" : "session", byteLabel(entry.bytes), dateLabel(rfc3339: entry.modified)]
                            .compactMap { $0 }
                            .joined(separator: " · "))
                            .font(Signalwave.mono(.caption))
                            .foregroundStyle(Signalwave.dim)
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

            if isInspecting {
                ProgressView()
                    .controlSize(.small)
                    .tint(Signalwave.green)
            } else {
                Menu {
                    Button {
                        Task { await model.share(entry, client: receiver.client) }
                    } label: {
                        Label("share to open in aum", systemImage: "square.and.arrow.up")
                    }
                    Divider()
                    Button(role: .destructive) {
                        Task {
                            await model.deleteFromController(path: entry.path, client: receiver.client)
                            triggerSync()
                        }
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

    // MARK: - Controller footer

    @ViewBuilder
    private var controllerFooter: some View {
        HStack(spacing: 10) {
            if folder.isBound {
                Menu {
                    Button {
                        linkFolder()
                    } label: {
                        Label("relink folder", systemImage: "folder.badge.gearshape")
                    }
                    Button(role: .destructive) {
                        folder.clear()
                        engine.reset()
                        navPath = []
                    } label: {
                        Label("forget folder", systemImage: "xmark")
                    }
                } label: {
                    Label(folder.folderName ?? "aum", systemImage: "folder.fill")
                        .font(Signalwave.mono(.caption))
                        .foregroundStyle(Signalwave.dim)
                        .lineLimit(1)
                }
                .tint(Signalwave.dim)
            }

            Spacer()

            if receiver.isConfigured {
                Text(footerStatusText)
                    .font(Signalwave.mono(.caption))
                    .foregroundStyle(Signalwave.dim)
                    .lineLimit(1)
                    .truncationMode(.head)

                if model.isClearing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Signalwave.amber)
                } else if let staged = engine.stagedCount, staged > 0 {
                    Button {
                        showClearConfirm = true
                    } label: {
                        Label("clear staging", systemImage: "trash")
                    }
                    .buttonStyle(.signalGhost(Signalwave.amber))
                }
            } else {
                Text("waiting for mcp-midi-controller on the lan…")
                    .font(Signalwave.mono(.caption))
                    .foregroundStyle(Signalwave.dim)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .confirmationDialog(
            "Delete all staged sessions from mcp-midi-controller? This does not touch any files on this iPad — and files still on the device sync back on the next cycle.",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear mcp-midi-controller", role: .destructive) {
                Task {
                    await model.clearController(client: receiver.client)
                    triggerSync()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var footerStatusText: String {
        var parts: [String] = []
        if let host = receiver.host {
            parts.append(host)
        }
        if let staged = engine.stagedCount {
            parts.append("\(staged) staged")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Shared bits

    /// The signalwave bordered list: rows separated by hairlines inside one
    /// rounded stroke. Shared by the browser, inbox, and fallback lists.
    private func signalList<Item: Identifiable, Row: View>(
        _ items: [Item],
        stroke: Color = Signalwave.grid,
        @ViewBuilder row: @escaping (Item) -> Row
    ) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Rectangle().fill(Signalwave.grid).frame(height: 1)
                }
                row(item)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(stroke, lineWidth: 1)
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

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private func dateLabel(_ date: Date?) -> String? {
        guard let date = date else { return nil }
        return Self.fileDateFormatter.string(from: date)
    }

    /// Formats the receiver's RFC3339 `modified` string with the same style as
    /// local file dates, so device and controller rows read identically.
    private func dateLabel(rfc3339: String) -> String? {
        guard !rfc3339.isEmpty,
              let date = DaemonClient.rfc3339.date(from: rfc3339) else { return nil }
        return dateLabel(date)
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
