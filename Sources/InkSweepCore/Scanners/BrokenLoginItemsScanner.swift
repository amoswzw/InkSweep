import Foundation

/// Broken login items: user LaunchAgents whose program no longer exists.
/// Full cleaners ship this capability ("Broken Login Items"); a user-space
/// version needs no privileges because `~/Library/LaunchAgents` is
/// user-owned. An agent whose executable is gone is an app-leftover by
/// definition: the owning application was removed but its agent stayed.
///
/// Deliberately conservative:
/// - Only `~/Library/LaunchAgents` (system `/Library/LaunchAgents` and
///   daemons need the deferred privileged helper — root-deferred ledger).
/// - Apple-managed agents are skipped (macOS cleans up after itself).
/// - Agents whose program exists are never flagged, even if their app looks
///   uninstalled — the executable check is the ground truth.
/// - Shell-based agents (`/bin/sh -c …`) are never flagged: the shell exists;
///   chasing their inner script paths is not worth the false-positive risk.
public struct BrokenLoginItemsScanner: Scanner {
    public let category: JunkCategory = .appLeftovers

    private let sizer: FileTreeSizer

    public init(sizer: FileTreeSizer = FileTreeSizer()) {
        self.sizer = sizer
    }

    public func scan(context: ScanContext, knowledgeBase: KnowledgeBase) -> ScanReport {
        var report = ScanReport()
        let fm = FileManager.default
        let root = context.homeDirectory.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        guard let agents = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]
        ) else { return report }  // absent → nothing to do, silently

        for agent in agents {
            if Self.isSymbolicLink(agent) { continue }
            let name = agent.lastPathComponent
            guard name.hasSuffix(".plist") else { continue }
            // Apple-managed agents are system business, not ours.
            if ProtectedPaths.isAppleNamespace(String(name.dropLast(".plist".count))) { continue }
            guard let info = NSDictionary(contentsOf: agent) as? [AnyHashable: Any] else { continue }

            // SMAppService-style agents resolve BundleProgram inside their app.
            if info["BundleProgram"] != nil { continue }
            if let program = Self.programPath(of: info), !program.isEmpty {
                // We only understand absolute program paths; anything else
                // (relative, environment-dependent) is skipped — conservative.
                guard program.hasPrefix("/") else { continue }
                // An unmounted external disk makes a program absent, not gone.
                if program.hasPrefix("/Volumes/") { continue }
                let expanded = (program as NSString).expandingTildeInPath
                var isDir: ObjCBool = false
                let alive = fm.fileExists(atPath: expanded, isDirectory: &isDir) && !isDir.boolValue
                if !alive {
                    addFinding(
                        agent,
                        reason: "Login item points at a missing program (\(program)); its application is gone.",
                        into: &report
                    )
                }
                continue
            }

            // No program at all. XPC-style agents that only register
            // machServices are functional; anything else does literally
            // nothing — empty shell left behind by an uninstaller.
            // (Observed in the wild: Google's Keystone→GoogleUpdater
            // migration leaves three empty <dict/> stub plists behind.)
            let machServices = info["MachServices"] as? [AnyHashable: Any]
            if machServices?.isEmpty == false { continue }
            addFinding(
                agent,
                reason: "Empty login item — launches nothing (no Program, no ProgramArguments, no MachServices); uninstaller debris.",
                into: &report
            )
        }
        return report
    }

    /// The executable an agent plist refers to: `Program`, or the first
    /// `ProgramArguments` element.
    static func programPath(of info: [AnyHashable: Any]) -> String? {
        if let p = info["Program"] as? String { return p }
        if let args = info["ProgramArguments"] as? [Any], let first = args.first as? String {
            return first
        }
        return nil
    }

    private func addFinding(_ url: URL, reason: String, into report: inout ScanReport) {
        let size = sizer.size(of: url)
        guard size > 0 else { return }
        report.findings.append(Finding(
            url: url,
            category: .appLeftovers,
            sizeBytes: size,
            ruleID: "broken-launch-agent",
            reason: reason,
            reversible: true,
            lastModified: sizer.lastModified(of: url)
        ))
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }
}
