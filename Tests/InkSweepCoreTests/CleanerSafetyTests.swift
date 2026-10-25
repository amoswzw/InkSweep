import XCTest
@testable import InkSweepCore

final class CleanerSafetyTests: FixtureTestCase {

    private func finding(_ relativePath: String, category: JunkCategory = .userCaches,
                         reversible: Bool = true) -> Finding {
        Finding(url: fixture.appendingPathComponent(relativePath), category: category,
                sizeBytes: 10_000, ruleID: "test", reason: "test", reversible: reversible)
    }

    // Analysis-only findings point at whole app bundles (lipo, .lproj): the
    // Cleaner itself must refuse them, whatever the caller forgot to filter.
    func testCleanerRefusesAnalysisOnlyFindings() throws {
        try write(10_000, to: "Applications/Big.app/Contents/MacOS/Big")
        let trasher = RecordingTrasher()
        let receipts = Cleaner(trasher: trasher).clean(
            [finding("Applications/Big.app", category: .systemJunk, reversible: false)], dryRun: false)

        XCTAssertTrue(trasher.trashed.isEmpty)
        guard case .failed = receipts.first?.outcome else {
            return XCTFail("expected refusal, got \(String(describing: receipts.first?.outcome))")
        }
        XCTAssertEqual(receipts.first?.reclaimedBytes, 0)
    }

    // Moving Trash contents to the Trash reclaims nothing; reporting it as
    // reclaimed would be a lie.
    func testCleanerRefusesItemsAlreadyInTrash() throws {
        try write(10_000, to: ".Trash/old.bin")
        let trasher = RecordingTrasher()
        let receipts = Cleaner(trasher: trasher).clean([finding(".Trash/old.bin", category: .trash)], dryRun: false)

        XCTAssertTrue(trasher.trashed.isEmpty)
        XCTAssertEqual(receipts.first?.reclaimedBytes, 0)
    }

    func testTrashEmptierDeletesDirectTrashChildrenOnly() throws {
        try write(10_000, to: ".Trash/old.bin")
        try write(10_000, to: "Library/Caches/com.app.one/blob.bin")
        let emptier = TrashEmptier(trashDirectory: fixture.appendingPathComponent(".Trash"))

        let receipts = emptier.empty([
            finding(".Trash/old.bin", category: .trash),
            finding("Library/Caches/com.app.one", category: .trash),
        ], dryRun: false)

        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: fixture.appendingPathComponent(".Trash/old.bin").path))
        XCTAssertTrue(fm.fileExists(atPath: fixture.appendingPathComponent("Library/Caches/com.app.one").path),
                      "an item outside the Trash must never be deleted by the emptier")
        XCTAssertEqual(receipts[0].outcome, .deleted)
        XCTAssertEqual(receipts[0].reclaimedBytes, 10_000)
        guard case .failed = receipts[1].outcome else { return XCTFail("outside-Trash item not refused") }
    }

    func testTrashEmptierDryRunTouchesNothing() throws {
        try write(10_000, to: ".Trash/old.bin")
        let emptier = TrashEmptier(trashDirectory: fixture.appendingPathComponent(".Trash"))
        let receipts = emptier.empty([finding(".Trash/old.bin", category: .trash)])

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.appendingPathComponent(".Trash/old.bin").path))
        XCTAssertEqual(receipts.first?.outcome, .skippedDryRun)
    }

    func testTrashEmptierRemovesSymlinkNotItsTarget() throws {
        try write(10_000, to: "Documents/precious.txt")
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent(".Trash"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.appendingPathComponent(".Trash/link"),
            withDestinationURL: fixture.appendingPathComponent("Documents"))
        let emptier = TrashEmptier(trashDirectory: fixture.appendingPathComponent(".Trash"))

        _ = emptier.empty([finding(".Trash/link", category: .trash)], dryRun: false)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("Documents/precious.txt").path))
    }
}
