import XCTest
@testable import InkSweepCore

final class UninstallPlannerTests: FixtureTestCase {

    private let target = "com.fixture.target"

    /// Installs a fake app under the fixture home and seeds its data.
    private func installTargetApp() throws {
        try writePlist(
            [
                "CFBundleIdentifier": target,
                "CFBundleName": "TargetApp",
                "CFBundleExecutable": "TargetApp",
                "CFBundleShortVersionString": "1.0",
            ],
            to: "Applications/TargetApp.app/Contents/Info.plist"
        )
        try write(1_000, to: "Applications/TargetApp.app/Contents/MacOS/TargetApp")

        try write(1_000, to: "Library/Containers/\(target)/Data/db.sqlite")
        try write(1_000, to: "Library/Containers/\(target).helper/Data/state")
        try write(500, to: "Library/Preferences/\(target).plist")
        try write(500, to: "Library/Saved Application State/\(target).savedState/windows.data")
        try write(1_000, to: "Library/Application Support/TargetApp/config.json")
        try write(1_000, to: "Library/Caches/\(target)/blob.bin")
        try write(500, to: "Library/Logs/TargetApp/run.log")
    }

    private func planner(othersInstalled: [String] = []) -> UninstallPlanner {
        UninstallPlanner()
    }

    func testPlanIncludesBundleAndAllRelatedData() throws {
        try installTargetApp()
        // Unrelated app data that must stay out of the plan.
        try write(1_000, to: "Library/Containers/com.other.installed/Data/db")
        try write(1_000, to: "Library/Application Support/OtherApp/config.json")

        let plan = planner().plan(bundleID: target, context: context, runningBundleIDs: { [] })

        XCTAssertEqual(plan.app?.bundleID, target)
        let paths = plan.findings.map(\.url.path)

        XCTAssertTrue(paths.contains { $0.hasSuffix("Applications/TargetApp.app") }, "bundle itself")
        XCTAssertTrue(paths.contains { $0.hasSuffix("Containers/\(target)") })
        XCTAssertTrue(paths.contains { $0.contains("\(target).helper") }, "helper container")
        XCTAssertTrue(paths.contains { $0.hasSuffix("\(target).plist") })
        XCTAssertTrue(paths.contains { $0.hasSuffix("\(target).savedState") })
        XCTAssertTrue(paths.contains { $0.contains("Application Support/TargetApp") })
        XCTAssertTrue(paths.contains { $0.contains("Caches/\(target)") })
        XCTAssertTrue(paths.contains { $0.contains("Logs/TargetApp") })

        XCTAssertFalse(paths.contains { $0.contains("com.other.installed") }, "other apps stay")
        XCTAssertFalse(paths.contains { $0.contains("OtherApp") })
    }

    func testSiblingVendorDataStaysOutOfThePlan() throws {
        try installTargetApp()
        // Same vendor team, but NOT this app's identifier family — a sibling
        // app's data must never ride along in an uninstall plan.
        try write(1_000, to: "Library/Containers/com.fixture.inksweep-like-sibling/Data/x")

        let plan = planner().plan(bundleID: target, context: context, runningBundleIDs: { [] })
        XCTAssertFalse(plan.findings.contains { $0.url.path.contains("inksweep-like-sibling") },
                       "sibling vendor data stays out even when no other vendor app remains")
        // The target's own helpers still ride along:
        XCTAssertTrue(plan.findings.contains { $0.url.path.contains("\(target).helper") })
    }

    func testLaunchAgentClaimedByLabelAndByBundlePath() throws {
        try installTargetApp()
        let bundleBin = fixture.appendingPathComponent("Applications/TargetApp.app/Contents/MacOS/TargetApp").path
        try writePlist(["Label": target, "Program": bundleBin],
                       to: "Library/LaunchAgents/\(target).agent.plist")
        try writePlist(["Label": "com.fixture.target.launcher", "Program": bundleBin],
                       to: "Library/LaunchAgents/com.fixture.target.launcher.plist")
        try writePlist(["Label": "com.other.agent", "Program": "/bin/echo"],
                       to: "Library/LaunchAgents/com.other.agent.plist")

        let plan = planner().plan(bundleID: target, context: context, runningBundleIDs: { [] })
        let agents = plan.findings.filter { $0.url.path.contains("LaunchAgents") }
        XCTAssertEqual(agents.count, 2, "label match + in-bundle program match")
    }

