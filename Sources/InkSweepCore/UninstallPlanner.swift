import Foundation

/// One installed application, as the uninstaller sees it.
public struct InstalledApp: Codable, Sendable, Hashable, Identifiable {
    public let url: URL
    /// Lowercased bundle identifier.
    public let bundleID: String
    /// Normalized app name ("Google-Chrome" ≡ "google chrome").
    public let name: String
    /// App name as written in its Info.plist.
    public let rawName: String
    /// CFBundleShortVersionString, when present.
    public let version: String?
    /// Sparkle feed URL, when the app ships one (updater support).
    public let sparkleFeed: String?
    /// CFBundleVersion — the number Sparkle compares updates against.
    public let buildVersion: String?
    /// SUPublicEDKey: the key an update's EdDSA signature must verify with.
    public let edPublicKey: String?

    /// Installed from the Mac App Store (it carries Apple's receipt).
    public var isAppStore: Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path)
    }

    public var id: String { bundleID }

    public init(url: URL, bundleID: String, name: String, rawName: String,
                version: String?, sparkleFeed: String?,
                buildVersion: String? = nil, edPublicKey: String? = nil) {
        self.url = url
        self.bundleID = bundleID
        self.name = name
        self.rawName = rawName
        self.version = version
        self.sparkleFeed = sparkleFeed
        self.buildVersion = buildVersion
        self.edPublicKey = edPublicKey
    }
}

/// Full-uninstall planner (the Uninstaller capability). Given an installed
/// app's bundle ID, produces every removal target: the .app bundle itself
/// plus all per-app data that would otherwise become AppLeftoversScanner
/// findings. Claim rules, scoped to one app — deliberately narrower than the
/// leftover scanner's, because here matching means *deleting*:
///
/// - exact bundle-ID match, or the target's component-prefix family
///   (its helpers: "app.helper" belongs to "app")
/// - name claims (exact, word-aligned suffix/prefix) for Application Support
/// - LaunchAgents whose label matches or whose program lives inside the bundle
/// - vendor-team data is NOT swept: a sibling app's files stay put
/// - protected names and portable-app subtrees are never included
///
/// Refuses system apps (`com.apple.*`). A plan is data only — executing it
/// goes through the usual reversible Cleaner (Trash), never the Shredder.
public struct UninstallPlanner: Sendable {
    public struct Plan: Codable, Sendable {
        public let app: InstalledApp?
        public let bundleID: String
        public let findings: [Finding]
        public let warnings: [String]

        public var totalBytes: Int64 { findings.reduce(0) { $0 + $1.sizeBytes } }

        public init(app: InstalledApp?, bundleID: String, findings: [Finding], warnings: [String]) {
            self.app = app
            self.bundleID = bundleID
            self.findings = findings
            self.warnings = warnings
        }
    }

    private let sizer: FileTreeSizer

    public init(sizer: FileTreeSizer = FileTreeSizer()) {
        self.sizer = sizer
    }

    // MARK: - Installed-app listing

    /// Lists installed apps under the standard locations (original walk:
    /// .app bundles → Info.plist). Note: /System/Applications is excluded —
    /// system apps are not uninstallable.
    public static func installedApps(context: ScanContext) -> [InstalledApp] {
        let fm = FileManager.default
        var out: [InstalledApp] = []
        for base in context.applicationRoots {
            guard let e = fm.enumerator(
                at: base, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsPackageDescendants]  // hidden cryptex symlinks included on purpose
            ) else { continue }
            for case let url as URL in e where url.pathExtension == "app" {
                guard let info = NSDictionary(
                    contentsOf: url.appendingPathComponent("Contents/Info.plist")
                ) else { continue }
                guard let id = (info["CFBundleIdentifier"] as? String)?.lowercased(), !id.isEmpty
                else { continue }
                let rawName = (info["CFBundleName"] as? String)
                    ?? (info["CFBundleExecutable"] as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                out.append(InstalledApp(
                    url: url,
                    bundleID: id,
                    name: DiskInstalledAppsSnapshot.normalizeName(rawName),
                    rawName: rawName,
                    version: info["CFBundleShortVersionString"] as? String,
                    sparkleFeed: info["SUFeedURL"] as? String,
                    buildVersion: info["CFBundleVersion"] as? String,
                    edPublicKey: info["SUPublicEDKey"] as? String
                ))
            }
        }
        return out.sorted { $0.rawName.localizedCaseInsensitiveCompare($1.rawName) == .orderedAscending }
    }

