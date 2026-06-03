import Foundation
import SwiftUI
import UIKit

// AUMFolderBookmark gives the sessions ferry direct, repeated access to AUM's
// own folder (e.g. "On My iPad/AUM"). The user picks the folder once with a
// .fileImporter([.folder]); we persist a security-scoped bookmark in
// UserDefaults and resolve it on demand. With the folder bound the app can:
//   - enumerate the *.aumproj / *.aum_midimap files already in AUM and upload
//     them with one tap (no per-file picker), and
//   - write daemon-generated files straight back into AUM (no per-file save
//     dialog).
// When no folder is bound, write-back falls back to the share sheet
// (UIActivityViewController → "Open in AUM" / "Save to Files…", see ShareSheet).
//
// iOS has no entitlement that grants blanket access to another app's documents,
// so the user-driven folder pick + bookmark is the only sanctioned path. The
// bookmark is stored on-device only; nothing here (paths, filenames) is ever
// logged or committed (public-repo / privacy rule).

/// One AUM file discovered inside the bound folder.
struct AUMFolderFile: Identifiable, Equatable {
    let url: URL
    let name: String
    let bytes: Int

    var id: String { url.path }
    var isMidiMap: Bool { name.lowercased().hasSuffix(".aum_midimap") }
}

enum AUMFolderError: LocalizedError {
    case noFolder
    case stale
    case accessDenied
    case resolveFailed(String)

    var errorDescription: String? {
        switch self {
        case .noFolder:
            return "no aum folder linked yet"
        case .stale:
            return "the linked aum folder moved — link it again"
        case .accessDenied:
            return "could not open the linked aum folder — link it again"
        case .resolveFailed(let why):
            return "could not open the linked aum folder: \(why)"
        }
    }
}

@MainActor
final class AUMFolderBookmark: ObservableObject {
    private static let key = "aumFolderBookmark"

    /// The bound folder's display name (last path component), or nil when no
    /// folder has been linked. Published so the UI can react to (un)linking.
    @Published private(set) var folderName: String?

    /// True once a usable folder bookmark is stored.
    var isBound: Bool { folderName != nil }

    init() {
        // Best-effort resolve at launch just to show the folder name; access is
        // re-acquired per operation in `withFolder`.
        if let url = try? resolve() {
            folderName = url.lastPathComponent
        }
    }

    // MARK: - Linking

    /// Resolve a `.fileImporter([.folder])` result and persist its bookmark.
    /// Silently ignores user cancellation.
    func handlePick(_ result: Result<[URL], Error>) throws {
        switch result {
        case .failure(let error):
            if (error as NSError).code == NSUserCancelledError { return }
            throw error
        case .success(let urls):
            guard let url = urls.first else { return }
            try bind(url)
        }
    }

    /// Persist a security-scoped bookmark to `url` (a picked folder).
    func bind(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(data, forKey: Self.key)
        folderName = url.lastPathComponent
    }

    /// Forget the linked folder.
    func clear() {
        UserDefaults.standard.removeObject(forKey: Self.key)
        folderName = nil
    }

    // MARK: - Enumerate / read / write

    /// List the `.aumproj` / `.aum_midimap` files in the bound folder, sorted by
    /// name. Throws `AUMFolderError` when nothing is linked or access fails.
    func listFiles() throws -> [AUMFolderFile] {
        try withFolder { folder in
            let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
            let contents = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )
            return contents.compactMap { url -> AUMFolderFile? in
                let ext = url.pathExtension.lowercased()
                guard ext == "aumproj" || ext == "aum_midimap" else { return nil }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return AUMFolderFile(url: url, name: url.lastPathComponent, bytes: size)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    /// Read a file enumerated from the bound folder (verbatim bytes).
    func read(_ file: AUMFolderFile) throws -> Data {
        try withFolder { _ in try Data(contentsOf: file.url) }
    }

    /// Write `data` into the bound folder under `filename`, overwriting any
    /// existing file. Returns the destination URL.
    @discardableResult
    func write(data: Data, filename: String) throws -> URL {
        try withFolder { folder in
            let dest = folder.appendingPathComponent(filename)
            try data.write(to: dest, options: .atomic)
            return dest
        }
    }

    // MARK: - Bookmark plumbing

    /// Resolve the stored bookmark, refreshing it transparently when iOS marks
    /// it stale. Throws `AUMFolderError` when nothing is stored.
    private func resolve() throws -> URL {
        guard let data = UserDefaults.standard.data(forKey: Self.key) else {
            throw AUMFolderError.noFolder
        }
        var stale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        } catch {
            throw AUMFolderError.resolveFailed(error.localizedDescription)
        }
        if stale {
            // Re-bake the bookmark so it keeps working next launch.
            if url.startAccessingSecurityScopedResource() {
                defer { url.stopAccessingSecurityScopedResource() }
                if let fresh = try? url.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    UserDefaults.standard.set(fresh, forKey: Self.key)
                }
            } else {
                throw AUMFolderError.stale
            }
        }
        return url
    }

    /// Resolve the folder and run `body` while holding its security scope.
    private func withFolder<T>(_ body: (URL) throws -> T) throws -> T {
        let url = try resolve()
        guard url.startAccessingSecurityScopedResource() else {
            throw AUMFolderError.accessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return try body(url)
    }
}

// MARK: - Share sheet

/// A SwiftUI wrapper over `UIActivityViewController`, the write-back fallback
/// when no AUM folder is linked. Sharing a file URL surfaces both "Open in AUM"
/// (routing the `.aumproj` straight into the host) and the system "Save to
/// Files…" activity, so it subsumes a bespoke file exporter.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var onComplete: ((Bool) -> Void)?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            onComplete?(completed)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
