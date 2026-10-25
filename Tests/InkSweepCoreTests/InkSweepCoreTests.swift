import XCTest
@testable import InkSweepCore

/// Records what it was asked to trash instead of touching the real Trash.
final class RecordingTrasher: Trasher, @unchecked Sendable {
    private(set) var trashed: [URL] = []
    func trash(_ url: URL) throws -> URL? {
        trashed.append(url)
        return url
    }
}

final class InkSweepCoreTests: FixtureTestCase {

    func testCachesScannerFindsChildrenWithSize() throws {
        try write(10_000, to: "Library/Caches/com.app.one/blob.bin")
        try write(20_000, to: "Library/Caches/com.app.two/blob.bin")

        let scanner = RuleBasedScanner(category: .userCaches)
        let report = scanner.scan(context: context, knowledgeBase: .seed)

        XCTAssertEqual(report.findings.count, 2)
        XCTAssertGreaterThanOrEqual(report.totalBytes, 30_000)
        XCTAssertTrue(report.findings.allSatisfy { $0.category == .userCaches })
        XCTAssertTrue(report.findings.allSatisfy { !$0.reason.isEmpty })
    }

    func testAbsentRootProducesNoFindingsOrWarnings() {
        let scanner = RuleBasedScanner(category: .userCaches)
        let report = scanner.scan(context: context, knowledgeBase: .seed)
        XCTAssertTrue(report.findings.isEmpty)
        XCTAssertTrue(report.warnings.isEmpty)
    }

    func testSizerDoesNotFollowSymlink() throws {
        // A big file outside the cache, and a cache child that only symlinks to it.
        try write(5_000_000, to: "elsewhere/big.bin")
        let cacheChild = fixture.appendingPathComponent("Library/Caches/com.app.link", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheChild, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: cacheChild.appendingPathComponent("link"),
            withDestinationURL: fixture.appendingPathComponent("elsewhere/big.bin"))

        let size = FileTreeSizer().size(of: cacheChild)
        XCTAssertLessThan(size, 5_000_000, "symlink target must not be counted")
    }

    func testDryRunTouchesNothing() throws {
        try write(10_000, to: "Library/Caches/com.app.one/blob.bin")
        let report = RuleBasedScanner(category: .userCaches).scan(context: context, knowledgeBase: .seed)
        let trasher = RecordingTrasher()
        let receipts = Cleaner(trasher: trasher).clean(report.findings, dryRun: true)

        XCTAssertEqual(trasher.trashed.count, 0)
        XCTAssertTrue(receipts.allSatisfy { $0.outcome == .skippedDryRun })
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.appendingPathComponent("Library/Caches/com.app.one/blob.bin").path))
    }

    func testApplyDelegatesToTrasher() throws {
        try write(10_000, to: "Library/Caches/com.app.one/blob.bin")
        let report = RuleBasedScanner(category: .userCaches).scan(context: context, knowledgeBase: .seed)
        let trasher = RecordingTrasher()
        let receipts = Cleaner(trasher: trasher).clean(report.findings, dryRun: false)

        XCTAssertEqual(trasher.trashed.count, report.findings.count)
        XCTAssertGreaterThan(receipts.reduce(0) { $0 + $1.reclaimedBytes }, 0)
    }

    func testLargeOldFilesThresholdAndAge() throws {
        try write(1_000, to: "Downloads/small-recent.bin")
        try write(200 * 1024 * 1024, to: "Downloads/big-old.bin")
        let oldDate = Date(timeIntervalSinceNow: -60 * 60 * 24 * 200)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: fixture.appendingPathComponent("Downloads/big-old.bin").path)

        let scanner = LargeOldFilesScanner(
            searchRoots: [.home("Downloads")],
            minimumSizeBytes: 100 * 1024 * 1024,
            minimumAge: 60 * 60 * 24 * 90)
        let report = scanner.scan(context: context, knowledgeBase: .seed)

        XCTAssertEqual(report.findings.count, 1)
        XCTAssertEqual(report.findings.first?.url.lastPathComponent, "big-old.bin")
    }

    func testEngineMergesCategories() throws {
        try write(10_000, to: "Library/Caches/com.app.one/blob.bin")
        try write(10_000, to: "Library/Logs/app.log")
        let engine = InkSweepEngine.standard(
            installed: FakeInstalledApps(bundleIDs: [], appNames: []),
            runningBundleIDs: { [] }
        )
        let report = engine.scan(context: context)
        XCTAssertGreaterThan(report.bytes(in: .userCaches), 0)
        XCTAssertGreaterThan(report.bytes(in: .systemLogs), 0)
    }
}
