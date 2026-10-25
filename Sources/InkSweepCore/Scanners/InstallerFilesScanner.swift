import Foundation

/// Installer images and packages left in download locations after the app
/// was installed. Fresh downloads (under a week) and disk images that are
/// currently mounted stay.
public struct InstallerFilesScanner: Scanner {
    public let category: JunkCategory = .installerFiles

    static let extensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]
    static let locations = [
        "Downloads", "Desktop",
        "Library/Mobile Documents/com~apple~CloudDocs/Downloads",
        "Library/Containers/com.apple.mail/Data/Library/Mail Downloads",
    ]

    public let minimumAge: TimeInterval
    private let attachedImages: @Sendable () -> Set<String>
    private let sizer: FileTreeSizer

    public init(minimumAge: TimeInterval = 7 * 86_400,
                attachedImages: @escaping @Sendable () -> Set<String> = InstallerFilesScanner.attachedDiskImages,
                sizer: FileTreeSizer = FileTreeSizer()) {
        self.minimumAge = minimumAge
        self.attachedImages = attachedImages
        self.sizer = sizer
    }

    public func scan(context: ScanContext, knowledgeBase: KnowledgeBase) -> ScanReport {
        var report = ScanReport()
        let mounted = attachedImages()
        for location in Self.locations {
            visit(context.homeDirectory.appendingPathComponent(location, isDirectory: true), depth: 0,
                  now: context.now, mounted: mounted, into: &report)
        }
        return report
    }

    private func visit(_ dir: URL, depth: Int, now: Date, mounted: Set<String>, into report: inout ScanReport) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
        for child in children {
            guard let v = try? child.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { continue }
            let ext = child.pathExtension.lowercased()
            if Self.extensions.contains(ext) {
                // A .pkg may be a bundle directory; either way it is one item.
                let modified = v.contentModificationDate ?? now
                guard now.timeIntervalSince(modified) >= minimumAge,
                      !mounted.contains(child.resolvingSymlinksInPath().path) else { continue }
                let size = sizer.size(of: child)
                guard size > 0 else { continue }
                report.findings.append(Finding(
                    url: child, category: .installerFiles, sizeBytes: size, ruleID: "installer-file",
                    reason: "Installer (.\(ext)) downloaded \(Int(now.timeIntervalSince(modified) / 86_400)) days ago.",
                    reversible: true, lastModified: modified))
            } else if v.isDirectory == true, depth < 1, child.pathExtension.isEmpty {
                visit(child, depth: depth + 1, now: now, mounted: mounted, into: &report)
            }
        }
    }

    /// Image paths `hdiutil info` reports as attached.
    @Sendable public static func attachedDiskImages() -> Set<String> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["info", "-plist"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [] }
        return Set(images.compactMap { ($0["image-path"] as? String).map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } })
    }
}
