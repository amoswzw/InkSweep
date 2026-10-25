import XCTest
@testable import InkSweepCore

final class EngineBehaviorTests: FixtureTestCase {

    struct StubScanner: InkSweepCore.Scanner {
        let category: JunkCategory
        let urls: [URL]
        func scan(context: ScanContext, knowledgeBase: KnowledgeBase) -> ScanReport {
            ScanReport(findings: urls.map {
                Finding(url: $0, category: category, sizeBytes: 16, ruleID: "stub", reason: "stub")
            })
        }
    }

    func testEngineDeduplicatesByPath() {
        let dup = fixture.appendingPathComponent("Library/Caches/dup", isDirectory: true)
        let engine = InkSweepEngine(
            scanners: [
                StubScanner(category: .userCaches, urls: [dup]),
                StubScanner(category: .appLeftovers, urls: [dup]),
            ],
            knowledgeBase: .seed
        )
        let report = engine.scan(context: context)
        XCTAssertEqual(report.findings.count, 1, "two scanners must not double-count one path")
    }

    func testScanReportJSONRoundTrip() throws {
        let finding = Finding(
            url: fixture.appendingPathComponent("Library/Caches/com.app/blob.bin"),
            category: .userCaches,
            sizeBytes: 123,
            ruleID: "user-caches",
            reason: "test",
            reversible: true,
            lastModified: Date(timeIntervalSince1970: 100)
        )
        let report = ScanReport(findings: [finding], warnings: ["w"])

        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(ScanReport.self, from: data)

        XCTAssertEqual(decoded.findings, report.findings)
        XCTAssertEqual(decoded.warnings, report.warnings)
    }

    func testSeedKnowledgeBaseGrew() {
        XCTAssertEqual(KnowledgeBase.seed.version, 4)
        XCTAssertTrue(KnowledgeBase.seed.rules.contains { $0.id == "watchos-device-support" })
        XCTAssertTrue(KnowledgeBase.seed.rules.contains { $0.id == "visionos-device-support" })
        XCTAssertTrue(KnowledgeBase.seed.rules.contains { $0.id == "simulator-caches" })
        // Precious developer data must NOT be in the seed as junk:
        XCTAssertFalse(KnowledgeBase.seed.rules.contains { $0.id == "xcode-archives" })
    }
}
