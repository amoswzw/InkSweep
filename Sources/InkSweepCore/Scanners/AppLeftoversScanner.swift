import Foundation

// MARK: - Installed-app snapshot

/// What is installed on this machine, as far as leftover detection cares.
/// Injectable so tests can posit any installed-app universe deterministically.
public protocol InstalledAppsSnapshot: Sendable {
    var bundleIDs: Set<String> { get }
    /// Normalized app names (CFBundleName / CFBundleExecutable): lowercase,
    /// dashes and underscores as spaces, whitespace collapsed.
    var appNames: Set<String> { get }
}

/// The real snapshot, built by scanning the standard application locations
/// for `.app` bundles and reading their Info.plist identifiers and names.
/// Original implementation: no third-party data involved.
public struct DiskInstalledAppsSnapshot: InstalledAppsSnapshot {
    public let bundleIDs: Set<String>
    public let appNames: Set<String>

    /// Bundles an app embeds under their own identifiers (extensions, XPC
    /// services, login-item and helper apps). Each gets its own container.
    static let embeddedBundleDirectories = [
        "Contents/PlugIns", "Contents/Extensions", "Contents/XPCServices",
        "Contents/Library/LoginItems", "Contents/Library/LaunchServices",
        "Contents/Library/SystemExtensions", "Contents/Helpers",
    ]