    func testSystemAppIsRefused() {
        let plan = planner().plan(bundleID: "com.apple.Safari", context: context, runningBundleIDs: { [] })
        XCTAssertTrue(plan.findings.isEmpty)
        XCTAssertFalse(plan.warnings.isEmpty)
    }

    func testNotInstalledAppIsRefused() {
        let plan = planner().plan(bundleID: "com.nope.missing", context: context, runningBundleIDs: { [] })
        XCTAssertTrue(plan.findings.isEmpty)
        XCTAssertFalse(plan.warnings.isEmpty)
    }

    func testRunningAppProducesWarning() throws {
        try installTargetApp()
        let plan = planner().plan(
            bundleID: target, context: context,
            runningBundleIDs: { [target] }
        )
        XCTAssertFalse(plan.warnings.isEmpty)
        XCTAssertFalse(plan.findings.isEmpty, "plan is still produced; execution is the user's call")
    }

    func testPlanCleansReversiblyViaCleaner() throws {
        try installTargetApp()
        let plan = planner().plan(bundleID: target, context: context, runningBundleIDs: { [] })
        let trasher = RecordingTrasher()
        _ = Cleaner(trasher: trasher).clean(plan.findings, dryRun: true)
        XCTAssertEqual(trasher.trashed.count, 0, "dry run of an uninstall plan touches nothing")
    }
}

final class UninstallVendorDirectoryTests: FixtureTestCase {

    private func install(id: String, name: String) throws {
        try writePlist(["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleExecutable": name],
                       to: "Applications/\(name).app/Contents/Info.plist")
        try write(1_000, to: "Applications/\(name).app/Contents/MacOS/\(name)")
    }

    // "Google" is a word-prefix of "Google Chrome", but it is the vendor's
    // shared directory: uninstalling Chrome must take Google/Chrome only.
    func testPrefixNamedVendorDirectoryIsSplitNotSwept() throws {
        try install(id: "com.google.Chrome", name: "Google Chrome")
        try write(1_000, to: "Library/Application Support/Google/Chrome/Default/History")
        try write(1_000, to: "Library/Application Support/Google/DriveFS/account/db")
        try write(1_000, to: "Library/Caches/Google/DriveFS/blob")
        try write(1_000, to: "Library/Caches/com.google.Chrome/blob")

        let plan = UninstallPlanner().plan(bundleID: "com.google.Chrome", context: context)
        let paths = Set(plan.findings.map { $0.url.standardizedFileURL.path })
        let base = fixture.standardizedFileURL.path

        XCTAssertTrue(paths.contains(base + "/Library/Application Support/Google/Chrome"))
        XCTAssertFalse(paths.contains(base + "/Library/Application Support/Google"), "vendor dir swept whole")
        XCTAssertFalse(paths.contains { $0.contains("DriveFS") }, "sibling app's data in the plan")
        XCTAssertTrue(paths.contains(base + "/Library/Caches/com.google.Chrome"))
        XCTAssertFalse(paths.contains(base + "/Library/Caches/Google"), "vendor cache dir swept whole")
    }

    // The prefix rule's legitimate case: "Hopper" ← "Hopper Disassembler",
    // a directory holding only the app's own files.
    func testPrefixNamedDirectoryWithoutSubdirectoriesIsClaimed() throws {
        try install(id: "com.cryptic-apps.hopper-web-4", name: "Hopper Disassembler")
        try write(1_000, to: "Library/Application Support/Hopper/settings.json")

        let plan = UninstallPlanner().plan(bundleID: "com.cryptic-apps.hopper-web-4", context: context)
        XCTAssertTrue(plan.findings.contains { $0.url.lastPathComponent == "Hopper" })
    }

    func testRunningCheckIgnoresBundleIDCase() throws {
        try install(id: "com.google.Chrome", name: "Google Chrome")
        let plan = UninstallPlanner().plan(bundleID: "com.google.chrome", context: context,
                                           runningBundleIDs: { ["com.google.Chrome"] })
        XCTAssertTrue(plan.warnings.contains { $0.contains("running") })
    }
}
