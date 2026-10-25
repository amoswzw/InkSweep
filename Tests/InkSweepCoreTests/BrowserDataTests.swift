import XCTest
@testable import InkSweepCore

final class BrowserDataTests: FixtureTestCase {

    private func scanner(
        installed: FakeInstalledApps, running: Set<String> = []
    ) -> BrowserDataScanner {
        BrowserDataScanner(installed: installed, runningBundleIDs: { running })
    }

    func testChromeProfileFiles() throws {
        try write(4_000, to: "Library/Application Support/Google/Chrome/Default/History")
        try write(4_000, to: "Library/Application Support/Google/Chrome/Default/Cookies")
        try write(4_000, to: "Library/Application Support/Google/Chrome/Default/Network/Cookies")
        try write(4_000, to: "Library/Application Support/Google/Chrome/Profile 1/History")

        let report = scanner(installed: FakeInstalledApps(
            bundleIDs: ["com.google.Chrome"], appNames: ["google chrome"]
        )).scan(context: context, knowledgeBase: .seed)

        XCTAssertEqual(report.findings.count, 4)
        XCTAssertTrue(report.findings.allSatisfy { $0.category == .browserData })
        XCTAssertTrue(report.findings.contains { $0.reason.contains("(profile Profile 1)") })
    }

    func testRunningBrowserIsSkippedWithWarning() throws {
        try write(4_000, to: "Library/Application Support/Google/Chrome/Default/History")

        let report = scanner(
            installed: FakeInstalledApps(bundleIDs: ["com.google.Chrome"], appNames: ["google chrome"]),
            running: ["com.google.Chrome"]
        ).scan(context: context, knowledgeBase: .seed)

        XCTAssertTrue(report.findings.isEmpty)
        XCTAssertEqual(report.warnings.count, 1)
        XCTAssertTrue(report.warnings[0].contains("Chrome"))
    }

    func testFirefoxCookiesOnly() throws {
        try write(4_000, to: "Library/Application Support/Firefox/Profiles/abc.default-release/cookies.sqlite")
        try write(4_000, to: "Library/Application Support/Firefox/Profiles/abc.default-release/places.sqlite")

        let report = scanner(installed: FakeInstalledApps(
            bundleIDs: ["org.mozilla.firefox"], appNames: ["firefox"]
        )).scan(context: context, knowledgeBase: .seed)

        XCTAssertEqual(report.findings.count, 1)
        XCTAssertEqual(report.findings[0].url.lastPathComponent, "cookies.sqlite")
        XCTAssertFalse(
            report.findings.contains { $0.url.lastPathComponent == "places.sqlite" },
            "places.sqlite holds bookmarks — must never be proposed"
        )
    }

    func testSafariStandaloneFiles() throws {
        try write(4_000, to: "Library/Safari/History.db")
        try write(4_000, to: "Library/Safari/Downloads.plist")
        try write(4_000, to: "Library/Safari/Cookies/Cookies.binarycookies")

        let report = scanner(installed: FakeInstalledApps(
            bundleIDs: ["com.apple.Safari"], appNames: ["safari"]
        )).scan(context: context, knowledgeBase: .seed)

        XCTAssertEqual(report.findings.count, 3)
        XCTAssertTrue(report.findings.allSatisfy { $0.ruleID == "browser-com.apple.Safari" })
    }

    func testUninstalledBrowserIsSkipped() throws {
        // Chrome's files exist, but Chrome is not installed: that tree is the
        // leftover scanner's business, not privacy cleaning.
        try write(4_000, to: "Library/Application Support/Google/Chrome/Default/History")

        let report = scanner(
            installed: FakeInstalledApps(bundleIDs: [], appNames: [])
        ).scan(context: context, knowledgeBase: .seed)

        XCTAssertTrue(report.findings.isEmpty)
        XCTAssertTrue(report.warnings.isEmpty)
    }

    func testChromiumGuestAndSystemProfilesAreIgnored() throws {
        try write(4_000, to: "Library/Application Support/Google/Chrome/Guest Profile/History")
        try write(4_000, to: "Library/Application Support/Google/Chrome/System Profile/History")

        let report = scanner(installed: FakeInstalledApps(
            bundleIDs: ["com.google.Chrome"], appNames: ["google chrome"]
        )).scan(context: context, knowledgeBase: .seed)

        XCTAssertTrue(report.findings.isEmpty)
    }
}

final class BrowserSidecarTests: FixtureTestCase {
    // Removing a SQLite database but leaving its journal/WAL behind leaves
    // the browser a stale log for a database that no longer matches.
    func testSQLiteSidecarsTravelWithTheirDatabase() throws {
        try write(4_000, to: "Library/Application Support/Google/Chrome/Default/History")
        try write(4_000, to: "Library/Application Support/Google/Chrome/Default/History-journal")
        try write(4_000, to: "Library/Application Support/Google/Chrome/Default/Cookies-wal")

        let names = BrowserDataScanner(
            installed: FakeInstalledApps(bundleIDs: ["com.google.Chrome"], appNames: []),
            runningBundleIDs: { [] }
        ).scan(context: context, knowledgeBase: .seed).findings.map(\.url.lastPathComponent)

        XCTAssertEqual(Set(names), ["History", "History-journal"])
    }
}
