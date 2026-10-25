import XCTest
@testable import InkSweepCore

final class ShredderTests: FixtureTestCase {

    func testDryRunTouchesNothing() throws {
        try write(50_000, to: "docs/target.bin")
        let url = fixture.appendingPathComponent("docs/target.bin")
        let receipts = Shredder().shred([url], dryRun: true)
        XCTAssertTrue(receipts.allSatisfy { $0.outcome == .skippedDryRun })
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testShredsFileCompletely() throws {
        try write(50_000, to: "docs/target.bin")
        let url = fixture.appendingPathComponent("docs/target.bin")
        let receipts = Shredder().shred([url], dryRun: false)
        XCTAssertEqual(receipts.first?.outcome, .shredded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testShredsDirectoryBottomUp() throws {
        try write(10_000, to: "dir/sub/a.bin")
        try write(10_000, to: "dir/sub/b.bin")
        try write(10_000, to: "dir/top.bin")
        let url = fixture.appendingPathComponent("dir")
        _ = Shredder().shred([url], dryRun: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.appendingPathComponent("dir/sub/a.bin").path))
    }

    func testSymlinkIsUnlinkedButTargetSurvives() throws {
        try write(10_000, to: "precious/data.bin")
        let link = fixture.appendingPathComponent("link-to-precious")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: fixture.appendingPathComponent("precious/data.bin"))
        _ = Shredder().shred([link], dryRun: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.appendingPathComponent("precious/data.bin").path),
            "shredding a symlink must never destroy its target")
    }

    func testMissingPathReportsFailure() {
        let url = fixture.appendingPathComponent("nope.bin")
        let receipts = Shredder().shred([url], dryRun: false)
        if case .failed = receipts[0].outcome {} else {
            XCTFail("expected failure for missing path")
        }
    }
}

final class ShredderGuardTests: FixtureTestCase {

    // Overwriting a hard-linked file destroys the other path's contents too.
    func testRefusesHardLinkedFile() throws {
        try write(50_000, to: "docs/target.bin")
        let url = fixture.appendingPathComponent("docs/target.bin")
        let other = fixture.appendingPathComponent("elsewhere.bin")
        try FileManager.default.linkItem(at: url, to: other)
        let before = try Data(contentsOf: other)

        let receipts = Shredder().shred([url], dryRun: false)

        guard case .failed = receipts.first?.outcome else { return XCTFail("hard link was shredded") }
        XCTAssertEqual(try Data(contentsOf: other), before)
    }

    func testRefusesHomeAndItsAncestors() throws {
        let home = fixture.appendingPathComponent("Users/me", isDirectory: true)
        try write(1_000, to: "Users/me/notes.txt")
        let shredder = Shredder(protectedDirectories: [home])

        let receipts = shredder.shred([home, fixture.appendingPathComponent("Users"), URL(fileURLWithPath: "/")],
                                      dryRun: false)

        XCTAssertTrue(receipts.allSatisfy { if case .failed = $0.outcome { return true } else { return false } })
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("notes.txt").path))
    }
}
