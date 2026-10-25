import CryptoKit
import Foundation

/// One file in a duplicate group.
public struct DuplicateFile: Codable, Sendable, Hashable {
    public let url: URL
    public let sizeBytes: Int64
    public let lastModified: Date?

    public init(url: URL, sizeBytes: Int64, lastModified: Date?) {
        self.url = url
        self.sizeBytes = sizeBytes
        self.lastModified = lastModified
    }
}

/// A set of byte-identical files. The oldest file is the conventionally
/// suggested keeper; the rest is reclaimable.
public struct DuplicateGroup: Codable, Sendable, Identifiable, Hashable {
    public let digest: String
    public let files: [DuplicateFile]

    public init(digest: String, files: [DuplicateFile]) {
        self.digest = digest
        self.files = files
    }

    public var id: String { digest }

    /// Bytes reclaimable if one copy is kept.
    public var wastedBytes: Int64 {
        Int64(max(files.count - 1, 0)) * (files.first?.sizeBytes ?? 0)
    }
}

/// Content-addressed duplicate finder — a capability the original app does
/// NOT ship (its vendor sells it as a separate product). No false positives
/// by construction: files are grouped by size, then by the SHA-256 of their
/// first 64 KB, and only a full-content SHA-256 decides a group.
public struct DuplicateFileScanner: Sendable {
    public let roots: [RuleRoot]
    public let minimumSizeBytes: Int64

    public init(
        roots: [RuleRoot] = [.home("Downloads"), .home("Documents"), .home("Desktop")],
        minimumSizeBytes: Int64 = 1_000_000
    ) {
        self.roots = roots
        self.minimumSizeBytes = minimumSizeBytes
    }

    public func scan(context: ScanContext) -> [DuplicateGroup] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
                                      .fileResourceIdentifierKey]

        // Stage 1: group by exact size. A hard link is the same file under
        // another name — deleting it frees nothing — so each inode counts once.
        var bySize: [Int64: [URL]] = [:]
        var seenFiles = Set<AnyHashable>()
        for root in roots {
            let base = context.resolve(root)
            guard let e = fm.enumerator(
                at: base, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in e {
                if Self.isSymbolicLink(url) { continue }
                guard let v = try? url.resourceValues(forKeys: Set(keys)),
                      v.isRegularFile == true else { continue }
                if let fileID = v.fileResourceIdentifier as? AnyHashable,
                   !seenFiles.insert(fileID).inserted { continue }
                let size = Self.fileSize(of: url)
                guard size >= minimumSizeBytes else { continue }
                bySize[size, default: []].append(url)
            }
        }

        // Stage 2+3: 64-KB prefix hash, then full hash.
        var groups: [DuplicateGroup] = []
        for (size, urls) in bySize where urls.count > 1 {
            var byPrefix: [String: [URL]] = [:]
            for url in urls {
                byPrefix[Self.sha256(url, prefixBytes: 65_536), default: []].append(url)
            }
            for (_, candidates) in byPrefix where candidates.count > 1 {
                var byFull: [String: [URL]] = [:]
                for url in candidates {
                    byFull[Self.sha256(url, prefixBytes: nil), default: []].append(url)
                }
                for (digest, urls) in byFull where urls.count > 1 {
                    let files = urls
                        .map { url in
                            let modified = (try? url.resourceValues(
                                forKeys: [.contentModificationDateKey]))?.contentModificationDate
                            return DuplicateFile(url: url, sizeBytes: size, lastModified: modified)
                        }
                        // oldest first → first is the suggested keeper
                        .sorted { ($0.lastModified ?? .distantPast) < ($1.lastModified ?? .distantPast) }
                    groups.append(DuplicateGroup(digest: digest, files: files))
                }
            }
        }
        return groups.sorted { $0.wastedBytes > $1.wastedBytes }
    }

    // MARK: - Hashing

    private static func sha256(_ url: URL, prefixBytes: Int?) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return "unreadable:" + url.path
        }
        defer { try? handle.close() }
        var sha = SHA256()
        var remaining = prefixBytes ?? Int.max
        while remaining > 0 {
            let n = min(1 << 20, remaining)
            guard let data = try? handle.read(upToCount: n), !data.isEmpty else { break }
            sha.update(data: data)
            remaining -= data.count
        }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fileSize(of url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }
}
