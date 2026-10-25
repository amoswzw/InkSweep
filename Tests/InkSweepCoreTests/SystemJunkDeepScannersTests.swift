import XCTest
@testable import InkSweepCore

final class SystemJunkDeepScannersTests: FixtureTestCase {

    // MARK: - Universal binaries

    static let x86_64: UInt32 = 0x0100_0007
    static let arm64: UInt32 = 0x0100_000C
    static var host: UInt32 { arm64 }
    static var foreign: UInt32 { x86_64 }

    /// A big-endian fat file whose arch table lists `slices` (cputype, size),
    /// padded to `totalSize` bytes.
    private func writeFatBinary(slices: [(UInt32, UInt32)], totalSize: Int, to rel: String) throws {
        var data = Data([0xCA, 0xFE, 0xBA, 0xBE])
        data.append(UInt32(slices.count).bigEndian.data)
        var offset: UInt32 = 4096
        for (cpu, size) in slices {
            for field in [cpu, 0, offset, size, 12] { data.append(field.bigEndian.data) }
            offset += size
        }
        data.append(Data(repeating: 0x90, count: max(totalSize - data.count, 0)))
        try put(data, rel)
    }

    private func put(_ data: Data, _ rel: String) throws {
        let url = fixture.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private var devIDThinner: AppThinner {
        AppThinner(signing: { _ in .init(developerID: true, teamID: "ABCDE12345") },
                   isRunning: { _ in false }, verify: { _ in true }, rosettaBundleIDs: { [] })
    }

    // lipo keeps the host slice; what it frees is everything else in the
    // file — measured from the arch table, not assumed equal per slice —
    // and only for files thinnable without breaking a code seal.
    func testUniversalBinaryWasteIsFileMinusHostSlices() throws {
        try writePlist(["CFBundleIdentifier": "com.vendor.fat", "CFBundleExecutable": "FatBin"],
                       to: "Apps/Fat.app/Contents/Info.plist")
        try writePlist(["CFBundleExecutable": "Fw"], to: "Apps/Fat.app/Contents/Frameworks/Fw.framework/Versions/A/Resources/Info.plist")
        try writePlist([:], to: "Apps/Fat.app/Contents/Frameworks/Fw.framework/Versions/A/_CodeSignature/CodeResources")
        try writePlist(["files2": ["Frameworks/Fw.framework": ["cdhash": Data([1])]]],
                       to: "Apps/Fat.app/Contents/_CodeSignature/CodeResources")
        try writeFatBinary(slices: [(Self.foreign, 3_000), (Self.host, 6_000)], totalSize: 10_000,
                           to: "Apps/Fat.app/Contents/MacOS/FatBin")
        var thin = Data([0xCE, 0xFA, 0xED, 0xFE])
        thin.append(Data(repeating: 1, count: 4_000))
        try put(thin, "Apps/Fat.app/Contents/MacOS/ThinBin")
        try writeFatBinary(slices: [(Self.foreign, 1_000), (Self.host, 2_000), (0x12, 1_000), (0x0E, 1_000)],
                           totalSize: 8_000, to: "Apps/Fat.app/Contents/Frameworks/Fw.framework/Versions/A/Fw")

        let scanner = UniversalBinaryScanner(appRoots: [fixture.appendingPathComponent("Apps")], thinner: devIDThinner)
        let report = scanner.scan(context: context, knowledgeBase: .seed)

        XCTAssertEqual(report.findings.count, 1)
        XCTAssertEqual(report.findings[0].sizeBytes, (10_000 - 6_000) + (8_000 - 2_000))
        XCTAssertFalse(report.findings[0].reversible, "not a Trash clean — thinning is its own Maintenance action")
        XCTAssertEqual(report.findings[0].category, .systemJunk)
    }

    func testFatBinaryWithoutHostSliceIsNotThinnable() throws {
        try writePlist(["CFBundleIdentifier": "com.vendor.old", "CFBundleExecutable": "Old"],
                       to: "Apps/Old.app/Contents/Info.plist")
        try writePlist([:], to: "Apps/Old.app/Contents/_CodeSignature/CodeResources")
        try writeFatBinary(slices: [(Self.foreign, 3_000), (0x12, 3_000)], totalSize: 8_000,
                           to: "Apps/Old.app/Contents/MacOS/Old")
        let scanner = UniversalBinaryScanner(appRoots: [fixture.appendingPathComponent("Apps")], thinner: devIDThinner)
        XCTAssertTrue(scanner.scan(context: context, knowledgeBase: .seed).findings.isEmpty)
    }

    func testLegacyLanguageNamesMapToCodes() throws {
        try write(2_000, to: "Apps/Old.app/Contents/Resources/English.lproj/Main.nib")
        try write(3_000, to: "Apps/Old.app/Contents/Resources/Japanese.lproj/Main.nib")

        let report = LanguageFilesScanner(appRoots: [fixture.appendingPathComponent("Apps")],
                                          preferredLanguages: ["en"])
            .scan(context: context, knowledgeBase: .seed)

        XCTAssertEqual(report.findings.count, 1)
        XCTAssertFalse(report.findings[0].reason.contains("English"), "English.lproj is the preferred language")
        XCTAssertTrue(report.findings[0].reason.contains("Japanese"))
    }

    func testThinAppsAreSilent() throws {
        var thin = Data([0xCE, 0xFA, 0xED, 0xFE])
        thin.append(Data(repeating: 1, count: 4_000))
        try put(thin, "Apps/Slim.app/Contents/MacOS/Slim")
        let scanner = UniversalBinaryScanner(appRoots: [fixture.appendingPathComponent("Apps")], thinner: devIDThinner)
        XCTAssertTrue(scanner.scan(context: context, knowledgeBase: .seed).findings.isEmpty)
    }

    // MARK: - Language files

    func testLanguageFilesCountNonPreferredOnly() throws {
        try write(2_000, to: "Apps/Talk.app/Contents/Resources/en.lproj/Main.strings")
        try write(3_000, to: "Apps/Talk.app/Contents/Resources/de.lproj/Main.strings")
        try write(4_000, to: "Apps/Talk.app/Contents/Resources/ja.lproj/Main.strings")
        try write(5_000, to: "Apps/Talk.app/Contents/Resources/Base.lproj/Shared.xib")

        let scanner = LanguageFilesScanner(
            appRoots: [fixture.appendingPathComponent("Apps")],
            preferredLanguages: ["en"]
        )
        let report = scanner.scan(context: context, knowledgeBase: .seed)

        // Expected = allocated size of de+ja (the sizer's du-matched semantics).
        let sizer = FileTreeSizer()
        let resources = fixture.appendingPathComponent("Apps/Talk.app/Contents/Resources")
        let expected = sizer.size(of: resources.appendingPathComponent("de.lproj"))
            + sizer.size(of: resources.appendingPathComponent("ja.lproj"))

        XCTAssertEqual(report.findings.count, 1)
        XCTAssertEqual(report.findings[0].sizeBytes, expected, "de+ja counted, en+Base kept")
        XCTAssertFalse(report.findings[0].reversible)
        XCTAssertTrue(report.findings[0].reason.contains("de"))
    }

    func testLanguageFilesMatchDialectPrefixes() throws {
        // Preferred "zh-Hans" must protect "zh-Hans.lproj" AND "zh.lproj".
        try write(2_000, to: "Apps/Cn.app/Contents/Resources/zh-Hans.lproj/a.strings")
        try write(2_000, to: "Apps/Cn.app/Contents/Resources/zh.lproj/a.strings")
        try write(3_000, to: "Apps/Cn.app/Contents/Resources/fr.lproj/a.strings")

        let scanner = LanguageFilesScanner(
            appRoots: [fixture.appendingPathComponent("Apps")],
            preferredLanguages: ["zh-Hans"]
        )
        let report = scanner.scan(context: context, knowledgeBase: .seed)
        XCTAssertEqual(report.findings.count, 1)
        // Only fr counted (allocated size semantics).
        let expected = FileTreeSizer().size(
            of: fixture.appendingPathComponent("Apps/Cn.app/Contents/Resources/fr.lproj"))
        XCTAssertEqual(report.findings[0].sizeBytes, expected)
    }

    // MARK: - Cleanable filter

    func testCleanableFindingsExcludeAnalysisOnly() {
        var report = ScanReport()
        report.findings = [
            Finding(url: URL(fileURLWithPath: "/tmp/a"), category: .userCaches,
                    sizeBytes: 10, ruleID: "r", reason: "reversible", reversible: true),
            Finding(url: URL(fileURLWithPath: "/tmp/b"), category: .systemJunk,
                    sizeBytes: 999, ruleID: "r", reason: "analysis", reversible: false),
        ]
        XCTAssertEqual(report.cleanableFindings.count, 1)
        XCTAssertEqual(report.analysisOnlyBytes, 999)
    }

    func testKnowledgeBaseV3HasSystemLocations() {
        XCTAssertEqual(KnowledgeBase.seed.version, 4)
        XCTAssertTrue(KnowledgeBase.seed.rules.contains { $0.id == "system-caches" && !$0.reversible })
        XCTAssertTrue(KnowledgeBase.seed.rules.contains { $0.id == "system-logs" && !$0.reversible })
    }
}

private extension UInt32 {
    var data: Data {
        withUnsafeBytes(of: self) { Data($0) }
    }
}
