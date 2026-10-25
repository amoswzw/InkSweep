import Foundation

/// A unit of coverage. Each scanner owns one category and produces findings.
public protocol Scanner: Sendable {
    var category: JunkCategory { get }
    func scan(context: ScanContext, knowledgeBase: KnowledgeBase) -> ScanReport
}

/// Drives any rule whose findings come straight from the filesystem layout
/// (caches, logs, trash). Algorithmic scanners that don't map to a fixed root
/// (large/old files, leftovers) implement `Scanner` directly instead.
public struct RuleBasedScanner: Scanner {
    public let category: JunkCategory
    private let sizer: FileTreeSizer
    private let processes: @Sendable () -> ProcessSnapshot

    public init(category: JunkCategory, sizer: FileTreeSizer = FileTreeSizer(),
                processes: @escaping @Sendable () -> ProcessSnapshot = { .current() }) {
        self.category = category
        self.sizer = sizer
        self.processes = processes
    }

    public func scan(context: ScanContext, knowledgeBase: KnowledgeBase) -> ScanReport {
        var report = ScanReport()
        let rules = knowledgeBase.rules(for: category)
        let running = rules.contains { !$0.ownerProcesses.isEmpty || !$0.ownerBundleIDs.isEmpty }
            ? processes() : .empty
        var unreadable: [String] = []
        for rule in rules {
            let roots = context.resolveAll(rule.root)
            if !roots.isEmpty, let owner = rule.runningOwner(in: running) {
                report.warnings.append("\(rule.reason) Skipped — \(owner) is running. Quit it and scan again.")
                continue
            }
            for root in roots where !scan(root: root, rule: rule, home: context.homeDirectory, into: &report) {
                unreadable.append(root.path.replacingOccurrences(of: context.homeDirectory.path, with: "~"))
            }
        }
        if !unreadable.isEmpty {
            let shown = unreadable.prefix(3).joined(separator: ", ") + (unreadable.count > 3 ? ", …" : "")
            report.warnings.append("\(unreadable.count) protected location\(unreadable.count == 1 ? " was" : "s were") unreadable (\(shown)) — grant Full Disk Access to include them.")
        }
        return report
    }

    /// False when the root exists but could not be listed.
    @discardableResult
    private func scan(root: URL, rule: Rule, home: URL, into report: inout ScanReport) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return true  // location simply absent on this machine — not a warning
        }
        switch rule.strategy {
        case .directoryItself:
            guard ProtectedPaths.cleanupProtection(for: root, home: home) == nil else { return true }
            addFinding(for: root, rule: rule, into: &report)
        case .childrenOfDirectory:
            guard let children = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []
            ) else {
                return false
            }
            for child in children {
                let isLink = (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
                if isLink { continue }
                if ProtectedPaths.cleanupProtection(for: child, home: home) != nil { continue }
                addFinding(for: child, rule: rule, into: &report)
            }
        }
        return true
    }

    private func addFinding(for url: URL, rule: Rule, into report: inout ScanReport) {
        let size = sizer.size(of: url)
        guard size > 0 else { return }
        report.findings.append(Finding(
            url: url,
            category: rule.category,
            sizeBytes: size,
            ruleID: rule.id,
            reason: rule.reason,
            reversible: rule.reversible,
            lastModified: sizer.lastModified(of: url)
        ))
    }
}