    // MARK: - Planning

    public func plan(
        bundleID: String,
        context: ScanContext,
        runningBundleIDs: @Sendable () -> Set<String> = { [] }
    ) -> Plan {
        let target = bundleID.lowercased()

        if ProtectedPaths.isAppleNamespace(target) {
            return Plan(app: nil, bundleID: target, findings: [],
                        warnings: ["\(bundleID) is a system app — not uninstallable."])
        }

        guard let app = Self.installedApps(context: context).first(where: { $0.bundleID == target })
        else {
            return Plan(app: nil, bundleID: target, findings: [],
                        warnings: ["\(bundleID) is not installed under the standard locations."])
        }

        var warnings: [String] = []
        if runningBundleIDs().contains(where: { $0.lowercased() == target }) {
            warnings.append("\(app.rawName) is running — quit it before uninstalling.")
        }

        var findings: [Finding] = [
            Finding(
                url: app.url,
                category: .appLeftovers,
                sizeBytes: sizer.size(of: app.url),
                ruleID: "uninstall-bundle",
                reason: "Application bundle \(app.rawName).",
                reversible: true,
                lastModified: sizer.lastModified(of: app.url)
            )
        ]

        let fm = FileManager.default

        /// The app's own identifier family only — no vendor-team sweeping:
        /// in an uninstall plan, a match means deletion, so sibling apps'
        /// data must stay out even when no other app of the vendor remains.
        func idClaims(_ identifier: String) -> Bool {
            let lower = identifier.lowercased()
            return lower == target || lower.hasPrefix(target + ".")
        }

        /// Exact or word-aligned suffix ("Chrome" ← "Google Chrome").
        func nameClaims(_ name: String) -> Bool {
            let n = DiskInstalledAppsSnapshot.normalizeName(name)
            return n == app.name || app.name.hasSuffix(" " + n)
        }

        /// Word-aligned prefix ("Hopper" ← "Hopper Disassembler"). Ambiguous:
        /// "Google" ← "Google Chrome" is the vendor's shared directory.
        func prefixClaims(_ name: String) -> Bool {
            app.name.hasPrefix(DiskInstalledAppsSnapshot.normalizeName(name) + " ")
        }

        func add(_ url: URL, reason: String) {
            if ProtectedPaths.isProtectedName(DiskInstalledAppsSnapshot.normalizeName(url.lastPathComponent)) {
                return
            }
            let size = sizer.size(of: url)
            guard size > 0 else { return }
            findings.append(Finding(
                url: url, category: .appLeftovers, sizeBytes: size,
                ruleID: "uninstall-\(target)", reason: reason,
                reversible: true, lastModified: sizer.lastModified(of: url)
            ))
        }

        // 1. Bundle-ID-named directories (incl. group containers).
        let idDirs: [(String, Bool)] = [
            ("Library/Containers", false),
            ("Library/HTTPStorages", false),
            ("Library/WebKit", false),
            ("Library/Application Scripts", false),
            ("Library/Group Containers", true),
        ]
        for (rel, isGroup) in idDirs {
            let root = context.homeDirectory.appendingPathComponent(rel, isDirectory: true)
            guard let children = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for child in children {
                if Self.isSymlink(child) { continue }
                var identifier = child.lastPathComponent
                if isGroup {
                    guard identifier.hasPrefix("group.") else { continue }
                    identifier = String(identifier.dropFirst("group.".count))
                }
                guard AppLeftoversScanner.looksLikeBundleID(identifier), idClaims(identifier)
                else { continue }
                add(child, reason: "\(app.rawName) \(isGroup ? "group container" : "application data") (\(identifier)).")
            }
        }

        // 2. Suffixed entries (preferences, saved state, cookies).
        let suffixed: [(String, [String], String)] = [
            ("Library/Preferences", [".plist.lockfile", ".plist"], "preference file"),
            ("Library/Saved Application State", [".savedState"], "saved application state"),
            ("Library/Cookies", [".binarycookies"], "cookie store"),
        ]
        for (rel, suffixes, kind) in suffixed {
            let root = context.homeDirectory.appendingPathComponent(rel, isDirectory: true)
            guard let children = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for child in children {
                if Self.isSymlink(child) { continue }
                var identifier = child.lastPathComponent
                var matched = false
                for suffix in suffixes where identifier.hasSuffix(suffix) {
                    identifier = String(identifier.dropLast(suffix.count))
                    matched = true
                    break
                }
                guard matched,
                      AppLeftoversScanner.looksLikeBundleID(identifier),
                      idClaims(identifier) else { continue }
                add(child, reason: "\(app.rawName) \(kind) (\(identifier)).")
            }
        }

        // 3. Caches and Logs children (id- or name-claimed).
        for rel in ["Library/Caches", "Library/Logs"] {
            let root = context.homeDirectory.appendingPathComponent(rel, isDirectory: true)
            guard let children = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for child in children {
                if Self.isSymlink(child) { continue }
                let name = child.lastPathComponent
                let claimed = AppLeftoversScanner.looksLikeBundleID(name) && idClaims(name)
                    || nameClaims(name)
                guard claimed else { continue }
                add(child, reason: "\(app.rawName) cache/log data (\(name)).")
            }
        }

        // 4. Application Support — name claims with vendor-split.
        let asRoot = context.homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        if let children = try? fm.contentsOfDirectory(
            at: asRoot, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for child in children {
                if Self.isSymlink(child) { continue }
                guard Self.isDirectory(child) else { continue }
                let name = child.lastPathComponent
                guard let subentries = try? fm.contentsOfDirectory(
                    at: child, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                let subdirs = subentries.filter { !Self.isSymlink($0) && Self.isDirectory($0) }
                let claimed = nameClaims(name)
                    || (AppLeftoversScanner.looksLikeBundleID(name) && idClaims(name))
                    || (prefixClaims(name) && subdirs.isEmpty)
                if claimed {
                    // Never take a subtree that contains someone's .app bundle.
                    if AppLeftoversScanner.firstAppBundle(in: child) == nil {
                        add(child, reason: "\(app.rawName) application support data.")
                    }
                    continue
                }
                // Vendor directory: include only the app's own subdirectories.
                for sub in subdirs {
                    let subName = sub.lastPathComponent
                    let subClaimed = nameClaims(subName)
                        || (AppLeftoversScanner.looksLikeBundleID(subName) && idClaims(subName))
                    guard subClaimed else { continue }
                    if AppLeftoversScanner.firstAppBundle(in: sub) == nil {
                        add(sub, reason: "\(app.rawName) application support data.")
                    }
                }
            }
        }

        // 5. LaunchAgents whose label matches or whose program lives in the bundle.
        let laRoot = context.homeDirectory.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        if let agents = try? fm.contentsOfDirectory(
            at: laRoot, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]
        ) {
            for agent in agents {
                if Self.isSymlink(agent) { continue }
                let name = agent.lastPathComponent
                guard name.hasSuffix(".plist") else { continue }
                let label = String(name.dropLast(".plist".count))
                var claimed = AppLeftoversScanner.looksLikeBundleID(label) && idClaims(label)
                if !claimed, let info = NSDictionary(contentsOf: agent) as? [AnyHashable: Any],
                   let program = BrokenLoginItemsScanner.programPath(of: info) {
                    let expanded = (program as NSString).expandingTildeInPath
                    claimed = expanded == app.url.path
                        || expanded.hasPrefix(app.url.path + "/")
                }
                guard claimed else { continue }
                add(agent, reason: "\(app.rawName) login item.")
            }
        }

        return Plan(app: app, bundleID: target, findings: findings, warnings: warnings)
    }

    // MARK: - Helpers

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
