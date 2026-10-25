import XCTest
@testable import InkSweepCore

final class ChromiumCacheScannerTests: FixtureTestCase {

    private func chromiumApp(_ rel: String, profiles: [String] = ["Default"]) throws {
        try write(100, to: "Library/Application Support/\(rel)/Local State")
        for p in profiles { try write(100, to: "Library/Application Support/\(rel)/\(p)/Preferences") }
    }

    private func scan(running: Set<String> = []) -> ScanReport {
        ChromiumCacheScanner(runningAppNames: { running }).scan(context: context, knowledgeBase: .seed)
    }

    func testFindsAppAndProfileLevelCachesOnly() throws {
        try chromiumApp("Claude")
        try write(1_000, to: "Library/Application Support/Claude/GPUCache/data_0")
        try write(1_000, to: "Library/Application Support/Claude/Default/Code Cache/js/x")
        try write(1_000, to: "Library/Application Support/Claude/Default/Local Storage/leveldb/000.log")
        try write(1_000, to: "Library/Application Support/Claude/Default/IndexedDB/x")

        let paths = Set(scan().findings.map { rel($0.url) })

        XCTAssertEqual(paths, ["Library/Application Support/Claude/GPUCache",
                               "Library/Application Support/Claude/Default/Code Cache"])
    }

    func testVendorNestedUserDataDirectory() throws {
        try chromiumApp("Google/Chrome", profiles: ["Default", "Profile 1"])
        try write(1_000, to: "Library/Application Support/Google/Chrome/Profile 1/GPUCache/x")
        try write(1_000, to: "Library/Application Support/Google/Chrome/component_crx_cache/x")

        XCTAssertEqual(Set(scan().findings.map { rel($0.url) }), [
            "Library/Application Support/Google/Chrome/Profile 1/GPUCache",
            "Library/Application Support/Google/Chrome/component_crx_cache",
        ])
    }

    func testRunningAppIsSkippedBySingletonLockOrName() throws {
        try chromiumApp("Code")
        try write(1_000, to: "Library/Application Support/Code/CachedData/x")
        XCTAssertEqual(scan(running: ["code"]).findings.count, 0)
        XCTAssertTrue(scan(running: ["code"]).warnings.contains { $0.contains("Code") })

        try FileManager.default.createSymbolicLink(
            atPath: fixture.appendingPathComponent("Library/Application Support/Code/SingletonLock").path,
            withDestinationPath: "host-123")
        XCTAssertEqual(scan().findings.count, 0)
    }

    func testVSCodeShapedAppAlsoGetsLogs() throws {
        try chromiumApp("Code")
        try write(1_000, to: "Library/Application Support/Code/CachedData/x")
        try write(1_000, to: "Library/Application Support/Code/logs/20261025/main.log")

        XCTAssertTrue(scan().findings.contains { rel($0.url) == "Library/Application Support/Code/logs" })
    }

    func testPasswordManagerIsNeverTouched() throws {
        try chromiumApp("1Password")
        try write(1_000, to: "Library/Application Support/1Password/GPUCache/x")

        XCTAssertTrue(scan().findings.isEmpty)
    }

    func testFolderWithoutLocalStateIsNotChromium() throws {
        try write(1_000, to: "Library/Application Support/SomeApp/Cache/important.db")
        XCTAssertTrue(scan().findings.isEmpty)
    }
}

final class ContainerCachesScannerTests: FixtureTestCase {

    private func scan(running: Set<String> = []) -> ScanReport {
        ContainerCachesScanner(minimumContainerBytes: 0,
                               processes: { ProcessSnapshot(executableNames: [], bundleIDs: running) })
            .scan(context: context, knowledgeBase: .seed)
    }

    func testThirdPartyContainerCachesAndTmp() throws {
        try write(1_000, to: "Library/Containers/com.vendor.app/Data/Library/Caches/images/a")
        try write(1_000, to: "Library/Containers/com.vendor.app/Data/tmp/upload.part")
        try write(1_000, to: "Library/Containers/com.vendor.app/Data/Documents/novel.txt")

        XCTAssertEqual(Set(scan().findings.map { rel($0.url) }), [
            "Library/Containers/com.vendor.app/Data/Library/Caches/images",
            "Library/Containers/com.vendor.app/Data/tmp/upload.part",
        ])
    }

    func testAppleSensitiveAndRunningContainersAreSkipped() throws {
        try write(1_000, to: "Library/Containers/com.apple.mail/Data/Library/Caches/x")
        try write(1_000, to: "Library/Containers/com.bitwarden.desktop/Data/Library/Caches/x")
        try write(1_000, to: "Library/Containers/com.vendor.Live/Data/Library/Caches/x")

        XCTAssertTrue(scan(running: ["com.vendor.live"]).findings.isEmpty)
    }

    func testSmallContainersAreNotWorthAFinding() throws {
        try write(1_000, to: "Library/Containers/com.vendor.app/Data/Library/Caches/a")
        let report = ContainerCachesScanner(processes: { .empty }).scan(context: context, knowledgeBase: .seed)
        XCTAssertTrue(report.findings.isEmpty, "default threshold is 1 MB per container")
    }
}

final class EngineNestingTests: FixtureTestCase {
    // A whole orphan container and its cache children must not both count.
    func testFindingsInsideAnotherFindingAreDropped() throws {
        try write(2_000_000, to: "Library/Containers/com.gone.app/Data/Library/Caches/blob")
        let engine = InkSweepEngine.standard(installed: FakeInstalledApps(bundleIDs: [], appNames: []),
                                             runningBundleIDs: { [] })

        let paths = engine.scan(context: context).findings.map { rel($0.url) }
            .filter { $0.contains("com.gone.app") }

        XCTAssertEqual(paths, ["Library/Containers/com.gone.app"])
    }
}
