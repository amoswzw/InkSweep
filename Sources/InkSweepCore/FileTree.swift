import Foundation

/// Measures on-disk size of a file or directory tree.
///
/// Symlinks are never followed: a symlinked directory is counted as the link
/// itself, not its target. That keeps a size measurement (and, later, a removal)
/// from escaping the directory it was asked about.
public struct FileTreeSizer: @unchecked Sendable {
    private let fileManager: FileManager
    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    private static let sizeKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
    ]

    /// Allocated size in bytes. Returns 0 for a missing path.
    public func size(of url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: Self.sizeKeys) else { return 0 }
        if values.isSymbolicLink == true { return 0 }
        if values.isDirectory == true {
            return directorySize(url)
        }
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let children = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(Self.sizeKeys),
            options: []  // do NOT skip anything; do NOT resolve symlinks
        ) else { return 0 }

        var total: Int64 = 0
        for child in children {
            guard let v = try? child.resourceValues(forKeys: Self.sizeKeys) else { continue }
            if v.isSymbolicLink == true { continue }           // never descend a symlink
            if v.isDirectory == true {
                total += directorySize(child)
            } else {
                total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? v.fileSize ?? 0)
            }
        }
        return total
    }

    public func lastModified(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
