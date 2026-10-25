import XCTest
@testable import InkSweepCore

final class BrokenLoginItemsTests: FixtureTestCase {

    private func scanner() -> BrokenLoginItemsScanner { BrokenLoginItemsScanner() }

    private func writeAgent(_ name: String, _ dict: [String: Any]) throws {
        try writePlist(dict, to: "Library/LaunchAgents/\(name)")
    }

    func testFlagsAgentWhoseProgramIsGone() throws {
        try writeAgent("com.fixture.gone.plist", [
            "Label": "com.fixture.gone",
            "Program": "/opt/definitely/not/here/tool",
            "RunAtLoad": true,
        ])
        let report = scanner().scan(context: context, knowledgeBase: .seed)
        XCTAssertEqual(report.findings.count, 1)
        let finding = try XCTUnwrap(report.findings.first)
        XCTAssertEqual(finding.ruleID, "broken-launch-agent")
        XCTAssertEqual(finding.category, .appLeftovers)
        XCTAssertTrue(finding.reason.contains("missing program"))
    }

    func testAliveAgentIsNotFlagged() throws {
        try writeAgent("com.fixture.alive.plist", [
            "Label": "com.fixture.alive",
            "Program": "/bin/echo",
        ])
        let report = scanner().scan(context: context, knowledgeBase: .seed)
        XCTAssertTrue(report.findings.isEmpty)
    }

    func testProgramArgumentsFirstElementIsChecked() throws {
        try writeAgent("com.fixture.args.plist", [
            "Label": "com.fixture.args",
            "ProgramArguments": [fixture.appendingPathComponent("Apps/Gone.app/Contents/MacOS/Gone").path, "--flag"],
        ])
        let report = scanner().scan(context: context, knowledgeBase: .seed)
        XCTAssertEqual(report.findings.count, 1)
    }

    func testAppleManagedAgentsAreSkipped() throws {
        try writeAgent("com.apple.something.user-agent.plist", [
            "Label": "com.apple.something.user-agent",
            "Program": "/nonexistent/apple/tool",
        ])
        let report = scanner().scan(context: context, knowledgeBase: .seed)
        XCTAssertTrue(report.findings.isEmpty)
    }

    func testNonAbsoluteProgramsAreIgnored() throws {
        try writeAgent("com.fixture.relative.plist", [
            "Label": "com.fixture.relative",
            "Program": "just-a-name",
        ])
        let report = scanner().scan(context: context, knowledgeBase: .seed)
        XCTAssertTrue(report.findings.isEmpty)
    }

    func testEmptyShellAgentIsFlagged() throws {
        // Real case: Google's Keystone→GoogleUpdater migration leaves
        // empty <dict/> stub plists that launchd loads to no effect.
        try writeAgent("com.fixture.empty.plist", [:])
        let report = scanner().scan(context: context, knowledgeBase: .seed)
        XCTAssertEqual(report.findings.count, 1)
        let finding = try XCTUnwrap(report.findings.first)
        XCTAssertTrue(finding.reason.contains("Empty login item"))
    }

    func testMachServicesOnlyAgentIsFunctional() throws {
        // XPC-style agent with no Program but registered MachServices —
        // launchd serves it; not broken.
        try writeAgent("com.fixture.xpc.plist", [
            "Label": "com.fixture.xpc",
            "MachServices": ["com.fixture.xpc.service": 1],
        ])
        let report = scanner().scan(context: context, knowledgeBase: .seed)
        XCTAssertTrue(report.findings.isEmpty)
    }

    func testAbsentRootIsSilent() {
        let report = scanner().scan(context: context, knowledgeBase: .seed)
        XCTAssertTrue(report.findings.isEmpty)
        XCTAssertTrue(report.warnings.isEmpty)
    }
}

final class BrokenLoginItemsGuardTests: FixtureTestCase {
    private func writeAgent(_ name: String, _ dict: [String: Any]) throws {
        try writePlist(dict, to: "Library/LaunchAgents/\(name).plist")
    }

    // A program on an unmounted external disk is absent, not broken.
    func testProgramOnUnmountedVolumeIsNotFlagged() throws {
        try writeAgent("com.vendor.backup", ["Label": "com.vendor.backup",
                                             "ProgramArguments": ["/Volumes/NotMounted/Backup.app/Contents/MacOS/Backup"]])
        XCTAssertTrue(BrokenLoginItemsScanner().scan(context: context, knowledgeBase: .seed).findings.isEmpty)
    }

    // SMAppService-style plists name their executable with BundleProgram.
    func testBundleProgramAgentIsNotEmpty() throws {
        try writeAgent("com.vendor.agent", ["Label": "com.vendor.agent",
                                            "BundleProgram": "Contents/MacOS/agent"])
        XCTAssertTrue(BrokenLoginItemsScanner().scan(context: context, knowledgeBase: .seed).findings.isEmpty)
    }
}
