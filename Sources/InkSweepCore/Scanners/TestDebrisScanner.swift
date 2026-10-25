import Foundation

/// XCTest writes a UUID-stamped preference plist per test-run
/// ("FooTests.1A2B3C4D-….plist") and never cleans them up. On a developer
/// machine these accumulate by the hundreds. They are not application data
/// (the app may well be installed) — they are test-run debris, so they get
/// their own detector and reason instead of masquerading as app leftovers.
public struct TestDebrisScanner: Scanner {
    public let category: JunkCategory = .developerJunk

    private let sizer: FileTreeSizer

    public init(sizer: FileTreeSizer = FileTreeSizer()) {
        self.sizer = sizer
    }

    private static let uuidPattern = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"

    /// True when the string embeds a UUID (an identifier component, a file
    /// name, …) — the signature of per-run debris.
    public static func containsUUID(_ s: String) -> Bool {
        s.range(of: uuidPattern, options: .regularExpression) != nil
    }

    public func scan(context: ScanContext, knowledgeBase: KnowledgeBase) -> ScanReport {
        var report = ScanReport()
        let fm = FileManager.default
        let root = context.homeDirectory.appendingPathComponent("Library/Preferences", isDirectory: true)
        guard let children = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []
        ) else { return report }

        for child in children {
            if Self.isSymbolicLink(child) { continue }
            let name = child.lastPathComponent
            guard name.hasSuffix(".plist") || name.hasSuffix(".plist.lockfile") else { continue }
            guard Self.containsUUID(name) else { continue }
            let size = sizer.size(of: child)
            guard size > 0 else { continue }
            report.findings.append(Finding(
                url: child,
                category: .developerJunk,
                sizeBytes: size,
                ruleID: "test-debris",
                reason: "Test-run preference debris (UUID-stamped plist, recreated per test run).",
                reversible: true,
                lastModified: sizer.lastModified(of: child)
            ))
        }
        return report
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }
}
