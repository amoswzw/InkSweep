import XCTest
@testable import InkSweepCore

final class AppLeftoversTests: FixtureTestCase {

    private func scanner(_ installed: FakeInstalledApps) -> AppLeftoversScanner {
        AppLeftoversScanner(installed: installed)
    }

    func testFlagsOrphanContainerAndProtectsInstalledAndApple() throws {
        try write(1_000, to: "Library/Containers/com.orphan.app/data/db")
        try write(1_000, to: "Library/Containers/com.example.installed/data/db")
        try write(1_000, to: "Library/Containers/com.apple.system.app/data/db")

        let report = scanner(FakeInstalledApps(
            bundleIDs: ["com.example.installed"], appNames: ["installed app"]
        )).scan(context: context, knowledgeBase: .seed)

        XCTAssertEqual(report.findings.count, 1)
        XCTAssertTrue(report.findings[0].url.path.contains("com.orphan.app"))
        XCTAssertEqual(report.findings[0].category, .appLeftovers)
    }

    func testTeamOfInstalledVendorIsProtected() throws {
        try write(1_000, to: "Library/Containers/com.vendor.helper/data")
        try write(1_000, to: "Library/Preferences/com.vendor.tool.plist")
        try write(1_000, to: "Library/Preferences/com.other.thing.plist")

        let report = scanner(FakeInstalledApps(
            bundleIDs: ["com.vendor.app"], appNames: ["vendor"]
        )).scan(context: context, knowledgeBase: .seed)

        XCTAssertEqual(report.findings.count, 1)
        XCTAssertTrue(report.findings[0].url.path.contains("com.other.thing.plist"))
    }

    func testSuffixedLeftoverRoots() throws {
        try write(500, to: "Library/Saved Application State/com.orphan.app.savedState/windows.data")
        try write(500, to: "Library/Cookies/com.orphan.app.binarycookies")
        try write(500, to: "Library/HTTPStorages/com.orphan.app/cache.db")

        let report = scanner(FakeInstalledApps(bundleIDs: [], appNames: []))
            .scan(context: context, knowledgeBase: .seed)

        XCTAssertEqual(report.findings.count, 3)
        XCTAssertTrue(report.findings.allSatisfy { $0.ruleID == "app-leftover" })
    }

    func testGroupContainers() throws {
        try write(500, to: "Library/Group Containers/group.com.orphan.app/data")
        try write(500, to: "Library/Group Containers/group.com.apple.shared/data")
        try write(500, to: "Library/Group Containers/group.com.vendor.shared/data")

        let report = scanner(FakeInstalledApps(
            bundleIDs: ["com.vendor.app"], appNames: []
        )).scan(context: context, knowledgeBase: .seed)

        XCTAssertEqual(report.findings.count, 1)
        XCTAssertTrue(report.findings[0].url.path.contains("group.com.orphan.app"))
    }

    func testApplicationSupportVendorSplit() throws {
        try write(500, to: "Library/Application Support/Google/Chrome/Default/History")
        try write(500, to: "Library/Application Support/OldApp/data.db")

        let withChrome = scanner(FakeInstalledApps(
            bundleIDs: ["com.google.Chrome"], appNames: ["google chrome"]
        )).scan(context: context, knowledgeBase: .seed)
        // Chrome installed: only the unrelated OldApp is leftover.
        XCTAssertEqual(withChrome.findings.count, 1)
        XCTAssertTrue(withChrome.findings[0].url.path.contains("OldApp"))

        let noChrome = scanner(FakeInstalledApps(bundleIDs: [], appNames: []))
            .scan(context: context, knowledgeBase: .seed)
        // Chrome gone and nothing else claims the tree: the whole "Google"
        // directory is one vendor's leftover, flagged as a single finding
        // (never the Chrome subdirectory separately — no double counting).
        XCTAssertEqual(noChrome.findings.count, 2)
        XCTAssertTrue(noChrome.findings.contains { $0.url.path.hasSuffix("/Google") })
        XCTAssertFalse(noChrome.findings.contains { $0.url.path.hasSuffix("/Google/Chrome") })
    }

