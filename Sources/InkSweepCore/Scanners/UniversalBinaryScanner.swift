import Foundation

/// Universal-binary analysis: for every app in the application folders
/// (and one plain subfolder such as Utilities), how much `AppThinner` can
/// remove without breaking a code signature. The number is the same plan the
/// Thin action executes, so what is shown is what can be had.
///
/// Findings are `reversible: false`: thinning is not a Trash clean but its
/// own confirmed Maintenance action (original app goes to the Trash).
public struct UniversalBinaryScanner: Scanner {
    public let category: JunkCategory = .systemJunk

    private let appRoots: [URL]?
    private let thinner: AppThinner

    public init(appRoots: [URL]? = nil, thinner: AppThinner = AppThinner()) {
        self.appRoots = appRoots
        self.thinner = thinner
    }

    public func scan(context: ScanContext, knowledgeBase: KnowledgeBase) -> ScanReport {
        var report = ScanReport()
        for app in Self.apps(in: appRoots ?? context.applicationRoots) {
            guard case .success(let plan) = thinner.plan(app: app, ignoringRunning: true) else { continue }
            report.findings.append(Finding(
                url: app, category: .systemJunk, sizeBytes: plan.savings, ruleID: "universal-binary",
                reason: "\(plan.files.count) binaries carry code this Mac cannot run — thinnable without re-signing (Maintenance → Thin).",
                reversible: false, lastModified: nil))
        }
        return report
    }

    /// `.app` bundles directly in each root or one plain folder below it.
    public static func apps(in roots: [URL]) -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        var out: [URL] = []
        for root in roots {
            for entry in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? [] {
                let v = try? entry.resourceValues(forKeys: Set(keys))
                guard v?.isDirectory == true, v?.isSymbolicLink != true else { continue }
                if entry.pathExtension == "app" {
                    out.append(entry)
                } else if entry.pathExtension.isEmpty {
                    let inner = (try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
                    out += inner.filter {
                        $0.pathExtension == "app"
                            && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true
                    }
                }
            }
        }
        return out
    }

    // MARK: - Mach-O fat header

    #if arch(arm64)
    static let hostCPUType: UInt32 = 0x0100_000C   // CPU_TYPE_ARM64
    #else
    static let hostCPUType: UInt32 = 0x0100_0007   // CPU_TYPE_X86_64
    #endif

    /// Bytes `lipo -thin <host>` would free: the file size minus every slice
    /// of the host CPU type, read from the fat arch table. Nil for thin
    /// binaries, non-binaries, and fat files with no host slice.
    static func thinWaste(of url: URL) -> Int64? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 8), header.count == 8 else { return nil }
        let h = [UInt8](header)
        // FAT_MAGIC (0xcafebabe) / FAT_MAGIC_64 (0xcafebabf), big-endian.
        // A thin Mach-O starts with 0xfeedface/0xfeedfacf — nothing to thin.
        let magic = be32(h, 0)
        guard magic == 0xcafebabe || magic == 0xcafebabf else { return nil }
        let is64 = magic == 0xcafebabf
        let nArch = Int(be32(h, 4))
        // Java class files share 0xcafebabe; their "count" is a version > 24.
        guard nArch >= 2, nArch <= 24 else { return nil }
        let entrySize = is64 ? 32 : 20
        guard let table = try? handle.read(upToCount: nArch * entrySize),
              table.count == nArch * entrySize else { return nil }
        let t = [UInt8](table)

        var hostBytes: Int64 = 0
        for i in 0..<nArch {
            let base = i * entrySize
            guard be32(t, base) == hostCPUType else { continue }
            hostBytes += is64 ? Int64(be32(t, base + 16)) << 32 | Int64(be32(t, base + 20))
                              : Int64(be32(t, base + 12))
        }
        guard hostBytes > 0 else { return nil }

        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        let waste = size - hostBytes
        return waste > 0 ? waste : nil
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
}
