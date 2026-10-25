import AppKit
import Foundation

/// Regenerable caches of every Chromium-based browser and Electron app,
/// found by structure rather than by a per-app list: a user-data directory
/// is any folder under Application Support holding Chromium's `Local State`
/// file; its profiles hold `Preferences`. Only folders Chromium itself
/// treats as caches are proposed — never Local Storage, IndexedDB, cookies
/// or history (privacy cleaning is BrowserDataScanner's job).
///
/// Per-app lists exist elsewhere; the structural match covers apps no list has.
public struct ChromiumCacheScanner: Scanner {
    public let category: JunkCategory = .userCaches

    static let appLevelCaches = [
        "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
        "GrShaderCache", "GraphiteDawnCache", "ShaderCache", "GPUPersistentCache",
        "component_crx_cache", "extensions_crx_cache", "Crashpad/completed",
        // Electron/VS Code family
        "CachedData", "CachedExtensionVSIXs",
        // Chrome's on-device model downloads (re-downloaded if a feature needs them)
        "OptGuideOnDeviceModel", "OptGuideOnDeviceClassifierModel", "optimization_guide_model_store",
    ]
    static let profileLevelCaches = [
        "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
        "GrShaderCache", "GraphiteDawnCache", "Application Cache",
    ]

    private let runningAppNames: @Sendable () -> Set<String>
    private let sizer: FileTreeSizer

    public init(
        runningAppNames: @escaping @Sendable () -> Set<String> = {
            var names = Set<String>()
            for app in NSWorkspace.shared.runningApplications {
                if let n = app.localizedName { names.insert(DiskInstalledAppsSnapshot.normalizeName(n)) }
                if let u = app.bundleURL {
                    names.insert(DiskInstalledAppsSnapshot.normalizeName(u.deletingPathExtension().lastPathComponent))
                }
            }
            return names
        },
        sizer: FileTreeSizer = FileTreeSizer()
    ) {
        self.runningAppNames = runningAppNames
        self.sizer = sizer
    }

    public func scan(context: ScanContext, knowledgeBase: KnowledgeBase) -> ScanReport {
        var report = ScanReport()
        let home = context.homeDirectory
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let running = runningAppNames()

        for userData in Self.userDataDirectories(under: support) {
            if ProtectedPaths.cleanupProtection(for: userData, home: home) != nil { continue }
            let names = userData.path.dropFirst(support.path.count + 1).split(separator: "/").map(String.init)
            let label = names.joined(separator: " ")
            if Self.isLocked(userData) || Self.isRunning(names, running: running) {
                report.warnings.append("\(label) is running — its caches were skipped. Quit it and scan again.")
                continue
            }
            var targets = Self.appLevelCaches.map { userData.appendingPathComponent($0) }
            if FileManager.default.fileExists(atPath: userData.appendingPathComponent("CachedData").path) {
                targets.append(userData.appendingPathComponent("logs"))
            }
            for profile in Self.profiles(in: userData) {
                targets += Self.profileLevelCaches.map { profile.appendingPathComponent($0) }
            }
            for target in targets {
                add(target, app: label, home: home, into: &report)
            }
        }
        return report
    }

    private func add(_ url: URL, app: String, home: URL, into report: inout ScanReport) {
        guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              v.isDirectory == true, v.isSymbolicLink != true,
              ProtectedPaths.cleanupProtection(for: url, home: home) == nil else { return }
        let size = sizer.size(of: url)
        guard size > 0 else { return }
        report.findings.append(Finding(
            url: url, category: .userCaches, sizeBytes: size, ruleID: "chromium-cache",
            reason: "\(app) \(url.lastPathComponent) — Chromium regenerates it on next launch.",
            reversible: true, lastModified: sizer.lastModified(of: url)))
    }

    /// Folders holding a `Local State` file, up to three levels below `root`
    /// ("Claude", "Google/Chrome", "Arc/User Data"). Symlinks are not followed.
    static func userDataDirectories(under root: URL) -> [URL] {
        var found: [URL] = []
        var frontier = [root]
        for _ in 0..<3 {
            var next: [URL] = []
            for dir in frontier {
                for child in directories(in: dir) {
                    if FileManager.default.fileExists(atPath: child.appendingPathComponent("Local State").path) {
                        found.append(child)
                    } else {
                        next.append(child)
                    }
                }
            }
            frontier = next
        }
        return found
    }

    static func profiles(in userData: URL) -> [URL] {
        directories(in: userData).filter {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Preferences").path)
        }
    }

    /// Chromium holds `SingletonLock` (a symlink) for as long as it runs.
    static func isLocked(_ userData: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(
            atPath: userData.appendingPathComponent("SingletonLock").path)) != nil
    }

    static func isRunning(_ names: [String], running: Set<String>) -> Bool {
        let normalized = names.map(DiskInstalledAppsSnapshot.normalizeName)
        let candidates = Set(normalized + [normalized.joined(separator: " ")])
            .subtracting(["user data"])
        return !candidates.isDisjoint(with: running)
    }

    private static func directories(in url: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return children.filter {
            let v = try? $0.resourceValues(forKeys: Set(keys))
            return v?.isDirectory == true && v?.isSymbolicLink != true
        }
    }
}
