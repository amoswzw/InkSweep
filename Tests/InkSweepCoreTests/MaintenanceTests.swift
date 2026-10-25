import SQLite3
import XCTest
@testable import InkSweepCore

final class StaleStateScannersTests: FixtureTestCase {

    private func backdate(_ rel: String, days: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86_400)],
                                              ofItemAtPath: fixture.appendingPathComponent(rel).path)
    }

    func testOnlySavedStatesOlderThan30DaysGo() throws {
        try write(1_000, to: "Library/Saved Application State/com.vendor.old.savedState/windows.plist")
        try backdate("Library/Saved Application State/com.vendor.old.savedState", days: 45)
        try write(1_000, to: "Library/Saved Application State/com.vendor.new.savedState/windows.plist")

        let found = StaleSavedStateScanner().scan(context: context, knowledgeBase: .seed).findings.map(\.url.lastPathComponent)

        XCTAssertEqual(found, ["com.vendor.old.savedState"])
    }

    func testBrokenPreferencesAreFoundValidAndProtectedOnesStay() throws {
        try writePlist(["ok": true], to: "Library/Preferences/com.vendor.good.plist")
        try write(0, to: "Library/Preferences/com.vendor.empty.plist")
        let garbage = fixture.appendingPathComponent("Library/Preferences/com.vendor.garbage.plist")
        try Data("<plist><dict><key>x".utf8).write(to: garbage)
        try Data("not a plist".utf8).write(to: fixture.appendingPathComponent("Library/Preferences/com.apple.dock.plist"))
        try Data("not a plist".utf8).write(to: fixture.appendingPathComponent("Library/Preferences/com.1password.x.plist"))

        let found = Set(BrokenPreferencesScanner().scan(context: context, knowledgeBase: .seed).findings.map(\.url.lastPathComponent))

        XCTAssertEqual(found, ["com.vendor.empty.plist", "com.vendor.garbage.plist"])
    }
}

/// In-memory preferences so tests never write the user's real defaults.
final class FakePreferences: PreferenceStore, @unchecked Sendable {
    var values: [String: [String: Any]] = [:]
    func value(_ key: String, domain: String) -> Any? { values[domain]?[key] }
    func set(_ value: Any?, for key: String, domain: String) -> Bool {
        values[domain, default: [:]][key] = value
        return true
    }
}

final class MaintenanceActionsTests: XCTestCase {

    func testDSStorePreventionTurnsOnBothKeysAndReportsUnchangedAfter() {
        let prefs = FakePreferences()
        let actions = MaintenanceActions(preferences: prefs)

        XCTAssertEqual(actions.preventNetworkDSStore().status, .applied)
        XCTAssertEqual(prefs.values["com.apple.desktopservices"]?["DSDontWriteNetworkStores"] as? Bool, true)
        XCTAssertEqual(prefs.values["com.apple.desktopservices"]?["DSDontWriteUSBStores"] as? Bool, true)
        XCTAssertEqual(actions.preventNetworkDSStore().status, .unchanged)
    }

    func testLegacyOverridesAreRemovedOnlyWhenSet() {
        let prefs = FakePreferences()
        let actions = MaintenanceActions(preferences: prefs)
        XCTAssertEqual(actions.removeLegacyOverrides().status, .unchanged)

        prefs.values[".GlobalPreferences"] = ["NSAppSleepDisabled": true]
        prefs.values["com.apple.frameworks.diskimages"] = ["skip-verify": "YES", "keep": 1]
        let outcome = actions.removeLegacyOverrides()

        XCTAssertEqual(outcome.status, .applied)
        XCTAssertNil(prefs.values[".GlobalPreferences"]?["NSAppSleepDisabled"] ?? nil)
        XCTAssertNil(prefs.values["com.apple.frameworks.diskimages"]?["skip-verify"] ?? nil)
        XCTAssertNotNil(prefs.values["com.apple.frameworks.diskimages"]?["keep"] ?? nil, "unrelated keys stay")
    }

    func testQuarantineHistoryIsClearedButTableKept() throws {
        let db = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: db) }
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(db.path, &handle), SQLITE_OK)
        sqlite3_exec(handle, "CREATE TABLE LSQuarantineEvent (LSQuarantineEventIdentifier TEXT); INSERT INTO LSQuarantineEvent VALUES ('a'),('b');", nil, nil, nil)
        sqlite3_close(handle)

        let actions = MaintenanceActions(preferences: FakePreferences(), quarantineDatabase: db)
        let outcome = actions.clearQuarantineHistory()

        XCTAssertEqual(outcome.status, .applied)
        XCTAssertTrue(outcome.detail.contains("2"))
        XCTAssertEqual(actions.clearQuarantineHistory().status, .unchanged)
    }

    func testCommandsGoThroughTheRunner() {
        let recorder = CommandRecorder()
        let actions = MaintenanceActions(preferences: FakePreferences(), run: recorder.run)

        _ = actions.refreshQuickLook()

        XCTAssertEqual(recorder.calls, [["/usr/bin/qlmanage", "-r", "cache"], ["/usr/bin/qlmanage", "-r"]])
    }
}

final class CommandRecorder: @unchecked Sendable {
    var calls: [[String]] = []
    func run(_ argv: [String]) -> Int32 { calls.append(argv); return 0 }
}

final class DiskVerifyTests: XCTestCase {
    func testVerifyReadsDiskutilsVerdict() {
        let ok = MaintenanceActions(preferences: FakePreferences(),
                                    capture: { _ in (0, "The volume /dev/rdisk3s1 appears to be OK\n") })
        XCTAssertEqual(ok.verifyStartupDisk().status, .unchanged)

        let bad = MaintenanceActions(preferences: FakePreferences(),
                                     capture: { _ in (1, "error: invalid object map\n") })
        XCTAssertEqual(bad.verifyStartupDisk().status, .failed)
        XCTAssertTrue(bad.verifyStartupDisk().detail.contains("Disk Utility"))
    }
}
