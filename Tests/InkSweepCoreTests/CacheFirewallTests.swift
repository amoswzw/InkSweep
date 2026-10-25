import XCTest
@testable import InkSweepCore

/// Cache entries that look disposable but are not, cross-checked against
/// protections documented with issue evidence by open-source cleanup tools.
final class CacheFirewallTests: FixtureTestCase {

    private func userCacheNames() -> Set<String> {
        let report = RuleBasedScanner(category: .userCaches, processes: { .empty }).scan(context: context, knowledgeBase: .seed)
        return Set(report.findings.map { rel($0.url) })
    }

    func testAppleCachesAreNeverProposedWhole() throws {
        try write(1_000, to: "Library/Caches/com.apple.homed/db")
        try write(1_000, to: "Library/Caches/com.apple.HomeKit/db")
        try write(1_000, to: "Library/Caches/com.apple.coreaudio/state")

        XCTAssertTrue(userCacheNames().isEmpty)
    }

    // Curated Apple caches are cleaned one level down: the folder Apple's
    // daemon owns (and its ACLs) stays, its contents go.
    func testCuratedAppleCachesAreCleanedByContents() throws {
        try write(1_000, to: "Library/Caches/com.apple.Safari/WebKitCache/blob")
        try write(1_000, to: "Library/Caches/com.apple.Safari/fsCachedData/x")

        XCTAssertEqual(userCacheNames(), [
            "Library/Caches/com.apple.Safari/WebKitCache",
            "Library/Caches/com.apple.Safari/fsCachedData",
        ])
    }

    func testStatefulEntriesWithCacheNamesAreProtected() throws {
        for name in ["ms-playwright", "deno", "GIPPseudonymousID", "CCTClearcutLogger", "FamilyCircle",
                     "Adobe Camera Raw 2", "com.1password.1password", "com.bitwarden.desktop",
                     "com.crowdstrike.falcon.Agent", "com.displaylink.DisplayLinkUserAgent"] {
            try write(1_000, to: "Library/Caches/\(name)/data")
        }
        try write(1_000, to: "Library/Caches/com.vendor.app/blob")

        XCTAssertEqual(userCacheNames(), ["Library/Caches/com.vendor.app"])
    }

    func testDiagnosticReportsFolderStaysItsReportsGo() throws {
        try write(1_000, to: "Library/Logs/DiagnosticReports/App-2026.ips")
        try write(1_000, to: "Library/Logs/SomeApp/run.log")

        let paths = Set(RuleBasedScanner(category: .systemLogs).scan(context: context, knowledgeBase: .seed)
            .findings.map { rel($0.url) })

        XCTAssertEqual(paths, ["Library/Logs/DiagnosticReports/App-2026.ips", "Library/Logs/SomeApp"])
    }
}
