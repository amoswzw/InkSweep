import XCTest
@testable import InkSweepCore

final class RuleEngineExtensionTests: FixtureTestCase {

    private func scan(_ category: JunkCategory, running: ProcessSnapshot = .empty) -> ScanReport {
        RuleBasedScanner(category: category, processes: { running }).scan(context: context, knowledgeBase: .seed)
    }

    func testPatternRootsExpandPerComponent() throws {
        try write(1_000, to: "Library/Developer/CoreSimulator/Devices/AAAA/data/tmp/a.tmp")
        try write(1_000, to: "Library/Developer/CoreSimulator/Devices/BBBB/data/tmp/b.tmp")
        try write(1_000, to: "Library/Developer/CoreSimulator/Devices/BBBB/data/Documents/keep.db")

        let paths = Set(scan(.developerJunk).findings.map { rel($0.url) })

        XCTAssertTrue(paths.isSuperset(of: ["Library/Developer/CoreSimulator/Devices/AAAA/data/tmp/a.tmp",
                                             "Library/Developer/CoreSimulator/Devices/BBBB/data/tmp/b.tmp"]))
        XCTAssertFalse(paths.contains { $0.contains("Documents") }, "device data is not tmp")
    }

    func testPatternsNeverFollowSymlinksOrMatchDotEntries() throws {
        try write(1_000, to: "elsewhere/data/tmp/precious.db")
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent("Library/Developer/CoreSimulator/Devices"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.appendingPathComponent("Library/Developer/CoreSimulator/Devices/LINK"),
            withDestinationURL: fixture.appendingPathComponent("elsewhere"))
        try write(1_000, to: "Library/Developer/CoreSimulator/Devices/.hidden/data/tmp/x")

        XCTAssertTrue(scan(.developerJunk).findings.isEmpty)
    }

    func testGlobbedGradleBuildCaches() throws {
        try write(1_000, to: ".gradle/caches/build-cache-1/entry")
        try write(1_000, to: ".gradle/caches/modules-2/files-2.1/dep.jar")

        let paths = Set(scan(.developerJunk).findings.map { rel($0.url) })

        XCTAssertEqual(paths, [".gradle/caches/build-cache-1/entry"], "dependency cache (modules-2) stays")
    }

    func testRunningOwnerSkipsTheRuleWithAWarning() throws {
        try write(1_000, to: ".cargo/registry/cache/index.crates.io-1/serde.crate")

        let report = scan(.developerJunk, running: ProcessSnapshot(executableNames: ["cargo"], bundleIDs: []))

        XCTAssertTrue(report.findings.isEmpty)
        XCTAssertTrue(report.warnings.contains { $0.contains("cargo is running") })
        XCTAssertEqual(scan(.developerJunk).findings.count, 1)
    }

    func testBundleIDOwnerPrefixPattern() throws {
        try write(1_000, to: "Library/Application Support/Adobe/Common/Media Cache Files/clip.cfa")
        let running = ProcessSnapshot(executableNames: [], bundleIDs: ["com.adobe.PremierePro.25"])

        XCTAssertTrue(scan(.userCaches, running: running).findings.isEmpty)
        XCTAssertEqual(scan(.userCaches).findings.count, 1)
    }

    func testAbsentOwnedRuleDoesNotWarn() {
        let report = scan(.developerJunk, running: ProcessSnapshot(executableNames: ["cargo", "java"], bundleIDs: []))
        XCTAssertTrue(report.warnings.isEmpty, "nothing to skip when the cache does not exist")
    }
}

final class KnowledgeBaseInvariantTests: XCTestCase {
    // R3: every rule is auditable — unique id, a source and a regeneration note.
    func testEveryRuleHasUniqueIDAndProvenance() {
        let rules = KnowledgeBase.seed.rules
        XCTAssertEqual(Set(rules.map(\.id)).count, rules.count, "duplicate rule ids")
        for rule in rules {
            XCTAssertFalse(rule.provenance.source.isEmpty, rule.id)
            XCTAssertFalse(rule.provenance.note.isEmpty, rule.id)
        }
    }
}