    func testUnclaimedTreeWithSubdirsIsFlaggedAsWhole() throws {
        // Real case: Vivaldi uninstalled — flag the whole browser directory,
        // not just one subdirectory of it.
        try write(500, to: "Library/Application Support/Vivaldi/NativeMessagingHosts/host.json")
        try write(500, to: "Library/Application Support/Vivaldi/Default/Preferences")

        let report = scanner(FakeInstalledApps(bundleIDs: [], appNames: []))
            .scan(context: context, knowledgeBase: .seed)

        XCTAssertEqual(report.findings.count, 1)
        XCTAssertTrue(report.findings[0].url.path.hasSuffix("/Vivaldi"))
    }

    func testProtectedSubdirectoryBesideLiveAppIsNotFlagged() throws {
        // Real case: Firefox installed — "Mozilla/NativeMessagingHosts" holds
        // browser↔extension bridges (1Password & co.) and must never be flagged.
        try write(500, to: "Library/Application Support/Mozilla/Firefox/profile/x")
        try write(500, to: "Library/Application Support/Mozilla/NativeMessagingHosts/host.json")

        let report = scanner(FakeInstalledApps(
            bundleIDs: ["org.mozilla.firefox"], appNames: ["firefox"]
        )).scan(context: context, knowledgeBase: .seed)

        XCTAssertTrue(report.findings.isEmpty)
    }

    func testUUIDStampedIdentifiersAreDebrisNotLeftovers() throws {
        // Real case: XCTest writes "HushloomTests.<UUID>.plist" per test run.
        // The app is installed; these are test debris (developerJunk), not
        // app leftovers.
        try write(500, to: "Library/Preferences/HushloomTests.D867F17F-7199-418A-A2EF-C17A53F560C7.plist")

        let leftovers = scanner(FakeInstalledApps(bundleIDs: [], appNames: []))
            .scan(context: context, knowledgeBase: .seed)
        XCTAssertTrue(leftovers.findings.isEmpty)

        let debris = TestDebrisScanner().scan(context: context, knowledgeBase: .seed)
        XCTAssertEqual(debris.findings.count, 1)
        XCTAssertEqual(debris.findings[0].category, .developerJunk)
        XCTAssertEqual(debris.findings[0].ruleID, "test-debris")
    }

    func testCriticalNamesAreNeverFlagged() throws {
        try write(9_999, to: "Library/Application Support/MobileSync/Backup/phone.backup")
        try write(9_999, to: "Library/Application Support/AddressBook/contacts.db")
        try write(9_999, to: "Library/Application Support/CloudDocs/document.pdf")

        let report = scanner(FakeInstalledApps(bundleIDs: [], appNames: []))
            .scan(context: context, knowledgeBase: .seed)

        XCTAssertTrue(report.findings.isEmpty, "critical user-data locations must never be proposed")
    }

    func testNonIdentifierEntriesAreIgnored() throws {
        // Files/entries that are not bundle-id-shaped are out of scope for the
        // identifier matchers — conservative by construction.
        try write(500, to: "Library/Preferences/Macromedia/Flash Player/prefs.sol")
        try write(500, to: "Library/Preferences/GlobalPreferences.plist")

        let report = scanner(FakeInstalledApps(bundleIDs: [], appNames: []))
            .scan(context: context, knowledgeBase: .seed)

        XCTAssertTrue(report.findings.isEmpty)
    }

    func testUnreadableRootsAreSkippedSilently() {
        let report = scanner(FakeInstalledApps(bundleIDs: [], appNames: []))
            .scan(context: context, knowledgeBase: .seed)
        XCTAssertTrue(report.findings.isEmpty)
        XCTAssertTrue(report.warnings.isEmpty)
    }

    // MARK: False-positive classes observed on a real machine (2026-10-25)

