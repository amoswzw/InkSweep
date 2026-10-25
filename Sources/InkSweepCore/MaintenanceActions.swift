import Foundation
import SQLite3

/// Reads and writes another app's preferences. Injectable so tests never
/// touch the user's real defaults.
public protocol PreferenceStore: Sendable {
    func value(_ key: String, domain: String) -> Any?
    /// `nil` deletes the key.
    func set(_ value: Any?, for key: String, domain: String) -> Bool
}

public struct CFPreferenceStore: PreferenceStore {
    public init() {}
    public func value(_ key: String, domain: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, domain as CFString)
    }
    public func set(_ value: Any?, for key: String, domain: String) -> Bool {
        CFPreferencesSetAppValue(key as CFString, value as CFPropertyList?, domain as CFString)
        return CFPreferencesAppSynchronize(domain as CFString)
    }
}

public struct MaintenanceOutcome: Sendable, Equatable {
    public enum Status: Sendable, Equatable { case applied, unchanged, skipped, failed }
    public let status: Status
    public let detail: String

    public init(status: Status, detail: String) {
        self.status = status
        self.detail = detail
    }
}

/// Maintenance that needs no administrator rights. Each action reports what
/// it changed; none rebuilds LaunchServices (re-registering every app makes
/// running Network Extension VPNs read as reinstalled).
public struct MaintenanceActions: Sendable {
    private let preferences: PreferenceStore
    private let quarantineDatabase: URL
    private let run: @Sendable ([String]) -> Int32
    private let capture: @Sendable ([String]) -> (Int32, String)

    public init(
        preferences: PreferenceStore = CFPreferenceStore(),
        quarantineDatabase: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"),
        run: @escaping @Sendable ([String]) -> Int32 = MaintenanceActions.execute,
        capture: @escaping @Sendable ([String]) -> (Int32, String) = MaintenanceActions.executeCapturing
    ) {
        self.preferences = preferences
        self.quarantineDatabase = quarantineDatabase
        self.run = run
        self.capture = capture
    }

    /// Read-only APFS check of the startup volume (works without admin
    /// rights; measured ~5 s on a 1 TB SSD).
    public func verifyStartupDisk() -> MaintenanceOutcome {
        let (status, output) = capture(["/usr/sbin/diskutil", "verifyVolume", "/"])
        if status == 0, output.localizedCaseInsensitiveContains("appears to be OK") {
            return MaintenanceOutcome(status: .unchanged, detail: "startup disk verified OK")
        }
        return MaintenanceOutcome(status: .failed,
                                  detail: "verification reported problems — run First Aid in Disk Utility")
    }

    /// Resets Quick Look's generator list and thumbnail cache.
    public func refreshQuickLook() -> MaintenanceOutcome {
        let a = run(["/usr/bin/qlmanage", "-r", "cache"])
        let b = run(["/usr/bin/qlmanage", "-r"])
        return a == 0 && b == 0
            ? MaintenanceOutcome(status: .applied, detail: "Quick Look thumbnails and generators reset")
            : MaintenanceOutcome(status: .failed, detail: "qlmanage failed")
    }

    /// Stops Finder writing .DS_Store on network shares and USB volumes.
    /// A persistent Finder preference; undo with `allowNetworkDSStore()`.
    public func preventNetworkDSStore() -> MaintenanceOutcome {
        setDSStoreKeys(true, done: ".DS_Store writing stopped on network and USB volumes")
    }

    public func allowNetworkDSStore() -> MaintenanceOutcome {
        setDSStoreKeys(nil, done: ".DS_Store writing restored to the macOS default")
    }

    private func setDSStoreKeys(_ value: Bool?, done: String) -> MaintenanceOutcome {
        let domain = "com.apple.desktopservices"
        var changed = 0
        for key in ["DSDontWriteNetworkStores", "DSDontWriteUSBStores"] {
            let current = (preferences.value(key, domain: domain) as? Bool) ?? false
            guard current != (value ?? false) else { continue }
            guard preferences.set(value, for: key, domain: domain) else {
                return MaintenanceOutcome(status: .failed, detail: "could not write \(domain)")
            }
            changed += 1
        }
        return MaintenanceOutcome(status: changed > 0 ? .applied : .unchanged, detail: done)
    }

    /// Removes App Nap and disk-image-verification overrides that old tweak
    /// tools leave behind, so macOS defaults apply again.
    public func removeLegacyOverrides() -> MaintenanceOutcome {
        let targets = [(".GlobalPreferences", "NSAppSleepDisabled")]
            + ["skip-verify", "skip-verify-locked", "skip-verify-remote"].map { ("com.apple.frameworks.diskimages", $0) }
        var removed: [String] = []
        for (domain, key) in targets {
            guard let value = preferences.value(key, domain: domain), Self.truthy(value) else { continue }
            guard preferences.set(nil, for: key, domain: domain) else {
                return MaintenanceOutcome(status: .failed, detail: "could not update \(domain)")
            }
            removed.append(key)
        }
        return removed.isEmpty
            ? MaintenanceOutcome(status: .unchanged, detail: "no legacy overrides found")
            : MaintenanceOutcome(status: .applied, detail: "removed \(removed.joined(separator: ", "))")
    }

    /// Clears Gatekeeper's download-history log (the record of what was
    /// downloaded from where). Quarantine flags on files are unaffected.
    /// Irreversible: callers confirm first.
    public func clearQuarantineHistory() -> MaintenanceOutcome {
        var db: OpaquePointer?
        guard FileManager.default.fileExists(atPath: quarantineDatabase.path),
              sqlite3_open_v2(quarantineDatabase.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return MaintenanceOutcome(status: .skipped, detail: "download history not readable")
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        var count: Int64 = -1
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM LSQuarantineEvent", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            count = sqlite3_column_int64(statement, 0)
        }
        sqlite3_finalize(statement)
        guard count >= 0 else { return MaintenanceOutcome(status: .failed, detail: "unexpected database layout") }
        guard count > 0 else { return MaintenanceOutcome(status: .unchanged, detail: "download history already empty") }
        guard sqlite3_exec(db, "DELETE FROM LSQuarantineEvent; VACUUM;", nil, nil, nil) == SQLITE_OK else {
            return MaintenanceOutcome(status: .failed, detail: "could not clear download history")
        }
        return MaintenanceOutcome(status: .applied, detail: "cleared \(count) download-history entries")
    }

    /// Deletes simulators whose runtime is no longer installed. Uses Xcode's
    /// own simctl, and only when an Xcode developer directory is selected
    /// (never the CLT shim, which would prompt to install tools).
    /// Irreversible: callers confirm first.
    public func deleteUnavailableSimulators(developerDirectory: String?) -> MaintenanceOutcome {
        guard let dir = developerDirectory, dir.contains(".app/Contents/Developer"),
              FileManager.default.isExecutableFile(atPath: dir + "/usr/bin/simctl") else {
            return MaintenanceOutcome(status: .skipped, detail: "Xcode is not selected")
        }
        return run([dir + "/usr/bin/simctl", "delete", "unavailable"]) == 0
            ? MaintenanceOutcome(status: .applied, detail: "unavailable simulators deleted")
            : MaintenanceOutcome(status: .failed, detail: "simctl failed")
    }

    static func truthy(_ value: Any) -> Bool {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.intValue != 0 }
        if let s = value as? String { return ["1", "true", "yes"].contains(s.lowercased()) }
        return false
    }

    @Sendable public static func executeCapturing(_ argv: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Sendable public static func execute(_ argv: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
