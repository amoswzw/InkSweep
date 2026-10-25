import Foundation

/// Abstracts the destructive step so tests never touch the real Trash.
public protocol Trasher: Sendable {
    /// Move `url` to the Trash. Returns the resulting in-Trash URL when known.
    func trash(_ url: URL) throws -> URL?
}

/// Real implementation: reversible removal via the Finder Trash.
public struct FileManagerTrasher: Trasher {
    public init() {}
    public func trash(_ url: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }
}

/// Executes a cleanup. `dryRun` is the default: it reports what *would* happen
/// and touches nothing. Nothing here ever calls `removeItem`; removal is always
/// delegated to a `Trasher`, so a clean is recoverable by design.
public struct Cleaner: Sendable {
    private let trasher: Trasher
    public init(trasher: Trasher = FileManagerTrasher()) {
        self.trasher = trasher
    }

    public func clean(_ findings: [Finding], dryRun: Bool = true) -> [CleanReceipt] {
        findings.map { finding in
            // Enforced here, not at call sites: analysis-only findings point at
            // whole app bundles, and one unfiltered caller would trash them.
            guard finding.reversible else {
                return CleanReceipt(finding: finding, outcome: .failed("analysis-only — never cleaned"))
            }
            if Self.isInsideTrash(finding.url) {
                return CleanReceipt(finding: finding, outcome: .failed("already in the Trash — empty the Trash instead"))
            }
            if dryRun {
                return CleanReceipt(finding: finding, outcome: .skippedDryRun)
            }
            do {
                let resulting = try trasher.trash(finding.url)
                return CleanReceipt(finding: finding, outcome: .trashed(resultingURL: resulting))
            } catch {
                return CleanReceipt(finding: finding, outcome: .failed(error.localizedDescription))
            }
        }
    }

    static func isInsideTrash(_ url: URL) -> Bool {
        url.standardizedFileURL.pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
    }
}

/// Emptying the Trash: the one clean action that is irreversible by nature,
/// so it lives apart from `Cleaner` and callers must confirm it explicitly.
/// Only direct children of `trashDirectory` are ever deleted; symlinks are
/// unlinked without touching their targets.
public struct TrashEmptier: Sendable {
    public let trashDirectory: URL

    public init(trashDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".Trash", isDirectory: true)) {
        self.trashDirectory = trashDirectory
    }

    public func empty(_ findings: [Finding], dryRun: Bool = true) -> [CleanReceipt] {
        let trash = trashDirectory.standardizedFileURL.path
        return findings.map { finding in
            guard finding.url.standardizedFileURL.deletingLastPathComponent().path == trash else {
                return CleanReceipt(finding: finding, outcome: .failed("not a Trash item — refused"))
            }
            if dryRun { return CleanReceipt(finding: finding, outcome: .skippedDryRun) }
            do {
                try FileManager.default.removeItem(at: finding.url)
                return CleanReceipt(finding: finding, outcome: .deleted)
            } catch {
                return CleanReceipt(finding: finding, outcome: .failed(error.localizedDescription))
            }
        }
    }
}
