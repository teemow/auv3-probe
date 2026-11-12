import Foundation

/// A file's size and modification date as the file system has them now.
public struct FileStamp: Equatable {
    public var bytes: Int
    public var modified: Date?

    public init(bytes: Int, modified: Date?) {
        self.bytes = bytes
        self.modified = modified
    }

    /// Read the stamp of the file at `path`, nil when there is none.
    ///
    /// It asks the file system by path, never a `URL`'s resource values: a
    /// `URL` caches them, and `Data.write(to:options: .atomic)` over an
    /// existing file leaves the replaced file's values in the cache of the URL
    /// it wrote through. Asked right after the write, that URL answers with
    /// the old file's date. The session sync recorded that date for every file
    /// a pull replaced and so took the file for changed in the next cycle.
    public static func read(atPath path: String) -> FileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        return FileStamp(bytes: size, modified: attributes[.modificationDate] as? Date)
    }
}
