import XCTest
@testable import ProbeKit

final class FileStampTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-stamp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // What a pull does to a file the device already has: replace it atomically,
    // then ask what date it has now. The URL the write went through still
    // answers with the replaced file's date on Apple's Foundation; the stamp
    // must be the new file's.
    func testAReplacedFileHasItsNewDate() throws {
        let dest = dir.appendingPathComponent("Example.aumproj")
        try Data(repeating: 1, count: 1000).write(to: dest, options: .atomic)
        let anHourAgo = Date(timeIntervalSinceNow: -3600)
        try FileManager.default.setAttributes([.modificationDate: anHourAgo], ofItemAtPath: dest.path)

        try Data(repeating: 2, count: 2000).write(to: dest, options: .atomic)

        let stamp = try XCTUnwrap(FileStamp.read(atPath: dest.path))
        XCTAssertEqual(stamp.bytes, 2000)
        let modified = try XCTUnwrap(stamp.modified)
        XCTAssertLessThan(abs(modified.timeIntervalSinceNow), 60, "the date of the file just written")
    }

    func testANewFileHasItsDateAndSize() throws {
        let dest = dir.appendingPathComponent("New.aumproj")
        try Data(repeating: 3, count: 300).write(to: dest, options: .atomic)
        let stamp = try XCTUnwrap(FileStamp.read(atPath: dest.path))
        XCTAssertEqual(stamp.bytes, 300)
        XCTAssertLessThan(abs(try XCTUnwrap(stamp.modified).timeIntervalSinceNow), 60)
    }

    func testAMissingFileHasNoStamp() {
        XCTAssertNil(FileStamp.read(atPath: dir.appendingPathComponent("none.aumproj").path))
    }
}
