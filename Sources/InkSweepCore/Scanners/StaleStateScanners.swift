import Foundation

/// Window-restoration state of apps not reopened for 30 days. Losing it
/// only means the app opens with fresh windows.
public struct StaleSavedStateScanner: Scanner {
    public let category: JunkCategory = .userCaches
    public let minimumAge: TimeInterval
    private let sizer: FileTreeSizer

    public init(minimumAge: TimeInterval = 30 * 86_400, sizer: FileTreeSizer = FileTreeSizer()) {
        self.minimumAge = minimumAge
        self.sizer = sizer
    }

    public func scan(context: ScanContext, knowledgeBase: KnowledgeBase) -> ScanReport {
        var report = ScanReport()
        let root = context.homeDirectory.appendingPathComponent("Library/Saved Application State", isDirectory: true)
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .contentModificationDateKey]
        for state in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys)) ?? []
        where state.pathExtension == "savedState" {
            guard let v = try? state.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true,
                  let modified = v.contentModificationDate,
                  context.now.timeIntervalSince(modified) >= minimumAge,
                  ProtectedPaths.cleanupProtection(for: state, home: context.homeDirectory) == nil else { continue }
            let size = sizer.size(of: state)
            guard size > 0 else { continue }
            report.findings.append(Finding(
                url: state, category: .userCaches, sizeBytes: size, ruleID: "stale-saved-state",
                reason: "Window state untouched for \(Int(context.now.timeIntervalSince(modified) / 86_400)) days — the app just opens fresh windows.",
                reversible: true, lastModified: modified))
        }
        return report
    }
}

/// Preference files that exist and can be read but are not valid property
/// lists — the app already cannot use them. An unreadable file is unknown,
/// not broken, and stays; so do Apple's and sensitive vendors' files.
public struct BrokenPreferencesScanner: Scanner {
    public let category: JunkCategory = .appLeftovers

    public init() {}

    public func scan(context: ScanContext, knowledgeBase: KnowledgeBase) -> ScanReport {
        var report = ScanReport()
        let root = context.homeDirectory.appendingPathComponent("Library/Preferences", isDirectory: true)
        for file in (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
        where file.pathExtension == "plist" {
            let stem = file.deletingPathExtension().lastPathComponent
            guard let v = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  v.isRegularFile == true, v.isSymbolicLink != true,
                  !ProtectedPaths.isAppleNamespace(stem),
                  ProtectedPaths.cleanupProtection(for: file, home: context.homeDirectory) == nil,
                  let data = try? Data(contentsOf: file) else { continue }
            if (try? PropertyListSerialization.propertyList(from: data, format: nil)) != nil { continue }
            report.findings.append(Finding(
                url: file, category: .appLeftovers, sizeBytes: Int64(max(data.count, 1)), ruleID: "broken-preferences",
                reason: "Corrupt preference file — not a valid property list; the app recreates its defaults.",
                reversible: true, lastModified: nil))
        }
        return report
    }
}
