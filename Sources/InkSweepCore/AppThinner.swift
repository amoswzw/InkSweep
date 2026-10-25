import Foundation
import Security

public enum ThinRefusal: String, Error, Sendable, Equatable {
    case notOwned = "not owned by you"
    case appStore = "App Store app"
    case apple = "Apple app"
    case notDeveloperID = "not signed with a Developer ID"
    case running = "running"
    case rosetta = "set to open using Rosetta"
    case nothingToThin = "nothing safely thinnable"
}

public struct ThinPlan: Sendable {
    public struct File: Sendable {
        public let url: URL
        public let savedBytes: Int64
    }
    public let app: URL
    public let bundleID: String
    public let files: [File]
    public var savings: Int64 { files.reduce(0) { $0 + $1.savedBytes } }
}

public struct ThinReceipt: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case thinned
        case refused(String)
        case failed(String)
    }
    public let app: URL
    public let outcome: Outcome
    public let savedBytes: Int64
}

/// Removes the slices this Mac cannot run from a universal app, without
/// administrator rights and without re-signing. Code signatures live per
/// slice, so the kept slice stays validly signed — provided only code the
/// seals reference by code-directory hash is touched:
///
/// - a bundle's main executable, or a file its nearest seal lists by `cdhash`;
/// - never a file any enclosing seal lists by plain `hash2` (Electron
///   frameworks seal libffmpeg.dylib that way — thinning it breaks the app);
/// - never anything under Resources or _CodeSignature.
///
/// Work happens on an APFS clone that must pass `codesign --verify --deep
/// --strict` (and Gatekeeper, if the original passed) before it replaces
/// the original, which goes to the Trash. Implementation is original.
public struct AppThinner: Sendable {
    public struct Signing: Sendable, Equatable {
        public let developerID: Bool
        public let teamID: String?
        public init(developerID: Bool, teamID: String?) {
            self.developerID = developerID
            self.teamID = teamID
        }
    }

    private let signing: @Sendable (URL) -> Signing?
    private let isRunning: @Sendable (String) -> Bool
    private let verify: @Sendable (URL) -> Bool
    private let rosettaBundleIDs: @Sendable () -> Set<String>
    private let trasher: Trasher

    public init(
        signing: @escaping @Sendable (URL) -> Signing? = AppThinner.staticSigning,
        isRunning: @escaping @Sendable (String) -> Bool = { ProcessSnapshot.current().bundleIDs.contains($0.lowercased()) },
        verify: @escaping @Sendable (URL) -> Bool = AppThinner.codesignAndGatekeeperAccept,
        rosettaBundleIDs: @escaping @Sendable () -> Set<String> = AppThinner.rosettaPreferredApps,
        trasher: Trasher = FileManagerTrasher()
    ) {
        self.signing = signing
        self.isRunning = isRunning
        self.verify = verify
        self.rosettaBundleIDs = rosettaBundleIDs
        self.trasher = trasher
    }

    // MARK: Planning

    /// `ignoringRunning` measures a running app too (the scan reports it;
    /// `thin` still refuses while it runs).
    public func plan(app: URL, ignoringRunning: Bool = false) -> Result<ThinPlan, ThinRefusal> {
        let fm = FileManager.default
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let bundleID = info["CFBundleIdentifier"] as? String else { return .failure(.nothingToThin) }
        if ProtectedPaths.isAppleNamespace(bundleID.lowercased()) { return .failure(.apple) }
        if fm.fileExists(atPath: app.appendingPathComponent("Contents/_MASReceipt").path) { return .failure(.appStore) }
        guard let sig = signing(app), sig.developerID, (sig.teamID?.count ?? 0) == 10 else {
            return .failure(.notDeveloperID)
        }
        if rosettaBundleIDs().contains(bundleID.lowercased()) { return .failure(.rosetta) }
        if !ignoringRunning, isRunning(bundleID) { return .failure(.running) }
        guard Self.ownedByCurrentUser(app) else { return .failure(.notOwned) }

        var files: [ThinPlan.File] = []
        var seals = SealCache()
        // The 8-byte fat-header read is cheap; seal checks only run for fat files.
        for file in Self.regularFiles(in: app) {
            guard let waste = UniversalBinaryScanner.thinWaste(of: file), Self.hostSliceCount(file) == 1,
                  Self.isThinnable(file, app: app, seals: &seals) else { continue }
            files.append(ThinPlan.File(url: file, savedBytes: waste))
        }
        return files.isEmpty ? .failure(.nothingToThin) : .success(ThinPlan(app: app, bundleID: bundleID, files: files))
    }

