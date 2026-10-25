import Foundation

/// A category of removable item. The taxonomy is the coverage contract:
/// every scanner declares the category it contributes to, and "nothing is
/// missed" is measured per category against an external baseline.
public enum JunkCategory: String, Codable, CaseIterable, Sendable {
    case userCaches
    case systemLogs
    case systemJunk
    case trash
    case browserData
    case appLeftovers
    case developerJunk
    case largeOldFiles
    case mailAttachments
    case installerFiles
    case projectArtifacts
}

/// One concrete thing found on disk that the engine proposes to remove.
public struct Finding: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let url: URL
    public let category: JunkCategory
    public let sizeBytes: Int64
    public let ruleID: String
    /// Human-readable justification, surfaced in the UI so a removal is never opaque.
    public let reason: String
    /// True when it can be cleaned by moving it to the Trash (recoverable).
    /// False means analysis-only: no reversible removal exists yet, and
    /// `Cleaner` refuses it.
    public let reversible: Bool
    public let lastModified: Date?

    public init(
        url: URL,
        category: JunkCategory,
        sizeBytes: Int64,
        ruleID: String,
        reason: String,
        reversible: Bool = true,
        lastModified: Date? = nil
    ) {
        self.id = url.path
        self.url = url
        self.category = category
        self.sizeBytes = sizeBytes
        self.ruleID = ruleID
        self.reason = reason
        self.reversible = reversible
        self.lastModified = lastModified
    }
}

/// The result of a scan pass: findings plus any non-fatal problems hit while scanning.
public struct ScanReport: Codable, Sendable {
    public var findings: [Finding]
    public var warnings: [String]

    public init(findings: [Finding] = [], warnings: [String] = []) {
        self.findings = findings
        self.warnings = warnings
    }

    public var totalBytes: Int64 { findings.reduce(0) { $0 + $1.sizeBytes } }

    public func findings(in category: JunkCategory) -> [Finding] {
        findings.filter { $0.category == category }
    }

    public func bytes(in category: JunkCategory) -> Int64 {
        findings(in: category).reduce(0) { $0 + $1.sizeBytes }
    }

    public var bytesByCategory: [JunkCategory: Int64] {
        var out: [JunkCategory: Int64] = [:]
        for f in findings { out[f.category, default: 0] += f.sizeBytes }
        return out
    }

    /// Findings that are safe to hand to the Cleaner (Trash-able).
    /// Analysis-only findings — lipo waste, extra language files, anything
    /// that needs the privileged helper — deliberately stay out.
    public var cleanableFindings: [Finding] {
        findings.filter { $0.reversible }
    }

    /// Bytes reported by analysis-only findings (informational, not cleanable).
    public var analysisOnlyBytes: Int64 {
        findings.filter { !$0.reversible }.reduce(0) { $0 + $1.sizeBytes }
    }
}

/// A record of what a clean actually did to one finding, so it can be reported and undone.
public struct CleanReceipt: Sendable {
    public enum Outcome: Sendable, Equatable {
        case trashed(resultingURL: URL?)
        /// Permanently removed — only `TrashEmptier` produces this.
        case deleted
        case skippedDryRun
        case failed(String)
    }
    public let finding: Finding
    public let outcome: Outcome

    public init(finding: Finding, outcome: Outcome) {
        self.finding = finding
        self.outcome = outcome
    }

    public var reclaimedBytes: Int64 {
        switch outcome {
        case .trashed, .deleted: return finding.sizeBytes
        case .skippedDryRun, .failed: return 0
        }
    }
}
