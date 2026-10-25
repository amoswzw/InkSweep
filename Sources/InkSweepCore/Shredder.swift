import Foundation
import Security

/// A record of what the shredder did to one path.
public struct ShredReceipt: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case shredded
        case skippedDryRun
        case failed(String)
    }
    public let url: URL
    public let outcome: Outcome

    public init(url: URL, outcome: Outcome) {
        self.url = url
        self.outcome = outcome
    }
}

/// Irreversible deletion — the Shredder tool. Opt-in and deliberately
/// separate from the default reversible (Trash) clean flow.
///
/// For regular files it overwrites the contents with three passes of random
/// data before unlinking; directories are cleared bottom-up; a symbolic link
/// is unlinked without ever touching its target.
///
/// Honest limitation, stated up front: on APFS (copy-on-write, SSDs) no
/// overwrite can guarantee physical erasure of every copy. This is the same
/// best-effort semantics the original feature ships with — which is exactly
/// why it lives behind an explicit "permanently" confirmation in the UI.
public struct Shredder: Sendable {
    /// Never shredded, nor is any ancestor of them (nor "/").
    public let protectedDirectories: [URL]

    public init(protectedDirectories: [URL] = [FileManager.default.homeDirectoryForCurrentUser]) {
        self.protectedDirectories = protectedDirectories
    }

    public func shred(_ urls: [URL], dryRun: Bool = true) -> [ShredReceipt] {
        urls.map { url in
            if isProtected(url) {
                return ShredReceipt(url: url, outcome: .failed("protected location — refused"))
            }
            guard !dryRun else { return ShredReceipt(url: url, outcome: .skippedDryRun) }
            do {
                try shredOne(url)
                return ShredReceipt(url: url, outcome: .shredded)
            } catch {
                return ShredReceipt(url: url, outcome: .failed(error.localizedDescription))
            }
        }
    }

    // MARK: - Internals

    private func isProtected(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if path == "/" { return true }
        return protectedDirectories.contains { dir in
            let protected = dir.standardizedFileURL.resolvingSymlinksInPath().path
            return protected == path || protected.hasPrefix(path + "/")
        }
    }

    private func shredOne(_ url: URL) throws {
        let fm = FileManager.default

        // A symlink is unlinked only — its target must survive.
        if Self.isSymbolicLink(url) {
            try fm.removeItem(at: url)
            return
        }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if isDir.boolValue {
            let children = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            for child in children {
                try shredOne(child)  // post-order: contents first
            }
            try fm.removeItem(at: url)
        } else {
            try overwrite(url)
            try fm.removeItem(at: url)
        }
    }

    /// Three passes of random data, fsync after each.
    private func overwrite(_ url: URL) throws {
        // Another hard link shares these blocks: overwriting would destroy
        // that path's contents, which the user never chose to shred.
        let links = (try FileManager.default.attributesOfItem(atPath: url.path)[.referenceCount] as? NSNumber)?
            .intValue ?? 1
        guard links <= 1 else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [
                NSLocalizedDescriptionKey: "\(url.lastPathComponent) has \(links) hard links — refused",
            ])
        }
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        guard size > 0 else { return }

        let bufferSize = 1_048_576
        var buffer = Data(count: bufferSize)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        for _ in 0..<3 {
            try handle.seek(toOffset: 0)
            var status = errSecSuccess
            buffer.withUnsafeMutableBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                status = SecRandomCopyBytes(kSecRandomDefault, ptr.count, base)
            }
            if status != errSecSuccess {
                throw CocoaError(.fileWriteUnknown)
            }
            var remaining = size
            while remaining > 0 {
                let n = min(Int64(buffer.count), remaining)
                try handle.write(contentsOf: buffer.prefix(Int(n)))
                remaining -= n
            }
            try handle.synchronize()
        }
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }
}