    /// Main executable of its nearest bundle, or cdhash-sealed by the nearest
    /// seal — and listed by plain hash in no enclosing seal.
    static func isThinnable(_ file: URL, app: URL) -> Bool {
        var cache = SealCache()
        return isThinnable(file, app: app, seals: &cache)
    }

    static func isThinnable(_ file: URL, app: URL, seals cache: inout SealCache) -> Bool {
        let seals = enclosingSeals(of: file, app: app, cache: &cache)
        guard let nearest = seals.first else { return false }
        for seal in seals {
            let key = relativePath(file, from: seal.base)
            if let entry = seal.files2[key], !isCdhashEntry(entry) { return false }
        }
        if nearest.mainExecutable?.standardizedFileURL == file.standardizedFileURL { return true }
        return nearest.files2[relativePath(file, from: nearest.base)].map(isCdhashEntry) ?? false
    }

    struct Seal {
        let base: URL
        let files2: [String: Any]
        let mainExecutable: URL?
    }

    /// Parsed seals by base path (`nil` = no seal there), shared across a plan.
    typealias SealCache = [String: Seal?]

    /// Seals from the innermost bundle out to the app. An app-style bundle
    /// seals `X/Contents`; a framework version seals `Versions/A`.
    static func enclosingSeals(of file: URL, app: URL) -> [Seal] {
        var cache = SealCache()
        return enclosingSeals(of: file, app: app, cache: &cache)
    }

    static func enclosingSeals(of file: URL, app: URL, cache: inout SealCache) -> [Seal] {
        var seals: [Seal] = []
        var dir = file.deletingLastPathComponent().standardizedFileURL
        let top = app.standardizedFileURL.path
        while dir.path.hasPrefix(top) {
            for base in [dir, dir.appendingPathComponent("Contents")] {
                if seals.contains(where: { $0.base.path == base.path }) { continue }
                if let cached = cache[base.path] {
                    if let seal = cached { seals.append(seal) }
                    continue
                }
                let resources = base.appendingPathComponent("_CodeSignature/CodeResources")
                guard let plist = NSDictionary(contentsOf: resources) as? [String: Any] else {
                    cache[base.path] = .some(nil)
                    continue
                }
                let infoPlist = base.lastPathComponent == "Contents"
                    ? base.appendingPathComponent("Info.plist") : base.appendingPathComponent("Resources/Info.plist")
                let exe = (NSDictionary(contentsOf: infoPlist)?["CFBundleExecutable"] as? String).map {
                    base.lastPathComponent == "Contents"
                        ? base.appendingPathComponent("MacOS/\($0)") : base.appendingPathComponent($0)
                }
                let seal = Seal(base: base, files2: plist["files2"] as? [String: Any] ?? [:], mainExecutable: exe)
                cache[base.path] = .some(seal)
                seals.append(seal)
            }
            if dir.path == top { break }
            dir = dir.deletingLastPathComponent()
        }
        return seals
    }

    static func isCdhashEntry(_ entry: Any) -> Bool {
        (entry as? [String: Any])?["cdhash"] != nil
    }

    static func relativePath(_ file: URL, from base: URL) -> String {
        String(file.standardizedFileURL.path.dropFirst(base.standardizedFileURL.path.count + 1))
    }

    /// Regular files outside Resources and _CodeSignature; symlinks skipped.
    static func regularFiles(in app: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(
            at: app, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else { return [] }
        var out: [URL] = []
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            // Frameworks carry a top-level `Resources` symlink; skipDescendants
            // on a symlink entry would skip the rest of the framework instead.
            if v?.isSymbolicLink == true { continue }
            let name = url.lastPathComponent
            if name == "Resources" || name == "_CodeSignature" { e.skipDescendants(); continue }
            if v?.isRegularFile == true { out.append(url) }
        }
        return out
    }

    static func ownedByCurrentUser(_ app: URL) -> Bool {
        let uid = getuid()
        guard let e = FileManager.default.enumerator(atPath: app.path) else { return false }
        let owner: (String) -> Bool = { path in
            var st = stat()
            return lstat(path, &st) == 0 && st.st_uid == uid
        }
        guard owner(app.path), access(app.deletingLastPathComponent().path, W_OK) == 0 else { return false }
        while let rel = e.nextObject() as? String {
            if !owner(app.appendingPathComponent(rel).path) { return false }
        }
        return true
    }

    // MARK: Fat slices

