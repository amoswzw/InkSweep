import XCTest
@testable import InkSweepCore

final class InstallerFilesScannerTests: FixtureTestCase {

    private func age(_ rel: String, days: Double) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-days * 86_400)],
            ofItemAtPath: fixture.appendingPathComponent(rel).path)
    }

    private func scan(attached: Set<String> = []) -> [String] {
        InstallerFilesScanner(attachedImages: { attached })
            .scan(context: context, knowledgeBase: .seed).findings.map { rel($0.url) }.sorted()
    }

    func testOldInstallersInDownloadsAndDesktop() throws {
        for f in ["Downloads/Tool-1.2.dmg", "Downloads/sub/Driver.PKG", "Desktop/ubuntu.iso", "Downloads/Xcode.xip"] {
            try write(10_000, to: f); try age(f, days: 30)
        }
        try write(10_000, to: "Downloads/report.pdf"); try age("Downloads/report.pdf", days: 30)

        XCTAssertEqual(scan(), ["Desktop/ubuntu.iso", "Downloads/Tool-1.2.dmg", "Downloads/Xcode.xip", "Downloads/sub/Driver.PKG"])
    }

    func testFreshAndMountedImagesStay() throws {
        try write(10_000, to: "Downloads/new.dmg")
        try write(10_000, to: "Downloads/mounted.dmg"); try age("Downloads/mounted.dmg", days: 30)
        let mounted = fixture.appendingPathComponent("Downloads/mounted.dmg").resolvingSymlinksInPath().path

        XCTAssertEqual(scan(attached: [mounted]), [])
    }
}

final class ProjectArtifactsScannerTests: FixtureTestCase {

    private func old(_ rel: String) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-30 * 86_400)],
            ofItemAtPath: fixture.appendingPathComponent(rel).path)
    }

    private func scan(tracked: [String: Bool?] = [:]) -> [String] {
        ProjectArtifactsScanner(isTracked: { repo, path in tracked[path.lastPathComponent] ?? false })
            .scan(context: context, knowledgeBase: .seed).findings.map { rel($0.url) }.sorted()
    }

    func testArtifactsNeedTheirProjectMarker() throws {
        try write(10, to: "Projects/web/package.json"); try write(10, to: "Projects/web/package-lock.json")
        try write(5_000, to: "Projects/web/node_modules/left-pad/index.js"); try old("Projects/web/node_modules")
        try write(10, to: "Projects/crate/Cargo.toml")
        try write(5_000, to: "Projects/crate/target/debug/app"); try old("Projects/crate/target")
        try write(10, to: "Projects/pkg/Package.swift")
        try write(5_000, to: "Projects/pkg/.build/debug/x"); try old("Projects/pkg/.build")
        // No marker: a folder that merely has an artifact's name.
        try write(5_000, to: "Projects/notes/target/chapter1.md"); try old("Projects/notes/target")
        // node_modules without a lockfile was never installed reproducibly.
        try write(10, to: "Projects/nolock/package.json")
        try write(5_000, to: "Projects/nolock/node_modules/x/index.js"); try old("Projects/nolock/node_modules")

        XCTAssertEqual(scan(), ["Projects/crate/target", "Projects/pkg/.build", "Projects/web/node_modules"])
    }

    func testRecentlyTouchedArtifactsStay() throws {
        try write(10, to: "Code/app/Cargo.toml")
        try write(5_000, to: "Code/app/target/debug/app")
        XCTAssertEqual(scan(), [])
    }

    func testGitTrackedOrUnknownOrNestedRepoStays() throws {
        try write(10, to: "dev/a/Cargo.toml"); try write(10, to: "dev/a/.git/HEAD")
        try write(5_000, to: "dev/a/target/x"); try old("dev/a/target")
        try write(10, to: "dev/b/Cargo.toml"); try write(10, to: "dev/b/.git/HEAD")
        try write(5_000, to: "dev/b/target/x"); try old("dev/b/target")
        try write(10, to: "dev/c/Cargo.toml")
        try write(5_000, to: "dev/c/target/vendored/.git/HEAD"); try old("dev/c/target")
        try write(10, to: "dev/d/Cargo.toml"); try write(10, to: "dev/d/.git/HEAD")
        try write(5_000, to: "dev/d/target/x"); try old("dev/d/target")

        // a: tracked, b: git could not answer (nil), d: untracked → only d goes.
        let found = ProjectArtifactsScanner(isTracked: { repo, path in
            switch repo.lastPathComponent { case "a": return true; case "b": return nil; default: return false }
        }).scan(context: context, knowledgeBase: .seed).findings.map { rel($0.url) }

        XCTAssertEqual(found, ["dev/d/target"])
    }

    func testArtifactIsNeverAContainer() throws {
        // A stray ~/Projects/node_modules full of package folders is not a set of projects.
        try write(10, to: "Projects/node_modules/pkg/package.json")
        try write(10, to: "Projects/node_modules/pkg/package-lock.json")
        try write(5_000, to: "Projects/node_modules/pkg/dist/index.js"); try old("Projects/node_modules/pkg/dist")

        XCTAssertEqual(scan(), [])
    }
}

final class DeviceFirmwareScannerTests: FixtureTestCase {
    func testCachedRestoreImagesButNotFreshOnes() throws {
        let old = Date().addingTimeInterval(-86_400)
        for f in ["Library/iTunes/iPhone Software Updates/iPhone17,1_26.0_Restore.ipsw",
                  "Library/Group Containers/K36BKF7T3D.group.com.apple.configurator/Library/Caches/Firmware/iPad_26.ipsw"] {
            try write(10_000, to: f)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: fixture.appendingPathComponent(f).path)
        }
        try write(10_000, to: "Library/iTunes/iPad Software Updates/downloading.ipsw")
        try write(10_000, to: "Library/iTunes/iPhone Software Updates/notes.txt")

        let found = DeviceFirmwareScanner().scan(context: context, knowledgeBase: .seed).findings.map { $0.url.lastPathComponent }

        XCTAssertEqual(Set(found), ["iPhone17,1_26.0_Restore.ipsw", "iPad_26.ipsw"])
    }
}
