import XCTest
@testable import InkSweepCore

final class AppThinnerTests: FixtureTestCase {

    static let host = UniversalBinaryScanner.hostCPUType
    static let foreign: UInt32 = host == 0x0100_000C ? 0x0100_0007 : 0x0100_000C

    /// A fat file whose host slice is `hostBytes` of 0xAA, foreign slice of 0xBB.
    private func fat(_ rel: String, hostBytes: Int = 4_096, foreignBytes: Int = 8_192) throws {
        var header = Data([0xCA, 0xFE, 0xBA, 0xBE])
        header.append(contentsOf: Self.be(2))
        let foreignOffset = 4_096, hostOffset = foreignOffset + foreignBytes
        for (cpu, off, size) in [(Self.foreign, foreignOffset, foreignBytes), (Self.host, hostOffset, hostBytes)] {
            for field in [cpu, 0, UInt32(off), UInt32(size), 12] { header.append(contentsOf: Self.be(field)) }
        }
        var data = header + Data(repeating: 0, count: foreignOffset - header.count)
        data += Data(repeating: 0xBB, count: foreignBytes) + Data(repeating: 0xAA, count: hostBytes)
        let url = fixture.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private static func be(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.bigEndian) { Array($0) } }

    private func seal(_ rel: String, _ files2: [String: [String: Any]]) throws {
        try writePlist(["files2": files2], to: rel)
    }

    /// An app shaped like an Electron app: main executable, a cdhash-sealed
    /// framework whose bundled library is hash-sealed, a hash-sealed and a
    /// cdhash-sealed loose dylib, and a fat file in Resources.
    private func makeApp() throws {
        let c = "Applications/Demo.app/Contents"
        try writePlist(["CFBundleIdentifier": "com.vendor.demo", "CFBundleExecutable": "Demo"], to: "\(c)/Info.plist")
        try fat("\(c)/MacOS/Demo")
        let fw = "\(c)/Frameworks/Engine.framework/Versions/A"
        // Real frameworks: top-level symlinks into Versions/Current.
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent("\(fw)/Resources"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: fixture.appendingPathComponent("\(c)/Frameworks/Engine.framework/Resources").path,
            withDestinationPath: "Versions/Current/Resources")
        try FileManager.default.createSymbolicLink(
            atPath: fixture.appendingPathComponent("\(c)/Frameworks/Engine.framework/Versions/Current").path,
            withDestinationPath: "A")
        try writePlist(["CFBundleExecutable": "Engine"], to: "\(fw)/Resources/Info.plist")
        try fat("\(fw)/Engine")
        try fat("\(fw)/Libraries/libcodec.dylib")
        try seal("\(fw)/_CodeSignature/CodeResources", ["Libraries/libcodec.dylib": ["hash2": Data([1])]])
        try fat("\(c)/Frameworks/libnested.dylib")
        try fat("\(c)/Frameworks/libplain.dylib")
        try fat("\(c)/Resources/tool")
        try seal("\(c)/_CodeSignature/CodeResources", [
            "Frameworks/Engine.framework": ["cdhash": Data([2]), "requirement": "x"],
            "Frameworks/libnested.dylib": ["cdhash": Data([3]), "requirement": "x"],
            "Frameworks/libplain.dylib": ["hash2": Data([4])],
        ])
    }

    private var app: URL { fixture.appendingPathComponent("Applications/Demo.app") }

    private func thinner(signing: AppThinner.Signing? = .init(developerID: true, teamID: "ABCDE12345"),
                         running: Bool = false, verify: Bool = true,
                         rosetta: Set<String> = []) -> AppThinner {
        AppThinner(signing: { _ in signing }, isRunning: { _ in running }, verify: { _ in verify },
                   rosettaBundleIDs: { rosetta }, trasher: MovingTrasher(trash: fixture.appendingPathComponent(".Trash")))
    }