    func testBundleIDMatchingIsCaseInsensitive() throws {
        // Real case: installed app id "cx.c3.TheUnarchiver", container "cx.c3.theunarchiver".
        try write(1_000, to: "Library/Containers/cx.c3.theunarchiver/data/db")
        let report = scanner(FakeInstalledApps(
            bundleIDs: ["cx.c3.TheUnarchiver"], appNames: []
        )).scan(context: context, knowledgeBase: .seed)
        XCTAssertTrue(report.findings.isEmpty)
    }

    func testHelperProcessesAreProtected() throws {
        // Real case: 1Password's "2BUA8C4S2C.com.1password.browser-helper" —
        // its ID never appears as an installed .app bundle ID.
        try write(1_000, to: "Library/Containers/2BUA8C4S2C.com.1password.browser-helper/data")
        let report = scanner(FakeInstalledApps(bundleIDs: [], appNames: []))
            .scan(context: context, knowledgeBase: .seed)
        XCTAssertTrue(report.findings.isEmpty)
    }

    func testApplicationSupportPrefixNameMatch() throws {
        // Real case: "Hopper" data dir, installed app named "Hopper Disassembler".
        try write(1_000, to: "Library/Application Support/Hopper/Scripts/x.swift")
        let report = scanner(FakeInstalledApps(
            bundleIDs: [], appNames: ["hopper disassembler"]
        )).scan(context: context, knowledgeBase: .seed)
        XCTAssertTrue(report.findings.isEmpty)
    }

    func testSubtreeContainingAppBundleIsUntouchable() throws {
        // Real case: BitBrowser installs itself inside its own Application
        // Support tree — flagging any part of it would delete a working app.
        try write(1_000, to: "Library/Application Support/BitBrowser/BrowserCache/entry")
        try write(1_000, to: "Library/Application Support/BitBrowser/Chrome-bin/140/BitBrowser.app/Contents/Info.plist")
        let report = scanner(FakeInstalledApps(bundleIDs: [], appNames: []))
            .scan(context: context, knowledgeBase: .seed)
        XCTAssertTrue(report.findings.isEmpty)
    }

    func testPortableAppClaimsItsDataElsewhere() throws {
        // Real case: a self-contained app's *preferences* outside its tree
        // must not be flagged as leftovers either.
        try writePlist(
            ["CFBundleIdentifier": "org.bitbrowser.BitBrowser"],
            to: "Library/Application Support/BitBrowser/Chrome-bin/140/BitBrowser.app/Contents/Info.plist"
        )
        try write(500, to: "Library/Preferences/org.bitbrowser.BitBrowser.plist")
        let report = scanner(FakeInstalledApps(bundleIDs: [], appNames: []))
            .scan(context: context, knowledgeBase: .seed)
        XCTAssertTrue(report.findings.isEmpty)
    }

    func testSystemGroupAppleNamespaceIsProtected() throws {
        // Real case: "systemgroup.com.apple.icloud.searchpartyd.sharedsettings.plist".
        try write(500, to: "Library/Preferences/systemgroup.com.apple.icloud.searchpartyd.sharedsettings.plist")
        let report = scanner(FakeInstalledApps(bundleIDs: [], appNames: []))
            .scan(context: context, knowledgeBase: .seed)
        XCTAssertTrue(report.findings.isEmpty)
    }
}

/// Regressions from a fresh macOS 27 guest (fixture mirrored from the
/// guest's real leftover layout).
final class AppLeftoversVMRegressionTests: FixtureTestCase {

    private func scan(_ ids: Set<String>, names: Set<String> = []) -> [String] {
        AppLeftoversScanner(installed: FakeInstalledApps(bundleIDs: ids, appNames: names))
            .scan(context: context, knowledgeBase: .seed)
            .findings.map(\.url.lastPathComponent)
    }

