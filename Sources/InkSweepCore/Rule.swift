import Foundation

/// Where a rule is anchored. Resolved against a `ScanContext` so tests can point
/// "home" at a temporary fixture instead of the real user directory.
public enum RuleRoot: Sendable, Codable, Equatable {
    case home(String)          // path relative to the user's home directory
    case absolute(String)      // fixed absolute path
    /// Home-relative path whose components may hold `*`/`?` globs. Matching
    /// never follows symlinks and `*` never matches a leading dot.
    case homePattern(String)
}

/// How a rule turns its root into findings.
public enum ScanStrategy: Sendable, Codable, Equatable {
    /// Each immediate child of the root directory is a finding (e.g. per-app cache folders).
    case childrenOfDirectory
    /// The root directory's contents collapse into one finding for the directory itself.
    case directoryItself
}

/// Provenance: why we believe this location is safe to clean. Every rule carries one,
/// so the dataset is auditable and can be defended without reference to any competitor.
public struct Provenance: Sendable, Codable, Equatable {
    public let source: String      // e.g. "Apple File System Programming Guide"
    public let note: String        // why removal here is safe / what regenerates it
    public init(source: String, note: String) {
        self.source = source
        self.note = note
    }
}

public struct Rule: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let category: JunkCategory
    public let root: RuleRoot
    public let strategy: ScanStrategy
    public let reason: String
    public let provenance: Provenance
    /// Whether a clean can act on this rule's findings. Root-owned locations
    /// (/Library/…) are reported as analysis until the privileged helper exists.
    public let reversible: Bool
    /// The rule is skipped while any of these runs: executable names, or
    /// bundle IDs (a trailing `*` matches a prefix). Moving a cache out from
    /// under its owner mid-write can corrupt it.
    public let ownerProcesses: [String]
    public let ownerBundleIDs: [String]

    public init(
        id: String,
        category: JunkCategory,
        root: RuleRoot,
        strategy: ScanStrategy,
        reason: String,
        provenance: Provenance,
        reversible: Bool = true,
        ownerProcesses: [String] = [],
        ownerBundleIDs: [String] = []
    ) {
        self.id = id
        self.category = category
        self.root = root
        self.strategy = strategy
        self.reason = reason
        self.provenance = provenance
        self.reversible = reversible
        self.ownerProcesses = ownerProcesses
        self.ownerBundleIDs = ownerBundleIDs
    }

    /// The first owner found running, or nil.
    public func runningOwner(in processes: ProcessSnapshot) -> String? {
        if let name = ownerProcesses.first(where: { processes.executableNames.contains($0.lowercased()) }) {
            return name
        }
        for pattern in ownerBundleIDs.map({ $0.lowercased() }) {
            let hit = pattern.hasSuffix("*")
                ? processes.bundleIDs.contains { $0.hasPrefix(String(pattern.dropLast())) }
                : processes.bundleIDs.contains(pattern)
            if hit { return pattern }
        }
        return nil
    }
}

/// A versioned, provenance-tracked collection of rules. This is the dataset that
/// coverage is measured against; it grows without code changes.
public struct KnowledgeBase: Sendable, Codable {
    public let version: Int
    public let rules: [Rule]

    public init(version: Int, rules: [Rule]) {
        self.version = version
        self.rules = rules
    }

    public func rules(for category: JunkCategory) -> [Rule] {
        rules.filter { $0.category == category }
    }
}

/// Everything a scan needs from its environment. Injectable so scans are testable
/// and deterministic: point `homeDirectory` at a fixture and the whole engine follows.
public struct ScanContext: Sendable {
    public var homeDirectory: URL
    public var now: Date
    /// Where installed `.app` bundles live. Injectable so tests never read
    /// the host's /Applications.
    public var applicationRoots: [URL]

    public init(homeDirectory: URL, now: Date = Date(), applicationRoots: [URL]? = nil) {
        self.homeDirectory = homeDirectory
        self.now = now
        self.applicationRoots = applicationRoots ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Library/Input Methods", isDirectory: true),
            homeDirectory.appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    public func resolve(_ root: RuleRoot) -> URL {
        switch root {
        case .home(let rel), .homePattern(let rel):
            return homeDirectory.appendingPathComponent(rel, isDirectory: true)
        case .absolute(let path):
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    /// Every existing, non-symlinked directory the root names.
    public func resolveAll(_ root: RuleRoot) -> [URL] {
        guard case .homePattern(let pattern) = root else { return [resolve(root)] }
        var current = [homeDirectory]
        let fm = FileManager.default
        for component in pattern.split(separator: "/").map(String.init) {
            var next: [URL] = []
            for dir in current {
                if component.contains("*") || component.contains("?") {
                    guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
                    for name in names.sorted() where fnmatch(component, name, FNM_PERIOD) == 0 {
                        next.append(dir.appendingPathComponent(name, isDirectory: true))
                    }
                } else {
                    next.append(dir.appendingPathComponent(component, isDirectory: true))
                }
            }
            current = next.filter { url in
                guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
                return v.isDirectory == true && v.isSymbolicLink != true
            }
        }
        return current
    }
}
