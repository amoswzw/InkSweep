import Foundation

/// Hard "never touch" list. Every protected name exists because deleting it
/// would destroy user data or break the system — not merely because it is
/// Apple's. This is the false-positive firewall of the leftover scanner:
/// coverage gaps are acceptable here, data loss is not.
public enum ProtectedPaths {

    /// Apple's identifier namespaces: system software always counts as
    /// installed, including group containers ("group.com.apple.*") and
    /// system group preferences ("systemgroup.com.apple.*").
    public static func isAppleNamespace(_ identifier: String) -> Bool {
        identifier.hasPrefix("com.apple.")
            || identifier.hasPrefix("group.com.apple.")
            || identifier.hasPrefix("systemgroup.com.apple.")
            // Shortcuts kept Workflow's namespace after Apple acquired it
            // (group.is.workflow.my.app holds the user's shortcuts).
            || identifier.hasPrefix("is.workflow.")
            || identifier.hasPrefix("group.is.workflow.")
    }

    /// Critical ~/Library children (Application Support entries, preference
    /// file stems, …) that must never be proposed as junk, regardless of what
    /// any matcher says. Keys are normalized names (lowercase, dashes and
    /// underscores as spaces, whitespace collapsed).
    ///
    /// Each entry is a safety invariant, not a style choice:
    /// - mobilesync holds iOS device backups (irreplaceable)
    /// - addressbook holds the Contacts database
    /// - clouddocs holds iCloud Drive content
    public static let protectedNames: Set<String> = [
        "addressbook",       // Apple Contacts database
        "animoji",           // Apple Messages/Photos Animoji data
        "apple computer",    // legacy Apple data
        "app store",
        "callhistory",       // FaceTime / call logs
        "callhistorydb",     // FaceTime / Phone call history store (fresh-VM observation)
        "callhistorytransactions",
        "caches",
        "categories",        // created by macOS itself; seen in a fresh macOS 27 VM
        "clouddocs",         // iCloud Drive content
        "cloudstorage",      // mounted cloud providers (Dropbox, DriveFS, …)
        "containers",
        "crashreporter",
        "diskimages",        // Apple disk-image framework data
        "dock",
        "facetime",
        "group containers",
        "icdd",              // Apple Internet Connectivity daemon data
        "icloud",
        "itunes",
        "knowledge",         // Siri knowledge store
        "messages",
        "mobilesync",        // iOS device backups — irreplaceable
        "nativemessaginghosts",   // browser↔extension bridges (1Password & co.); dir is camel-case "NativeMessagingHosts"
        "networkserviceproxy",    // Apple system daemon data
        "preferences",
        "safari",
        "syncservices",
    ]

    // MARK: - Cleanup-target firewall

    /// Entries whose names say "cache" but hold state, keyed by name prefix.
    /// Every entry's behavior was verified in the wild; the list grows with
    /// evidence, and no code is shared with any other tool.
    static let statefulCachePrefixes: [(prefix: String, reason: String)] = [
        ("ms-playwright", "Playwright's installed browser builds, not a cache"),
        ("deno", "Deno's DENO_DIR also holds origin storage and runtimes"),
        ("GIPPseudonymousID", "Google ID store; deleting it while Gemini runs starts a write loop"),
        ("CCTClearcutLogger", "Google Clearcut queue; same write loop as GIPPseudonymousID"),
        ("FamilyCircle", "Family Sharing state"),
        ("com.displaylink.", "DisplayLink driver agent state"),
        ("com.lasersoft-imaging.", "SilverFast license state"),
        ("app.cotypist.", "Cotypist model data"),
    ]

    /// Vendors whose data is never cleaned: password managers (vault
    /// state) and endpoint-security agents (tamper protection, MDM).
    static let sensitiveVendorPrefixes = [
        "com.1password.", "com.agilebits.", "com.lastpass.", "com.dashlane.", "com.bitwarden.",
        "com.crowdstrike.", "com.sentinelone.", "com.sentinel-labs.", "com.eset.", "com.jamf.",
        "com.jamfsoftware.", "com.paloaltonetworks.", "com.cisco.anyconnect", "com.cisco.secureclient",
        "com.alibaba.security.",
    ]

    /// The same vendors by folder name (Application Support uses names).
    static let sensitiveAppNames = ["1password", "bitwarden", "lastpass", "dashlane", "keepassxc"]

    /// Why `url` must not be proposed by a cleanup rule, or nil if it may.
    /// Applied to every rule-based finding, whatever rule produced it.
    public static func cleanupProtection(for url: URL, home: URL) -> String? {
        let name = url.lastPathComponent
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        let caches = home.appendingPathComponent("Library/Caches").standardizedFileURL.path
        let logs = home.appendingPathComponent("Library/Logs").standardizedFileURL.path

        if parent == caches && isAppleNamespace(name) {
            return "Apple system cache — only curated Apple caches are cleaned, by contents"
        }
        if parent == logs && name == "DiagnosticReports" {
            return "the folder stays; its reports are cleaned one by one"
        }
        if name.hasPrefix("Adobe ") || name.contains(" Adobe") {
            return "Adobe license or plug-in state under a cache-like name"
        }
        for (prefix, reason) in statefulCachePrefixes where name.hasPrefix(prefix) {
            return reason
        }
        for component in url.pathComponents.map({ $0.lowercased() }) {
            if sensitiveVendorPrefixes.contains(where: { component.hasPrefix($0) })
                || sensitiveAppNames.contains(where: { component.hasPrefix($0) }) {
                return "password-manager or endpoint-security data"
            }
        }
        return nil
    }

    /// True when a normalized entry name is protected outright.
    public static func isProtectedName(_ normalized: String) -> Bool {
        if protectedNames.contains(normalized) { return true }
        // Apple-branded entries: "Apple", "Apple Computer", …
        if normalized == "apple" || normalized.hasPrefix("apple ") { return true }
        return false
    }
}
