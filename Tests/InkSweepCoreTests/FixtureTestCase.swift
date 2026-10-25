import XCTest
@testable import InkSweepCore

/// Shared fixture home directory: every scan runs against this throwaway tree,
/// so tests never touch the real filesystem and are deterministic.
class FixtureTestCase: XCTestCase {
    var fixture: URL!

    override func setUpWithError() throws {
        fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("inksweep-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fixture)
    }

    func write(_ bytes: Int, to relativePath: String) throws {
        let url = fixture.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    /// Writes a real property-list file (so NSDictionary(contentsOf:) can read it).
    func writePlist(_ dict: [String: Any], to relativePath: String) throws {
        let url = fixture.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: url)
    }

    /// Fixture-relative path, robust to /var ↔ /private/var resolution.
    func rel(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
            .replacingOccurrences(of: fixture.resolvingSymlinksInPath().path + "/", with: "")
    }

    var context: ScanContext {
        ScanContext(homeDirectory: fixture,
                    applicationRoots: [fixture.appendingPathComponent("Applications", isDirectory: true)])
    }
}

/// A deterministic installed-app universe for leftover/browser scanners.
struct FakeInstalledApps: InstalledAppsSnapshot {
    let bundleIDs: Set<String>
    let appNames: Set<String>
}
