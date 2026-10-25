import Foundation

/// A node in a sized directory tree (Space Lens data model).
public struct SpaceNode: Codable, Sendable, Hashable, Identifiable {
    public let id: String          // absolute path
    public let name: String
    public let url: URL
    public let sizeBytes: Int64
    public let isDirectory: Bool
    public let children: [SpaceNode]?

    public init(id: String, name: String, url: URL, sizeBytes: Int64,
                isDirectory: Bool, children: [SpaceNode]?) {
        self.id = id
        self.name = name
        self.url = url
        self.sizeBytes = sizeBytes
        self.isDirectory = isDirectory
        self.children = children
    }
}

/// Builds a pruned, sized directory tree for the Space Lens visualization —
/// the disk-usage explorer capability. Bottom-up sizes (allocated bytes,
/// symlinks never followed), children pruned to the largest `maxChildren`
/// per level and `maxDepth` levels deep, so the UI gets a bounded
/// representation of any tree, however large.
public struct SpaceLensScanner: Sendable {
    public let maxDepth: Int
    public let maxChildren: Int

    public init(maxDepth: Int = 3, maxChildren: Int = 12) {
        self.maxDepth = maxDepth
        self.maxChildren = maxChildren
    }

    private static let sizeKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
    ]

    public func tree(root: URL) -> SpaceNode {
        node(for: root, depth: 0)
    }

    private func node(for url: URL, depth: Int) -> SpaceNode {
        let fm = FileManager.default
        guard let v = try? url.resourceValues(forKeys: Self.sizeKeys) else {
            return SpaceNode(id: url.path, name: url.lastPathComponent, url: url,
                             sizeBytes: 0, isDirectory: false, children: nil)
        }
        if v.isSymbolicLink == true {
            // A link contributes its own (tiny) size, never its target's.
            let size = Int64(v.fileAllocatedSize ?? v.fileSize ?? 0)
            return SpaceNode(id: url.path, name: url.lastPathComponent, url: url,
                             sizeBytes: size, isDirectory: false, children: nil)
        }
        guard v.isDirectory == true else {
            let size = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? v.fileSize ?? 0)
            return SpaceNode(id: url.path, name: url.lastPathComponent, url: url,
                             sizeBytes: size, isDirectory: false, children: nil)
        }

        guard let children = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(Self.sizeKeys), options: []
        ) else {
            return SpaceNode(id: url.path, name: url.lastPathComponent, url: url,
                             sizeBytes: 0, isDirectory: true, children: nil)
        }

        // Hidden entries are part of the truth; keep them (a lens that lies
        // about disk usage is useless). TCC-blocked children read as absent.
        var childNodes: [SpaceNode] = []
        for child in children {
            childNodes.append(depth < maxDepth
                              ? node(for: child, depth: depth + 1)
                              : leafNode(for: child))
        }
        let total = childNodes.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let pruned = Array(childNodes.sorted { $0.sizeBytes > $1.sizeBytes }.prefix(maxChildren))
        return SpaceNode(
            id: url.path,
            name: url.lastPathComponent,
            url: url,
            sizeBytes: total,
            isDirectory: true,
            children: pruned.isEmpty ? nil : pruned
        )
    }

    /// At the depth cap we still need sizes, just no further recursion.
    private func leafNode(for url: URL) -> SpaceNode {
        guard let v = try? url.resourceValues(forKeys: Self.sizeKeys) else {
            return SpaceNode(id: url.path, name: url.lastPathComponent, url: url,
                             sizeBytes: 0, isDirectory: false, children: nil)
        }
        if v.isSymbolicLink == true {
            return SpaceNode(id: url.path, name: url.lastPathComponent, url: url,
                             sizeBytes: Int64(v.fileAllocatedSize ?? v.fileSize ?? 0),
                             isDirectory: false, children: nil)
        }
        if v.isDirectory == true {
            // One shallow pass to sum direct children without recursion.
            let fm = FileManager.default
            let children = (try? fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: Array(Self.sizeKeys), options: [])) ?? []
            let total = children.reduce(Int64(0)) {
                guard let cv = try? $1.resourceValues(forKeys: Self.sizeKeys) else { return $0 }
                if cv.isSymbolicLink == true { return $0 }
                return $0 + Int64(cv.totalFileAllocatedSize ?? cv.fileAllocatedSize ?? cv.fileSize ?? 0)
            }
            return SpaceNode(id: url.path, name: url.lastPathComponent, url: url,
                             sizeBytes: total, isDirectory: true, children: nil)
        }
        return SpaceNode(id: url.path, name: url.lastPathComponent, url: url,
                         sizeBytes: Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? v.fileSize ?? 0),
                         isDirectory: false, children: nil)
    }
}
