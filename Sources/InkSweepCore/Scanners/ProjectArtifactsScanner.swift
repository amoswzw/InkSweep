import Foundation

/// Rebuildable build outputs and dependency installs inside the user's
/// project folders (node_modules, target, .build, .venv, …). Each kind is
/// proposed only beside the project file that proves what it is, and only
/// when it is idle for a week, holds no git-tracked file and no nested
/// repository. When git cannot answer, the artifact stays.
public struct ProjectArtifactsScanner: Scanner {
    public let category: JunkCategory = .projectArtifacts

    /// Artifact name → project files, any one of which must sit beside it.
    static let markers: [String: [String]] = [
        "node_modules": ["package.json"],
        "dist": ["package.json"], ".next": ["package.json"], ".nuxt": ["package.json"],
        ".output": ["package.json"], ".turbo": ["package.json"], ".parcel-cache": ["package.json"],
        "target": ["Cargo.toml", "pom.xml"],
        "build": ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "pubspec.yaml"],
        ".gradle": ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"],
        ".build": ["Package.swift"],
        ".venv": ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile"],
        "venv": ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile"],
        ".tox": ["tox.ini"], ".nox": ["noxfile.py"],
        ".mypy_cache": ["pyproject.toml", "setup.cfg", "mypy.ini"],
        ".pytest_cache": ["pyproject.toml", "pytest.ini", "setup.cfg", "tox.ini"],
        ".ruff_cache": ["pyproject.toml", "ruff.toml"],
        ".dart_tool": ["pubspec.yaml"],
        ".zig-cache": ["build.zig"], "zig-out": ["build.zig"],
        ".terragrunt-cache": ["terragrunt.hcl"],
        "vendor": ["composer.json"],
    ]
    static let lockfiles = ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock"]
    static let projectRoots = ["Projects", "Developer", "Code", "dev", "Development", "Workspace",
                               "Repos", "GitHub", "src", "www"]
    static let maxDepth = 6

    public let minimumIdle: TimeInterval
    /// true = the artifact holds git-tracked content, nil = git could not answer.
    private let isTracked: @Sendable (_ repo: URL, _ path: URL) -> Bool?
    private let sizer: FileTreeSizer

    public init(minimumIdle: TimeInterval = 7 * 86_400,
                isTracked: @escaping @Sendable (URL, URL) -> Bool? = ProjectArtifactsScanner.gitTracked,
                sizer: FileTreeSizer = FileTreeSizer()) {
        self.minimumIdle = minimumIdle
        self.isTracked = isTracked
        self.sizer = sizer
    }

    public func scan(context: ScanContext, knowledgeBase: KnowledgeBase) -> ScanReport {
        var report = ScanReport()
        var seen = Set<String>()
        for name in Self.projectRoots {
            let root = context.homeDirectory.appendingPathComponent(name, isDirectory: true)
            // The default volume is case-insensitive: "Code" and "code" are one folder.
            guard let id = (try? root.resourceValues(forKeys: [.fileResourceIdentifierKey, .isSymbolicLinkKey]))
                .flatMap({ $0.isSymbolicLink == true ? nil : $0.fileResourceIdentifier }),
                  seen.insert(String(describing: id)).inserted else { continue }
            walk(root, depth: 0, repo: nil, now: context.now, into: &report)
        }
        return report
    }

    private func walk(_ dir: URL, depth: Int, repo: URL?, now: Date, into report: inout ScanReport) {
        guard depth < Self.maxDepth else { return }
        let fm = FileManager.default
        let repo = fm.fileExists(atPath: dir.appendingPathComponent(".git").path) ? dir : repo
        for child in Self.directories(in: dir) {
            let name = child.lastPathComponent
            if let required = Self.markers[name] {
                // An artifact is never a container: do not look inside it.
                if isCandidate(child, required: required, repo: repo, now: now) {
                    let size = sizer.size(of: child)
                    if size > 0 {
                        report.findings.append(Finding(
                            url: child, category: .projectArtifacts, sizeBytes: size, ruleID: "project-\(name)",
                            reason: "\(name) of \(dir.lastPathComponent) — rebuilt by the project's tooling; idle for over a week.",
                            reversible: true, lastModified: sizer.lastModified(of: child)))
                    }
                }
                continue
            }
            if name.hasPrefix(".") || name == "Library" { continue }
            walk(child, depth: depth + 1, repo: repo, now: now, into: &report)
        }
    }

    private func isCandidate(_ artifact: URL, required: [String], repo: URL?, now: Date) -> Bool {
        let fm = FileManager.default
        let project = artifact.deletingLastPathComponent()
        guard required.contains(where: { fm.fileExists(atPath: project.appendingPathComponent($0).path) })
        else { return false }
        if artifact.lastPathComponent == "node_modules",
           !Self.lockfiles.contains(where: { fm.fileExists(atPath: project.appendingPathComponent($0).path) }) {
            return false
        }
        let modified = (try? artifact.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? now
        guard now.timeIntervalSince(modified) >= minimumIdle else { return false }
        if Self.containsRepository(artifact, depth: 3) { return false }
        if let repo, isTracked(repo, artifact) != false { return false }
        return true
    }

    static func containsRepository(_ dir: URL, depth: Int) -> Bool {
        guard depth > 0 else { return false }
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) { return true }
        let children = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
            ?? []
        return children.contains { child in
            let v = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return v?.isDirectory == true && v?.isSymbolicLink != true && containsRepository(child, depth: depth - 1)
        }
    }

    private static func directories(in url: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [])) ?? []
        return children.filter {
            let v = try? $0.resourceValues(forKeys: Set(keys))
            return v?.isDirectory == true && v?.isSymbolicLink != true && v?.isPackage != true
        }
    }

    // MARK: git

    /// A git that will not trigger Apple's Command Line Tools install prompt:
    /// never the /usr/bin/git shim, only a real binary.
    static let gitExecutable: String? = {
        var candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git"]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            p.waitUntilExit()
            let dir = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if p.terminationStatus == 0, !dir.isEmpty { candidates.insert(dir + "/usr/bin/git", at: 0) }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    @Sendable public static func gitTracked(repo: URL, path: URL) -> Bool? {
        guard let git = gitExecutable else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = ["-C", repo.path, "-c", "core.fsmonitor=false", "ls-files", "-z", "--",
                       ":(top,literal,icase)" + String(path.resolvingSymlinksInPath().path
                           .dropFirst(repo.resolvingSymlinksInPath().path.count + 1))]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? !out.isEmpty : nil
    }
}
