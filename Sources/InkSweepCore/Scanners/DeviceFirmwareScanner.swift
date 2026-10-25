import Foundation

/// iOS/iPadOS restore images (.ipsw) cached by Finder and Apple
/// Configurator. Apple re-downloads them on the next restore or update; a
/// file touched within the last hour may still be downloading, so it stays.
public struct DeviceFirmwareScanner: Scanner {
    public let category: JunkCategory = .userCaches

    static let itunesFolders = ["iPhone Software Updates", "iPad Software Updates",
                                "iPod Software Updates", "Apple TV Software Updates"]
    private let sizer: FileTreeSizer

    public init(sizer: FileTreeSizer = FileTreeSizer()) {
        self.sizer = sizer
    }

    public func scan(context: ScanContext, knowledgeBase: KnowledgeBase) -> ScanReport {
        var report = ScanReport()
        let home = context.homeDirectory
        var roots = Self.itunesFolders.map { home.appendingPathComponent("Library/iTunes/\($0)") }
        roots += context.resolveAll(.homePattern("Library/Group Containers/*.group.com.apple.configurator"))
        for root in roots {
            guard let e = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in e where url.pathExtension.lowercased() == "ipsw" {
                guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                      v.isRegularFile == true, v.isSymbolicLink != true,
                      context.now.timeIntervalSince(v.contentModificationDate ?? context.now) >= 3_600 else { continue }
                let size = sizer.size(of: url)
                guard size > 0 else { continue }
                report.findings.append(Finding(
                    url: url, category: .userCaches, sizeBytes: size, ruleID: "device-firmware",
                    reason: "Cached device restore image — Apple downloads it again when a device needs it.",
                    reversible: true, lastModified: v.contentModificationDate))
            }
        }
        return report
    }
}