    public init(roots: [URL]? = nil) {
        let fm = FileManager.default
        let roots = roots ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            // Input methods are real apps that just live elsewhere (Squirrel & co).
            URL(fileURLWithPath: "/Library/Input Methods", isDirectory: true),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
        var ids: Set<String> = []
        var names: Set<String> = []
        for root in roots {
            guard let e = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                // NOTE: deliberately no .skipsHiddenFiles — on modern macOS,
                // /Applications/Safari.app is a hidden symlink into the OS
                // cryptex, and skipping hidden entries would make Safari look
                // uninstalled (observed on macOS 27).
                options: [.skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in e where url.pathExtension == "app" {
                guard let info = NSDictionary(
                    contentsOf: url.appendingPathComponent("Contents/Info.plist")
                ) else { continue }
                if let id = info["CFBundleIdentifier"] as? String, !id.isEmpty {
                    // Bundle IDs are matched case-insensitively everywhere.
                    ids.insert(id.lowercased())
                }
                for key in ["CFBundleName", "CFBundleExecutable"] {
                    if let raw = info[key] as? String {
                        let normalized = Self.normalizeName(raw)
                        if !normalized.isEmpty { names.insert(normalized) }
                    }
                }
                for relative in Self.embeddedBundleDirectories {
                    let dir = url.appendingPathComponent(relative, isDirectory: true)
                    guard let bundles = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                    else { continue }
                    for bundle in bundles {
                        let plist = bundle.appendingPathComponent("Contents/Info.plist")
                        if let id = (NSDictionary(contentsOf: plist)?["CFBundleIdentifier"] as? String)?
                            .lowercased(), !id.isEmpty {
                            ids.insert(id)
                            ids.insert(Self.droppingTeamPrefix(id))
                        }
                    }
                }
            }
        }
        bundleIDs = ids
        appNames = names
    }

    /// "2bua8c4s2c.com.vendor.helper" → "com.vendor.helper": embedded login
    /// items may carry their Team ID as a first component.
    static func droppingTeamPrefix(_ id: String) -> String {
        let parts = id.split(separator: ".", maxSplits: 1)
        guard parts.count == 2, parts[0].count == 10,
              parts[0].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              parts[0].contains(where: \.isNumber) else { return id }
        return String(parts[1])
    }

    /// "Google-Chrome" ≡ "google chrome" ≡ "Google Chrome ".
    public static func normalizeName(_ s: String) -> String {
        let spaced = s
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .lowercased()
        return spaced
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

// MARK: - Scanner

/// Finds per-application data whose owning application is no longer installed
/// (the "uninstaller leftovers" capability), via an original heuristic:
///
/// 1. Build the installed universe (bundle IDs + names) — injectable.
/// 2. For each per-app data root, derive a bundle-id-shaped identifier from
///    the entry's name and check whether an installed app "claims" it:
///    exact match, component-prefix family match, or same vendor team.
/// 3. Apple namespaces and a critical-name protect-list are never flagged.
/// 4. Application Support is name-based with one level of vendor-directory
///    splitting ("Google/Chrome" style), so removing one vendor app never
///    takes a sibling vendor app's data with it. A subtree that itself
///    contains an `.app` bundle is some application's home and is untouchable
///    (self-contained apps install into Application Support).
/// 5. Helper-process identifiers ("…helper", "…browser-helper") are claimed
///    defensively: they never appear as app-bundle IDs.
///
/// False negatives are deliberately preferred over false positives: this
/// scanner must never propose something a live application still needs.
public struct AppLeftoversScanner: Scanner {
    public let category: JunkCategory = .appLeftovers

    private let installed: InstalledAppsSnapshot
    /// Bundle IDs are compared case-insensitively ("cx.c3.TheUnarchiver"
    /// must claim "cx.c3.theunarchiver").
    private let loweredIDs: Set<String>
    private let sizer: FileTreeSizer

    public init(
        installed: InstalledAppsSnapshot = DiskInstalledAppsSnapshot(),
        sizer: FileTreeSizer = FileTreeSizer()
    ) {
        self.installed = installed
        self.loweredIDs = Set(installed.bundleIDs.map { $0.lowercased() })
        self.sizer = sizer
    }

    public func scan(context: ScanContext, knowledgeBase: KnowledgeBase) -> ScanReport {
        var report = ScanReport()
        let home = context.homeDirectory
        // Application Support first: self-contained ("portable") apps live
        // there, and their IDs must be known before judging preferences and
        // containers elsewhere.
        var portableIDs: Set<String> = []
        scanApplicationSupport(home: home, portableIDs: &portableIDs, into: &report)
        scanBundleIDDirectories(home: home, portableIDs: portableIDs, into: &report)
        scanSuffixedEntries(home: home, portableIDs: portableIDs, into: &report)
        return report
    }

    // MARK: Roots

    /// Roots whose children are named by (group-)bundle identifier.
    /// `vendorShared`: entries are routinely shared across one vendor's apps,
    /// so the same-team claim applies. Per-bundle roots (sandbox containers,
    /// web stores) belong to exactly one identifier.
    private static let bundleIDDirectories: [(relative: String, isGroup: Bool, vendorShared: Bool)] = [
        ("Library/Containers", false, false),
        ("Library/HTTPStorages", false, false),
        ("Library/WebKit", false, false),
        ("Library/Application Scripts", false, true),
        ("Library/Group Containers", true, true),
    ]

    /// Roots whose children carry a bundle identifier plus a fixed suffix.
    private static let suffixedRoots: [(relative: String, suffixes: [String], kind: String, vendorShared: Bool)] = [
        ("Library/Preferences", [".plist.lockfile", ".plist"], "preference file", true),
        ("Library/Saved Application State", [".savedState"], "saved application state", false),
        ("Library/Cookies", [".binarycookies"], "cookie store", false),
    ]

    private func scanBundleIDDirectories(home: URL, portableIDs: Set<String>, into report: inout ScanReport) {
        let fm = FileManager.default
        for (relative, isGroup, vendorShared) in Self.bundleIDDirectories {
            let root = home.appendingPathComponent(relative, isDirectory: true)
            guard let children = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for child in children {
                if Self.isSymbolicLink(child) { continue }
                var identifier = child.lastPathComponent
                if isGroup {
                    guard identifier.hasPrefix("group.") else { continue }
                    identifier = String(identifier.dropFirst("group.".count))
                }
                guard Self.looksLikeBundleID(identifier) else { continue }
                // UUID-stamped identifiers are test-run debris, not app data —
                // TestDebrisScanner owns them.
                if TestDebrisScanner.containsUUID(identifier) { continue }
                if claimsInstalledApp(identifier, portableIDs: portableIDs, sameTeamClaims: vendorShared) { continue }
                addFinding(
                    child,
                    reason: "Leftover \(isGroup ? "group container" : "application data") for \"\(identifier)\": no installed app claims this identifier.",
                    into: &report
                )
            }
        }
    }

    private func scanSuffixedEntries(home: URL, portableIDs: Set<String>, into report: inout ScanReport) {
        let fm = FileManager.default
        for (relative, suffixes, kind, vendorShared) in Self.suffixedRoots {
            let root = home.appendingPathComponent(relative, isDirectory: true)
            guard let children = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for child in children {
                if Self.isSymbolicLink(child) { continue }
                var identifier = child.lastPathComponent
                var matched = false
                for suffix in suffixes where identifier.hasSuffix(suffix) {
                    identifier = String(identifier.dropLast(suffix.count))
                    matched = true
                    break
                }
                guard matched, Self.looksLikeBundleID(identifier) else { continue }
                if TestDebrisScanner.containsUUID(identifier) { continue }
                if claimsInstalledApp(identifier, portableIDs: portableIDs, sameTeamClaims: vendorShared) { continue }
                addFinding(
                    child,
                    reason: "Leftover \(kind) for \"\(identifier)\": no installed app claims this identifier.",
                    into: &report
                )
            }
        }
    }

    private func scanApplicationSupport(home: URL, portableIDs: inout Set<String>, into report: inout ScanReport) {
        let fm = FileManager.default
        let root = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        guard let children = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for child in children {
            if Self.isSymbolicLink(child) { continue }
            guard Self.isDirectory(child) else { continue }
            // A subtree that contains .app bundles is some application's home
            // (self-contained apps install into Application Support). Record
            // every such app — even inside claimed trees — so its data elsewhere
            // is not flagged, and never touch the subtree itself.
            let apps = Self.appBundles(in: child)
            for app in apps {
                if let id = (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?[
                    "CFBundleIdentifier"] as? String)?.lowercased(), !id.isEmpty {
                    portableIDs.insert(id)
                }
            }
            if claimsEntry(child.lastPathComponent) || !apps.isEmpty { continue }
            guard let subentries = try? fm.contentsOfDirectory(
                at: child, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }  // unreadable → make no claim either way

            let subdirs = subentries.filter { !Self.isSymbolicLink($0) && Self.isDirectory($0) }
            if subdirs.isEmpty {
                // Plain orphaned app directory (only files inside, or empty).
                addFinding(
                    child,
                    reason: "Leftover application data for \"\(child.lastPathComponent)\": no installed app claims this name.",
                    into: &report
                )
            } else if subdirs.contains(where: { isClaimedByApp($0.lastPathComponent) }) {
                // Vendor-style directory (e.g. "Google" or "Mozilla"): a live
                // application lives beside orphans. Flag only the subdirectories
                // that are neither claimed by an installed app nor protected.
                for sub in subdirs {
                    if isClaimedByApp(sub.lastPathComponent) { continue }
                    if ProtectedPaths.isProtectedName(DiskInstalledAppsSnapshot.normalizeName(sub.lastPathComponent)) { continue }
                    // A subdirectory that itself contains an .app bundle is a
                    // self-contained application: never flag it either.
                    if Self.firstAppBundle(in: sub) != nil { continue }
                    addFinding(
                        sub,
                        reason: "Leftover application data for \"\(sub.lastPathComponent)\": no installed app claims this name.",
                        into: &report
                    )
                }
            } else {
                // No subdirectory belongs to a live app: the whole tree is one
                // uninstalled application's data ("Vivaldi", "Arc", …).
                addFinding(
                    child,
                    reason: "Leftover application data for \"\(child.lastPathComponent)\": no installed app claims this name.",
                    into: &report
                )
            }
        }
    }

    // MARK: Claim logic

    /// True when the bundle-id-shaped identifier is protected or claimed by an
    /// installed app: exact match, helper/prefix family, or same vendor team.
    /// `portableIDs` are apps found living inside their own Application Support
    /// trees — they count as installed too. The team rule intentionally
    /// over-protects (an installed app from the same vendor may share data
    /// with the candidate); callers disable it for per-bundle roots.
    private func claimsInstalledApp(_ identifier: String, portableIDs: Set<String> = [],
                                    sameTeamClaims: Bool = true) -> Bool {
        if ProtectedPaths.isAppleNamespace(identifier) { return true }
        if ProtectedPaths.isProtectedName(DiskInstalledAppsSnapshot.normalizeName(identifier)) { return true }
        let lower = identifier.lowercased()
        // Helper processes of installed apps ("…browser-helper", "….helper"):
        // their IDs never appear as app-bundle IDs, so claim them defensively.
        if let lastComponent = lower.split(separator: ".").last,
           lastComponent.contains("helper") {
            return true
        }
        let ids = portableIDs.isEmpty ? loweredIDs : loweredIDs.union(portableIDs)
        if ids.contains(lower) { return true }
        for installedID in ids {
            if installedID.hasPrefix(lower + ".") { return true }   // helper of this app is installed
            if lower.hasPrefix(installedID + ".") { return true }   // this is a helper of an installed app
            if sameTeamClaims && Self.team(of: lower) == Self.team(of: installedID) { return true }
        }
        return false
    }

    /// True when an *installed application* claims this entry name: app display
    /// name (exact, word-aligned suffix "google chrome" ← "Chrome", or
    /// word-aligned prefix "hopper disassembler" → "Hopper"), or bundle-id
    /// claim when the entry is id-shaped. Protection is deliberately NOT part
    /// of this: a protected subdirectory must not make its parent look like a
    /// live vendor directory.
    private func isClaimedByApp(_ name: String) -> Bool {
        let normalized = DiskInstalledAppsSnapshot.normalizeName(name)
        for appName in installed.appNames {
            if appName == normalized { return true }
            if appName.hasSuffix(" " + normalized) { return true }
            if appName.hasPrefix(normalized + " ") { return true }
        }
        if Self.looksLikeBundleID(name) && claimsInstalledApp(name) { return true }
        return false
    }

    /// `isClaimedByApp` OR outright protected — used to skip a directory
    /// subtree entirely.
    private func claimsEntry(_ name: String) -> Bool {
        if ProtectedPaths.isProtectedName(DiskInstalledAppsSnapshot.normalizeName(name)) { return true }
        return isClaimedByApp(name)
    }

    // MARK: Helpers

    private func addFinding(_ url: URL, reason: String, into report: inout ScanReport) {
        let size = sizer.size(of: url)
        guard size > 0 else { return }
        report.findings.append(Finding(
            url: url,
            category: .appLeftovers,
            sizeBytes: size,
            ruleID: "app-leftover",
            reason: reason,
            reversible: true,
            lastModified: sizer.lastModified(of: url)
        ))
    }

    static func looksLikeBundleID(_ s: String) -> Bool {
        guard !s.isEmpty, !s.hasPrefix("."), !s.hasSuffix(".") else { return false }
        if s.contains(where: { $0.isWhitespace }) { return false }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty }
    }

    static func appBundles(in url: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: nil,
            options: [.skipsPackageDescendants]
        ) else { return [] }
        var out: [URL] = []
        for case let entry as URL in e where entry.pathExtension == "app" {
            out.append(entry)
        }
        return out
    }

    /// The first application bundle found anywhere below `url`, or nil. Such
    /// trees are self-contained app installs (or contain them) — flagging them
    /// would propose deleting a working application.
    static func firstAppBundle(in url: URL) -> URL? {
        guard let e = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: nil,
            options: [.skipsPackageDescendants]
        ) else { return nil }
        for case let entry as URL in e where entry.pathExtension == "app" {
            return entry
        }
        return nil
    }

    static func team(of identifier: String) -> String {
        let parts = identifier.split(separator: ".")
        return parts.count >= 2 ? "\(parts[0]).\(parts[1])" : identifier
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