    // A sandbox container, saved state, cookie store or web store belongs
    // to exactly one bundle ID; a sibling app of the same vendor never
    // shares it. (The VM run missed com.fixture.gone beside com.fixture.live.)
    func testPerBundleRootsIgnoreVendorTeam() throws {
        try write(1_000, to: "Library/Containers/com.fixture.gone/Data/db.sqlite")
        try write(1_000, to: "Library/Saved Application State/com.fixture.gone.savedState/windows.data")
        try write(1_000, to: "Library/Cookies/com.fixture.gone.binarycookies")
        try write(1_000, to: "Library/HTTPStorages/com.fixture.gone/store")

        let found = Set(scan(["com.fixture.live"]))

        XCTAssertTrue(found.contains("com.fixture.gone"))
        XCTAssertTrue(found.contains("com.fixture.gone.savedState"))
        XCTAssertTrue(found.contains("com.fixture.gone.binarycookies"))
    }

    // Preference domains and group containers are routinely shared across a
    // vendor's apps (com.microsoft.office, group.com.vendor.shared): the
    // team rule stays there, deliberately.
    func testSharedRootsKeepVendorTeamProtection() throws {
        try write(1_000, to: "Library/Preferences/com.fixture.shared.plist")
        try write(1_000, to: "Library/Group Containers/group.com.fixture.shared/data")

        XCTAssertTrue(scan(["com.fixture.live"]).isEmpty)
    }

    // Apple data outside the com.apple namespace, observed as false
    // positives in a fresh macOS 27 VM with no third-party apps.
    func testAppleDataOutsideComAppleNamespaceIsProtected() throws {
        try write(1_000, to: "Library/Application Support/CallHistoryDB/CallHistory.storedata")
        try write(1_000, to: "Library/Application Support/Categories/cats.plist")
        try write(1_000, to: "Library/Group Containers/group.is.workflow.my.app/Shortcuts.sqlite")
        try write(1_000, to: "Library/Group Containers/group.is.workflow.shortcuts/data")

        XCTAssertEqual(scan([]), [])
    }

    // Observed on the dev machine: a user-disabled GoogleUpdater still ships
    // its app inside Application Support/Google, which Chrome's name claims.
    // Apps inside a claimed tree must still count as installed.
    func testAppsInsideClaimedApplicationSupportTreesCountAsInstalled() throws {
        try writePlist(["CFBundleIdentifier": "com.google.GoogleUpdater"],
                       to: "Library/Application Support/Google/GoogleUpdater.disabled/1.0/GoogleUpdater.app/Contents/Info.plist")
        try write(1_000, to: "Library/HTTPStorages/com.google.GoogleUpdater/store")

        XCTAssertEqual(scan(["com.google.chrome"], names: ["google chrome"]), [])
    }

    func testTeamPrefixedEmbeddedIDsAlsoCountWithoutPrefix() throws {
        try writePlist(["CFBundleIdentifier": "com.host.app"], to: "Applications/Host.app/Contents/Info.plist")
        try writePlist(["CFBundleIdentifier": "2BUA8C4S2C.com.host.browser-support"],
                       to: "Applications/Host.app/Contents/Library/LoginItems/Support.app/Contents/Info.plist")

        let snapshot = DiskInstalledAppsSnapshot(roots: [fixture.appendingPathComponent("Applications")])

        XCTAssertTrue(snapshot.bundleIDs.contains("com.host.browser-support"))
    }

    // App extensions get their own containers under their own bundle IDs,
    // which need not extend the host app's ID.
    func testEmbeddedBundleIDsCountAsInstalled() throws {
        try writePlist(["CFBundleIdentifier": "com.host.app", "CFBundleName": "Host"],
                       to: "Applications/Host.app/Contents/Info.plist")
        try writePlist(["CFBundleIdentifier": "net.partner.share-extension"],
                       to: "Applications/Host.app/Contents/PlugIns/Share.appex/Contents/Info.plist")
        try writePlist(["CFBundleIdentifier": "net.partner.updater"],
                       to: "Applications/Host.app/Contents/Library/LoginItems/Updater.app/Contents/Info.plist")

        let snapshot = DiskInstalledAppsSnapshot(roots: [fixture.appendingPathComponent("Applications")])

        XCTAssertTrue(snapshot.bundleIDs.isSuperset(of: ["com.host.app", "net.partner.share-extension", "net.partner.updater"]))
    }
}
