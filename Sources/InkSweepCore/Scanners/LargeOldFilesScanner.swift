import Foundation

/// Surfaces big files not touched in a long time. Commercial cleaners offer
/// this capability; a good "surpass" axis: the threshold and age are tunable, and the
/// finding carries its own age so the UI can rank by reclaimable-per-staleness.
public struct LargeOldFilesScanner: Scanner {
    public let category: JunkCategory = .largeOldFiles

    public let searchRoots: [RuleRoot]
    public let minimumSizeBytes: Int64
    public let minimumAge: TimeInterval
    private let sizer: FileTreeSizer

    public init(
        searchRoots: [RuleRoot] = [.home("Downloads"), .home("Documents"), .home("Desktop")],
        minimumSizeBytes: Int64 = 100 * 1024 * 1024,
        minimumAge: TimeInterval = 60 * 60 * 24 * 90,
        sizer: FileTreeSizer = FileTreeSizer()
    ) {
        self.searchRoots = searchRoots
        self.minimumSizeBytes = minimumSizeBytes
        self.minimumAge = minimumAge
        self.sizer = sizer
    }

    public func scan(context: ScanContext, knowledgeBase: KnowledgeBase) -> ScanReport {
        var report = ScanReport()
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]

        for root in searchRoots {
            let base = context.resolve(root)
            guard let e = fm.enumerator(
                at: base,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in e {
                guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if v.isSymbolicLink == true { continue }
                guard v.isRegularFile == true else { continue }
                if let modified = v.contentModificationDate,
                   context.now.timeIntervalSince(modified) < minimumAge { continue }
                let size = sizer.size(of: url)
                guard size >= minimumSizeBytes else { continue }
                let days = Int((context.now.timeIntervalSince(v.contentModificationDate ?? context.now)) / 86_400)
                report.findings.append(Finding(
                    url: url,
                    category: .largeOldFiles,
                    sizeBytes: size,
                    ruleID: "large-old-file",
                    reason: "Large file (\(size / (1024 * 1024)) MB) not modified in \(days) days",
                    reversible: true,
                    lastModified: v.contentModificationDate
                ))
            }
        }
        return report
    }
}