    /// (offset, size) of every slice of the host CPU type, or nil if not fat.
    static func hostSlices(of file: URL) -> [(offset: UInt64, size: UInt64)]? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 8), header.count == 8 else { return nil }
        let h = [UInt8](header)
        let magic = be32(h, 0)
        guard magic == 0xcafebabe || magic == 0xcafebabf else { return nil }
        let is64 = magic == 0xcafebabf
        let n = Int(be32(h, 4))
        guard n >= 2, n <= 24 else { return nil }
        let entry = is64 ? 32 : 20
        guard let table = try? handle.read(upToCount: n * entry), table.count == n * entry else { return nil }
        let t = [UInt8](table)
        var out: [(UInt64, UInt64)] = []
        for i in 0..<n where be32(t, i * entry) == UniversalBinaryScanner.hostCPUType {
            let b = i * entry
            if is64 {
                out.append((UInt64(be32(t, b + 8)) << 32 | UInt64(be32(t, b + 12)),
                            UInt64(be32(t, b + 16)) << 32 | UInt64(be32(t, b + 20))))
            } else {
                out.append((UInt64(be32(t, b + 8)), UInt64(be32(t, b + 12))))
            }
        }
        return out
    }

    static func hostSliceCount(_ file: URL) -> Int { hostSlices(of: file)?.count ?? 0 }

    private static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    /// Replaces a fat file with its single host slice — what `lipo -thin`
    /// writes — keeping the file's permissions.
    static func extractHostSlice(_ file: URL) throws {
        guard let slices = hostSlices(of: file), slices.count == 1 else { throw CocoaError(.fileReadCorruptFile) }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: slices[0].offset)
        guard let slice = try handle.read(upToCount: Int(slices[0].size)), slice.count == Int(slices[0].size)
        else { throw CocoaError(.fileReadCorruptFile) }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let temp = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).thin")
        try slice.write(to: temp)
        try FileManager.default.setAttributes([.posixPermissions: attributes[.posixPermissions] ?? 0o755],
                                              ofItemAtPath: temp.path)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: temp)
    }

    // MARK: Thinning

    public func thin(app: URL) -> ThinReceipt {
        let plan: ThinPlan
        switch self.plan(app: app) {
        case .failure(let refusal): return ThinReceipt(app: app, outcome: .refused(refusal.rawValue), savedBytes: 0)
        case .success(let p): plan = p
        }
        let fm = FileManager.default
        let stage = app.deletingLastPathComponent()
            .appendingPathComponent(".inksweep-thin-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: stage) }
        let clone = stage.appendingPathComponent(app.lastPathComponent)
        do {
            try fm.createDirectory(at: stage, withIntermediateDirectories: false)
            try fm.copyItem(at: app, to: clone)   // an APFS clone: no extra space until written
            for file in plan.files {
                try Self.extractHostSlice(clone.appendingPathComponent(Self.relativePath(file.url, from: app)))
            }
        } catch {
            return ThinReceipt(app: app, outcome: .failed("could not prepare the copy: \(error.localizedDescription)"), savedBytes: 0)
        }
        guard verify(clone) else {
            return ThinReceipt(app: app, outcome: .failed("the thinned copy failed signature verification — original kept"), savedBytes: 0)
        }
        if isRunning(plan.bundleID) {
            return ThinReceipt(app: app, outcome: .refused(ThinRefusal.running.rawValue), savedBytes: 0)
        }
        let trashed: URL?
        do {
            trashed = try trasher.trash(app)
        } catch {
            return ThinReceipt(app: app, outcome: .failed("could not move the original to the Trash"), savedBytes: 0)
        }
        do {
            try fm.moveItem(at: clone, to: app)
        } catch {
            if let trashed { try? fm.moveItem(at: trashed, to: app) }
            return ThinReceipt(app: app, outcome: .failed("swap failed — original restored"), savedBytes: 0)
        }
        return ThinReceipt(app: app, outcome: .thinned, savedBytes: plan.savings)
    }

    // MARK: System probes

    /// Signing identity read in-process from the static code signature.
    @Sendable public static func staticSigning(_ app: URL) -> Signing? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
        let leaf = (dict[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first
        let summary = leaf.flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? ""
        return Signing(developerID: summary.hasPrefix("Developer ID Application"), teamID: team)
    }

    /// The clone must verify deeply and strictly, and Gatekeeper must accept it.
    @Sendable public static func codesignAndGatekeeperAccept(_ app: URL) -> Bool {
        MaintenanceActions.execute(["/usr/bin/codesign", "--verify", "--deep", "--strict", app.path]) == 0
            && MaintenanceActions.execute(["/usr/sbin/spctl", "--assess", "--type", "execute", app.path]) == 0
    }

    /// Bundle IDs the user set to "Open using Rosetta".
    @Sendable public static func rosettaPreferredApps() -> Set<String> {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.LaunchServices/com.apple.LaunchServices.plist")
        let dict = NSDictionary(contentsOf: url)?["LSArchitecturesForX86_64"] as? [String: Any] ?? [:]
        return Set(dict.keys.map { $0.lowercased() })
    }
}
