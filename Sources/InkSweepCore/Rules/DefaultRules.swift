import Foundation

public extension KnowledgeBase {
    /// The seed dataset. Every rule is an original entry grounded in Apple's
    /// documented directory conventions, each with its own provenance and a note
    /// on why removal is safe (what regenerates the data). This grows over time.
    ///
    /// Deliberately absent: `~/Library/Developer/Xcode/Archives` (holds release
    /// builds and dSYMs users may still need — junk status is a user decision,
    /// not a rule) and CoreSimulator/Devices (contains simulator user data).
    static let seed = KnowledgeBase(version: 4, rules: coreRules + extendedRules)

    private static let coreRules: [Rule] = [
        Rule(
            id: "user-caches",
            category: .userCaches,
            root: .home("Library/Caches"),
            strategy: .childrenOfDirectory,
            reason: "Per-application cache; apps regenerate it on demand.",
            provenance: Provenance(
                source: "Apple File System Programming Guide — Library/Caches",
                note: "Caches hold recomputable data and may be purged when the app is not running."
            )
        ),
        Rule(
            id: "user-logs",
            category: .systemLogs,
            root: .home("Library/Logs"),
            strategy: .childrenOfDirectory,
            reason: "User-level diagnostic logs; safe to clear.",
            provenance: Provenance(
                source: "Apple File System Programming Guide — Library/Logs",
                note: "Logs are diagnostic records, not user data; apps recreate them as needed."
            )
        ),
        Rule(
            id: "trash",
            category: .trash,
            root: .home(".Trash"),
            strategy: .childrenOfDirectory,
            reason: "Items already in the Trash.",
            provenance: Provenance(
                source: "macOS Finder Trash (~/.Trash)",
                note: "Contents were already discarded by the user."
            )
        ),
        Rule(
            id: "xcode-derived-data",
            category: .developerJunk,
            root: .home("Library/Developer/Xcode/DerivedData"),
            strategy: .childrenOfDirectory,
            reason: "Xcode build intermediates; rebuilt automatically.",
            provenance: Provenance(
                source: "Xcode DerivedData location",
                note: "Derived build products and indexes are regenerated on the next build."
            )
        ),
        Rule(
            id: "xcode-ios-device-support",
            category: .developerJunk,
            root: .home("Library/Developer/Xcode/iOS DeviceSupport"),
            strategy: .childrenOfDirectory,
            reason: "Cached symbols for previously connected iOS devices/OS versions.",
            provenance: Provenance(
                source: "Xcode iOS DeviceSupport cache",
                note: "Re-downloaded when a device with that OS version is next connected."
            )
        ),
        Rule(
            id: "watchos-device-support",
            category: .developerJunk,
            root: .home("Library/Developer/Xcode/watchOS DeviceSupport"),
            strategy: .childrenOfDirectory,
            reason: "Cached symbols for previously paired watchOS devices/OS versions.",
            provenance: Provenance(
                source: "Xcode watchOS DeviceSupport cache",
                note: "Re-downloaded when a paired watch with that OS version is next connected."
            )
        ),
        Rule(
            id: "tvos-device-support",
            category: .developerJunk,
            root: .home("Library/Developer/Xcode/tvOS DeviceSupport"),
            strategy: .childrenOfDirectory,
            reason: "Cached symbols for previously connected tvOS devices/OS versions.",
            provenance: Provenance(
                source: "Xcode tvOS DeviceSupport cache",
                note: "Re-downloaded when a device with that OS version is next connected."
            )
        ),
        Rule(
            id: "visionos-device-support",
            category: .developerJunk,
            root: .home("Library/Developer/Xcode/visionOS DeviceSupport"),
            strategy: .childrenOfDirectory,
            reason: "Cached symbols for previously connected visionOS devices/OS versions.",
            provenance: Provenance(
                source: "Xcode visionOS DeviceSupport cache",
                note: "Re-downloaded when a device with that OS version is next connected (Xcode 16 name)."
            )
        ),
        Rule(
            id: "xcode-device-logs",
            category: .developerJunk,
            root: .home("Library/Developer/Xcode/iOS Device Logs"),
            strategy: .childrenOfDirectory,
            reason: "Symbolicated device console logs kept from past debugging sessions.",
            provenance: Provenance(
                source: "Xcode iOS Device Logs",
                note: "Historical diagnostics only; new logs are captured on next device use."
            )
        ),
        Rule(
            id: "simulator-caches",
            category: .developerJunk,
            root: .home("Library/Developer/CoreSimulator/Caches"),
            strategy: .directoryItself,
            reason: "CoreSimulator internal caches.",
            provenance: Provenance(
                source: "CoreSimulator Caches directory",
                note: "Simulator service cache; regenerated by CoreSimulator on demand. Device data under CoreSimulator/Devices is deliberately NOT touched."
            )
        ),
        Rule(
            id: "system-caches",
            category: .systemJunk,
            root: .absolute("/Library/Caches"),
            strategy: .childrenOfDirectory,
            reason: "System-wide caches — reported for analysis; cleaning needs administrator privileges.",
            provenance: Provenance(
                source: "macOS system directory conventions — /Library/Caches",
                note: "Third-party system-wide caches. Apps recreate them; removal is safe but requires admin (privileged-helper phase)."
            ),
            reversible: false
        ),
        Rule(
            id: "system-logs",
            category: .systemJunk,
            root: .absolute("/Library/Logs"),
            strategy: .childrenOfDirectory,
            reason: "System-wide diagnostic logs — reported for analysis; cleaning needs administrator privileges.",
            provenance: Provenance(
                source: "macOS system directory conventions — /Library/Logs",
                note: "Diagnostic records, not user data. Removal requires admin (privileged-helper phase)."
            ),
            reversible: false
        ),
    ]
}
