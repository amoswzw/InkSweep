import XCTest
@testable import InkSweepCore

final class DuplicateFileTests: FixtureTestCase {

    /// Writes specific bytes, creating intermediate directories.
    private func put(_ data: Data, _ rel: String) throws {
        let url = fixture.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func testIdenticalFilesGroupWithWastedBytes() throws {
        let payload = Data((0..<1_500_000).map { UInt8($0 % 251) })
        try put(payload, "Downloads/a/movie-part.bin")
        try put(payload, "Documents/copies/movie-part.bin")

        let groups = DuplicateFileScanner(
            roots: [.home("Downloads"), .home("Documents")],
            minimumSizeBytes: 1_000_000
        ).scan(context: context)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].files.count, 2)
        XCTAssertEqual(groups[0].wastedBytes, Int64(payload.count))
    }

    func testSameSizeDifferentContentIsNotAGroup() throws {
        try put(Data(repeating: 0x41, count: 1_500_000), "Downloads/a.bin")
        try put(Data(repeating: 0x42, count: 1_500_000), "Downloads/b.bin")

        let groups = DuplicateFileScanner(
            roots: [.home("Downloads")], minimumSizeBytes: 1_000_000
        ).scan(context: context)
        XCTAssertTrue(groups.isEmpty, "equal size with different bytes must not group")
    }

    func testBelowThresholdIsIgnored() throws {
        try put(Data(repeating: 7, count: 500_000), "Downloads/small-a.bin")
        try put(Data(repeating: 7, count: 500_000), "Downloads/small-b.bin")

        let groups = DuplicateFileScanner(
            roots: [.home("Downloads")], minimumSizeBytes: 1_000_000
        ).scan(context: context)
        XCTAssertTrue(groups.isEmpty)
    }

    func testPrefixCollisionStillRequiresFullHashMatch() throws {
        // Same 64-KB prefix, different tail — must NOT group.
        let prefix = Data(repeating: 9, count: 65_536)
        var a = prefix; a.append(Data(repeating: 1, count: 500_000))
        var b = prefix; b.append(Data(repeating: 2, count: 500_000))
        try put(a, "Downloads/pre-a.bin")
        try put(b, "Downloads/pre-b.bin")

        let groups = DuplicateFileScanner(
            roots: [.home("Downloads")], minimumSizeBytes: 1_000_000
        ).scan(context: context)
        XCTAssertTrue(groups.isEmpty, "identical 64-KB prefix with different tails must not group")
    }

    func testThreeCopiesWasteTwice() throws {
        let payload = Data(repeating: 3, count: 1_200_000)
        try put(payload, "Downloads/one.bin")
        try put(payload, "Downloads/two.bin")
        try put(payload, "Downloads/three.bin")

        let groups = DuplicateFileScanner(
            roots: [.home("Downloads")], minimumSizeBytes: 1_000_000
        ).scan(context: context)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].files.count, 3)
        XCTAssertEqual(groups[0].wastedBytes, 2 * 1_200_000)
    }
}

final class DuplicateHardLinkTests: FixtureTestCase {
    // Two names for one inode: deleting either frees nothing.
    func testHardLinksAreNotDuplicates() throws {
        try write(1_500_000, to: "Downloads/a.bin")
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent("Documents"),
                                                withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: fixture.appendingPathComponent("Downloads/a.bin"),
                                         to: fixture.appendingPathComponent("Documents/a.bin"))

        let groups = DuplicateFileScanner(roots: [.home("Downloads"), .home("Documents")],
                                          minimumSizeBytes: 1_000_000).scan(context: context)

        XCTAssertTrue(groups.isEmpty)
    }
}