    func testOnlyMainExecutablesAndCdhashSealedCodeAreThinned() throws {
        try makeApp()
        guard case .success(let plan) = thinner().plan(app: app) else { return XCTFail("refused") }

        XCTAssertEqual(Set(plan.files.map { rel($0.url) }), [
            "Applications/Demo.app/Contents/MacOS/Demo",
            "Applications/Demo.app/Contents/Frameworks/Engine.framework/Versions/A/Engine",
            "Applications/Demo.app/Contents/Frameworks/libnested.dylib",
        ])
        XCTAssertEqual(plan.savings, 3 * (4_096 + 8_192 + 4_096 - 4_096), "file size minus the host slice")
    }

    // An outer seal that lists a nested main executable by plain hash wins:
    // thinning it would break the outer seal (a Quick Look plugin case).
    func testOuterPlainHashBeatsNestedMainExecutable() throws {
        let c = "Applications/Demo.app/Contents"
        try writePlist(["CFBundleIdentifier": "com.vendor.demo", "CFBundleExecutable": "Demo"], to: "\(c)/Info.plist")
        try fat("\(c)/MacOS/Demo")
        let plugin = "\(c)/Library/QuickLook/Demo.qlgenerator/Contents"
        try writePlist(["CFBundleExecutable": "Demo"], to: "\(plugin)/Info.plist")
        try fat("\(plugin)/MacOS/Demo")
        try seal("\(plugin)/_CodeSignature/CodeResources", [:])
        try seal("\(c)/_CodeSignature/CodeResources", [
            "Library/QuickLook/Demo.qlgenerator/Contents/MacOS/Demo": ["hash2": Data([9])],
        ])

        guard case .success(let plan) = thinner().plan(app: app) else { return XCTFail("refused") }
        XCTAssertEqual(plan.files.map { rel($0.url) }, ["Applications/Demo.app/Contents/MacOS/Demo"])
    }

    func testRefusals() throws {
        try makeApp()
        XCTAssertEqual(thinner(signing: nil).plan(app: app).refusal, .notDeveloperID)
        XCTAssertEqual(thinner(signing: .init(developerID: false, teamID: nil)).plan(app: app).refusal, .notDeveloperID)
        XCTAssertEqual(thinner(running: true).plan(app: app).refusal, .running)
        XCTAssertEqual(thinner(rosetta: ["com.vendor.demo"]).plan(app: app).refusal, .rosetta)
        try write(10, to: "Applications/Demo.app/Contents/_MASReceipt/receipt")
        XCTAssertEqual(thinner().plan(app: app).refusal, .appStore)
    }

    func testThinSwapsInVerifiedCloneAndTrashesOriginal() throws {
        try makeApp()
        let receipt = thinner().thin(app: app)

        XCTAssertEqual(receipt.outcome, .thinned)
        let main = try Data(contentsOf: app.appendingPathComponent("Contents/MacOS/Demo"))
        XCTAssertEqual(main, Data(repeating: 0xAA, count: 4_096), "only the host slice remains")
        let plain = try Data(contentsOf: app.appendingPathComponent("Contents/Frameworks/libplain.dylib"))
        XCTAssertEqual(plain.prefix(4), Data([0xCA, 0xFE, 0xBA, 0xBE]), "hash-sealed file untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.appendingPathComponent(".Trash/Demo.app").path),
                      "original goes to the Trash")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.appendingPathComponent("Applications").path),
                       ["Demo.app"], "staging folder removed")
    }

    func testFailedVerificationLeavesTheOriginalAlone() throws {
        try makeApp()
        let before = try Data(contentsOf: app.appendingPathComponent("Contents/MacOS/Demo"))

        let receipt = thinner(verify: false).thin(app: app)

        guard case .failed = receipt.outcome else { return XCTFail("\(receipt.outcome)") }
        XCTAssertEqual(try Data(contentsOf: app.appendingPathComponent("Contents/MacOS/Demo")), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.appendingPathComponent(".Trash").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.appendingPathComponent("Applications").path),
                       ["Demo.app"])
    }
}

/// Moves into a fixture Trash so the swap path runs for real.
struct MovingTrasher: Trasher {
    let trash: URL
    func trash(_ url: URL) throws -> URL? {
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let dest = trash.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    }
}

extension Result where Success == ThinPlan, Failure == ThinRefusal {
    var refusal: ThinRefusal? { if case .failure(let r) = self { return r } else { return nil } }
}
