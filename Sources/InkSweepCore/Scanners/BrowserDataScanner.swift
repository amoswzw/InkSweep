import AppKit
import Foundation

/// Privacy cleaning across the major browsers — an original rule set grounded
/// in each browser's public profile layout. History, cookies and download
/// lists are reported as individually removable files.
///
/// Two deliberate safety policies:
/// - A browser that is currently running is skipped entirely (its databases
///   are open; removing files under a live browser corrupts profiles). A
///   warning tells the user to quit it and re-scan.
/// - Files that mix junk with precious data are never proposed. Firefox's
///   `places.sqlite` holds history *and bookmarks*, so only its cookie store
///   is handled. This trades a little coverage for zero data-loss risk.
public struct BrowserDataScanner: Scanner {
    public let category: JunkCategory = .browserData

    private enum ProfileStyle: Sendable {
        case chromium     // "Default", "Profile 1", …
        case everyChild   // Firefox: "<hash>.default-release", …
    }

    private struct Family: Sendable {
        let name: String
        let bundleID: String
        let profileParent: String?  // relative to home
        let profileStyle: ProfileStyle
        let profileFiles: [(path: String, label: String)]
        let standaloneFiles: [(path: String, label: String)]  // relative to home
    }

    private static let chromiumProfileFiles: [(path: String, label: String)] = [
        ("History", "browsing history"),
        ("Cookies", "cookies"),
        ("Network/Cookies", "cookies"),
        ("Top Sites", "top sites"),
        ("Visited Links", "visited links"),
    ]

    private static let families: [Family] = [
        Family(
            name: "Safari", bundleID: "com.apple.Safari",
            profileParent: nil, profileStyle: .everyChild, profileFiles: [],
            standaloneFiles: [
                ("Library/Safari/History.db", "browsing history"),
                ("Library/Safari/Downloads.plist", "downloads list"),
                ("Library/Safari/Cookies/Cookies.binarycookies", "cookies"),
            ]
        ),
        Family(
            name: "Google Chrome", bundleID: "com.google.Chrome",
            profileParent: "Library/Application Support/Google/Chrome",
            profileStyle: .chromium,
            profileFiles: Self.chromiumProfileFiles, standaloneFiles: []
        ),
        Family(
            name: "Microsoft Edge", bundleID: "com.microsoft.edgemac",
            profileParent: "Library/Application Support/Microsoft Edge",
            profileStyle: .chromium,
            profileFiles: Self.chromiumProfileFiles, standaloneFiles: []
        ),
        Family(
            name: "Brave", bundleID: "com.brave.Browser",
            profileParent: "Library/Application Support/BraveSoftware/Brave-Browser",
            profileStyle: .chromium,
            profileFiles: Self.chromiumProfileFiles, standaloneFiles: []
        ),
        Family(
            name: "Arc", bundleID: "company.thebrowser.Browser",
            profileParent: "Library/Application Support/Arc/User Data",
            profileStyle: .chromium,
            profileFiles: Self.chromiumProfileFiles, standaloneFiles: []
        ),
        Family(
            name: "Firefox", bundleID: "org.mozilla.firefox",
            profileParent: "Library/Application Support/Firefox/Profiles",
            profileStyle: .everyChild,
            profileFiles: [
                ("cookies.sqlite", "cookies"),
            ],
            standaloneFiles: []
        ),
    ]

    private let loweredIDs: Set<String>
    private let runningBundleIDs: @Sendable () -> Set<String>
    private let sizer: FileTreeSizer

    public init(
        installed: InstalledAppsSnapshot = DiskInstalledAppsSnapshot(),
        runningBundleIDs: @escaping @Sendable () -> Set<String> = {
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        },
        sizer: FileTreeSizer = FileTreeSizer()
    ) {
        self.loweredIDs = Set(installed.bundleIDs.map { $0.lowercased() })
        self.runningBundleIDs = runningBundleIDs
        self.sizer = sizer
    }

    public func scan(context: ScanContext, knowledgeBase: KnowledgeBase) -> ScanReport {
        var report = ScanReport()
        let fm = FileManager.default
        let home = context.homeDirectory
        let running = runningBundleIDs()

        for family in Self.families {
            // An uninstalled browser's data is a job for AppLeftoversScanner,
            // not for privacy cleaning of a browser still in use. (Bundle IDs
            // compare case-insensitively.)
            guard loweredIDs.contains(family.bundleID.lowercased()) else { continue }
            if running.contains(family.bundleID) {
                report.warnings.append(
                    "\(family.name) is running — its data was skipped. Quit it and scan again."
                )
                continue
            }

            if family.name == "Safari" {
                // ~/Library/Safari is TCC-protected: distinguish "absent" from
                // "unreadable" so the user learns they need Full Disk Access.
                let safariRoot = home.appendingPathComponent("Library/Safari", isDirectory: true)
                do {
                    _ = try fm.contentsOfDirectory(at: safariRoot, includingPropertiesForKeys: nil)
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                    continue  // Safari data absent
                } catch {
                    report.warnings.append(
                        "Safari data is unreadable — grant Full Disk Access and scan again."
                    )
                    continue
                }
            }

            for (relative, label) in family.standaloneFiles {
                addWithSidecars(
                    home.appendingPathComponent(relative),
                    family: family, profile: nil, label: label, into: &report
                )
            }

            if let parentRel = family.profileParent {
                let parent = home.appendingPathComponent(parentRel, isDirectory: true)
                guard let profiles = try? fm.contentsOfDirectory(
                    at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for profile in profiles {
                    if Self.isSymbolicLink(profile) { continue }
                    guard Self.isDirectory(profile) else { continue }
                    let name = profile.lastPathComponent
                    switch family.profileStyle {
                    case .chromium:
                        guard name == "Default" || name.hasPrefix("Profile ") else { continue }
                    case .everyChild:
                        break
                    }
                    for (fileRel, label) in family.profileFiles {
                        addWithSidecars(
                            profile.appendingPathComponent(fileRel),
                            family: family, profile: name, label: label, into: &report
                        )
                    }
                }
            }
        }
        return report
    }

    /// The database plus whichever SQLite sidecars exist — but only when the
    /// database itself is present; an orphan sidecar is left alone.
    private func addWithSidecars(
        _ url: URL, family: Family, profile: String?, label: String,
        into report: inout ScanReport
    ) {
        let before = report.findings.count
        addIfPresent(url, family: family, profile: profile, label: label, into: &report)
        guard report.findings.count > before else { return }
        for suffix in ["-journal", "-wal", "-shm"] {
            let sidecar = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + suffix)
            addIfPresent(sidecar, family: family, profile: profile, label: label + " journal", into: &report)
        }
    }

    private func addIfPresent(
        _ url: URL, family: Family, profile: String?, label: String,
        into report: inout ScanReport
    ) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return }
        let size = sizer.size(of: url)
        guard size > 0 else { return }
        let scope = profile.map { " (profile \($0))" } ?? ""
        report.findings.append(Finding(
            url: url,
            category: .browserData,
            sizeBytes: size,
            ruleID: "browser-\(family.bundleID)",
            reason: "\(family.name) \(label)\(scope)",
            reversible: true,
            lastModified: sizer.lastModified(of: url)
        ))
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
