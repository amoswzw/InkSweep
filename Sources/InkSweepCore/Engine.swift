import AppKit
import Foundation

/// Runs every registered scanner and merges their reports into one. The set of
/// scanners *is* the coverage surface; adding a category means adding a scanner here.
public struct InkSweepEngine: Sendable {
    public let scanners: [Scanner]
    public let knowledgeBase: KnowledgeBase

    public init(scanners: [Scanner], knowledgeBase: KnowledgeBase) {
        self.scanners = scanners
        self.knowledgeBase = knowledgeBase
    }

    public func scan(context: ScanContext) -> ScanReport {
        scan(context: context, progress: nil)
    }

    /// Scan with per-scanner progress: `progress(phase, findingsSoFar)` fires
    /// as each scanner begins, and once more with "done". A sweep that does
    /// real work (app-bundle walks, header reads, tree hashing) should be
    /// *seen* doing it — honest progress, not a fake spinner.
    public func scan(
        context: ScanContext,
        progress: (@Sendable (_ phase: String, _ findingsSoFar: Int) -> Void)?
    ) -> ScanReport {
        var merged = ScanReport()
        var seenPaths = Set<String>()
        var total = 0
        for scanner in scanners {
            progress?(scanner.category.rawValue, total)
            let r = scanner.scan(context: context, knowledgeBase: knowledgeBase)
            // Deduplicate by path: two scanners must never double-count one thing.
            for finding in r.findings where seenPaths.insert(finding.url.path).inserted {
                merged.findings.append(finding)
                total += 1
            }
            merged.warnings.append(contentsOf: r.warnings)
        }
        progress?("done", total)
        merged.findings = Self.droppingNested(merged.findings)
        return merged
    }

    /// Removes findings that lie inside another finding (a whole orphan
    /// container already covers its own caches), so no byte counts twice.
    static func droppingNested(_ findings: [Finding]) -> [Finding] {
        let paths = Set(findings.map { $0.url.standardizedFileURL.path })
        return findings.filter { finding in
            var parent = finding.url.standardizedFileURL.deletingLastPathComponent()
            while parent.path != "/" {
                if paths.contains(parent.path) { return false }
                parent = parent.deletingLastPathComponent()
            }
            return true
        }
    }

    /// The default engine: one rule-based scanner per filesystem-layout category,
    /// the leftover and browser scanners, and the algorithmic large/old-files
    /// scanner, over the seeded knowledge base. Dependencies are injectable so
    /// tests get a deterministic installed-app universe.
    public static func standard(
        installed: InstalledAppsSnapshot = DiskInstalledAppsSnapshot(),
        runningBundleIDs: @escaping @Sendable () -> Set<String> = {
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        }
    ) -> InkSweepEngine {
        let ruleCategories: [JunkCategory] = [.userCaches, .systemLogs, .systemJunk, .trash, .developerJunk]
        var scanners: [Scanner] = ruleCategories.map { RuleBasedScanner(category: $0) }
        scanners.append(ChromiumCacheScanner())
        scanners.append(ContainerCachesScanner())
        scanners.append(AppLeftoversScanner(installed: installed))
        scanners.append(BrokenLoginItemsScanner())
        scanners.append(BrowserDataScanner(installed: installed, runningBundleIDs: runningBundleIDs))
        scanners.append(MailAttachmentsScanner(runningBundleIDs: runningBundleIDs))
        scanners.append(TestDebrisScanner())
        // The heavy app-bundle walks come late, so the progress readout moves
        // through the fast phases first and the long tail is visible.
        scanners.append(UniversalBinaryScanner())
        scanners.append(LanguageFilesScanner())
        scanners.append(DeviceFirmwareScanner())
        scanners.append(StaleSavedStateScanner())
        scanners.append(BrokenPreferencesScanner())
        scanners.append(InstallerFilesScanner())
        scanners.append(ProjectArtifactsScanner())
        scanners.append(LargeOldFilesScanner())
        return InkSweepEngine(scanners: scanners, knowledgeBase: .seed)
    }
}
