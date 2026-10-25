import Foundation

/// The Caches and tmp folders inside third-party App Sandbox containers.
/// The container layout makes both regenerable by definition; the app's
/// Documents and Application Support stay untouched. Apple's own containers
/// are cleaned only through curated rules, and a running app is skipped.
public struct ContainerCachesScanner: Scanner {
    public let category: JunkCategory = .userCaches

    /// Containers below this much cache are not worth a finding.
    public let minimumContainerBytes: Int64
    private let processes: @Sendable () -> ProcessSnapshot
    private let sizer: FileTreeSizer

    public init(minimumContainerBytes: Int64 = 1_000_000,
                processes: @escaping @Sendable () -> ProcessSnapshot = { .current() },
                sizer: FileTreeSizer = FileTreeSizer()) {
        self.minimumContainerBytes = minimumContainerBytes
        self.processes = processes
        self.sizer = sizer
    }

    public func scan(context: ScanContext, knowledgeBase: KnowledgeBase) -> ScanReport {
        var report = ScanReport()
        let fm = FileManager.default
        let home = context.homeDirectory
        let root = home.appendingPathComponent("Library/Containers", isDirectory: true)
        guard let containers = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles])
        else { return report }
        let running = processes().bundleIDs
        var unreadable = 0

        for container in containers {
            let id = container.lastPathComponent
            if (try? container.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
            if ProtectedPaths.isAppleNamespace(id) { continue }
            if ProtectedPaths.cleanupProtection(for: container, home: home) != nil { continue }
            if running.contains(id.lowercased()) { continue }

            var findings: [Finding] = []
            for sub in ["Data/Library/Caches", "Data/tmp"] {
                let dir = container.appendingPathComponent(sub, isDirectory: true)
                guard fm.fileExists(atPath: dir.path) else { continue }
                guard let children = try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [])
                else { unreadable += 1; continue }
                for child in children {
                    if (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
                    if ProtectedPaths.cleanupProtection(for: child, home: home) != nil { continue }
                    let size = sizer.size(of: child)
                    guard size > 0 else { continue }
                    findings.append(Finding(
                        url: child, category: .userCaches, sizeBytes: size, ruleID: "container-cache",
                        reason: "\(id) sandbox \(sub.hasSuffix("tmp") ? "temporary file" : "cache") — regenerable by the container layout.",
                        reversible: true, lastModified: sizer.lastModified(of: child)))
                }
            }
            if findings.reduce(0, { $0 + $1.sizeBytes }) >= max(minimumContainerBytes, 1) {
                report.findings += findings
            }
        }
        if unreadable > 0 {
            report.warnings.append("\(unreadable) app containers were unreadable — grant Full Disk Access to include their caches.")
        }
        return report
    }
}
