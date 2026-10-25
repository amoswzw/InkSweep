import AppKit
import Foundation

/// Mail attachment blobs under `~/Library/Mail` (the MailJunkScanning
/// capability). Reports files living in "Attachments" subtrees above a size
/// threshold. Mail must be closed so the store isn't modified under it.
/// For IMAP/Exchange accounts Mail re-downloads a removed attachment on
/// demand; for POP or "On My Mac" mail the Trash copy is the only copy.
public struct MailAttachmentsScanner: Scanner {
    public let category: JunkCategory = .mailAttachments

    public static let mailBundleID = "com.apple.mail"

    public let minimumSizeBytes: Int64
    private let runningBundleIDs: @Sendable () -> Set<String>
    private let sizer: FileTreeSizer

    public init(
        minimumSizeBytes: Int64 = 1_000_000,
        runningBundleIDs: @escaping @Sendable () -> Set<String> = {
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        },
        sizer: FileTreeSizer = FileTreeSizer()
    ) {
        self.minimumSizeBytes = minimumSizeBytes
        self.runningBundleIDs = runningBundleIDs
        self.sizer = sizer
    }

    public func scan(context: ScanContext, knowledgeBase: KnowledgeBase) -> ScanReport {
        var report = ScanReport()
        let fm = FileManager.default
        let root = context.homeDirectory.appendingPathComponent("Library/Mail", isDirectory: true)

        if runningBundleIDs().contains(Self.mailBundleID) {
            report.warnings.append("Mail is running — attachments were skipped. Quit Mail and scan again.")
            return report
        }

        // ~/Library/Mail is FDA-gated: distinguish "absent" from "unreadable".
        do {
            _ = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return report  // no Mail data on this machine
        } catch {
            report.warnings.append("Mail data is unreadable — grant Full Disk Access and scan again.")
            return report
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return report }

        for case let url as URL in e {
            if Self.isSymbolicLink(url) { continue }
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            guard v.isRegularFile == true else { continue }
            guard url.pathComponents.contains("Attachments") else { continue }
            let size = sizer.size(of: url)
            guard size >= minimumSizeBytes else { continue }
            report.findings.append(Finding(
                url: url,
                category: .mailAttachments,
                sizeBytes: size,
                ruleID: "mail-attachment",
                reason: "Mail attachment (\(size / 1_000_000) MB) — server-backed accounts re-download it; POP/local mail keeps no other copy.",
                reversible: true,
                lastModified: v.contentModificationDate
            ))
        }
        return report
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }
}
