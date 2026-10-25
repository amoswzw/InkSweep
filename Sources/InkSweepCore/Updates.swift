import CryptoKit
import Foundation

// MARK: - Versions

/// Sparkle-style version comparison: digit runs compare as numbers, letter
/// runs as text; trailing zero components are ignored ("2.0" == "2.0.0");
/// a trailing letter run marks a pre-release ("1.0b2" < "1.0").
public enum VersionCompare {
    private enum Token: Equatable {
        case number(Int), text(String)
        var isText: Bool { if case .text = self { return true } else { return false } }
    }

    private static func tokens(_ s: String) -> [Token] {
        var out: [Token] = []
        var current = ""
        var digits = false
        func flush() {
            guard !current.isEmpty else { return }
            out.append(digits ? .number(Int(current) ?? 0) : .text(current.lowercased()))
            current = ""
        }
        for ch in s {
            if ch.isNumber {
                if !digits { flush(); digits = true }
                current.append(ch)
            } else if ch.isLetter {
                if digits { flush(); digits = false }
                current.append(ch)
            } else {
                flush()
            }
        }
        flush()
        return out
    }

    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = tokens(a), y = tokens(b)
        for i in 0..<max(x.count, y.count) {
            switch (i < x.count ? x[i] : nil, i < y.count ? y[i] : nil) {
            case let (.number(m)?, .number(n)?):
                if m != n { return m < n ? .orderedAscending : .orderedDescending }
            case let (.text(m)?, .text(n)?):
                if m != n { return m < n ? .orderedAscending : .orderedDescending }
            case (.number?, .text?): return .orderedDescending
            case (.text?, .number?): return .orderedAscending
            case let (rest?, nil):
                return rest == .number(0) && x[i...].allSatisfy { $0 == .number(0) } ? .orderedSame
                    : (rest.isText ? .orderedAscending : .orderedDescending)
            case let (nil, rest?):
                return rest == .number(0) && y[i...].allSatisfy { $0 == .number(0) } ? .orderedSame
                    : (rest.isText ? .orderedDescending : .orderedAscending)
            case (nil, nil): return .orderedSame
            }
        }
        return .orderedSame
    }

    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        compare(candidate, installed) == .orderedDescending
    }
}

// MARK: - Sparkle appcasts

public struct AppcastItem: Sendable, Equatable, Codable {
    public let version: String
    public let shortVersion: String?
    public let url: URL?
    public let length: Int64?
    public let edSignature: String?
    public let minimumSystemVersion: String?
    public let releaseNotes: URL?
    public let channel: String?

    public init(version: String, shortVersion: String?, url: URL?, length: Int64?, edSignature: String?,
                minimumSystemVersion: String?, releaseNotes: URL?, channel: String?) {
        self.version = version
        self.shortVersion = shortVersion
        self.url = url
        self.length = length
        self.edSignature = edSignature
        self.minimumSystemVersion = minimumSystemVersion
        self.releaseNotes = releaseNotes
        self.channel = channel
    }
}

/// Reads a Sparkle appcast. Version fields may sit on the `<enclosure>` as
/// attributes or in the `<item>` as elements; both are accepted.
public enum Appcast {
    public static func parse(_ data: Data) -> [AppcastItem] {
        let delegate = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    /// The newest item Sparkle itself would offer: the default channel only,
    /// a downloadable enclosure, and a minimum macOS this Mac satisfies.
    public static func best(_ items: [AppcastItem],
                            os: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> AppcastItem? {
        let current = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        return items
            .filter { $0.channel == nil && $0.url != nil }
            .filter { $0.minimumSystemVersion.map { VersionCompare.compare($0, current) != .orderedDescending } ?? true }
            .max { VersionCompare.compare($0.version, $1.version) == .orderedAscending }
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var items: [AppcastItem] = []
        private var fields: [String: String]?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            if name == "item" { fields = [:] }
            if name == "enclosure", fields != nil {
                for (key, value) in attributes {
                    let k = key.replacingOccurrences(of: "sparkle:", with: "")
                    fields?["enclosure." + k] = value
                }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard fields != nil else { return }
            if name.hasPrefix("sparkle:") {
                fields?[String(name.dropFirst("sparkle:".count))] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if name == "item", let f = fields {
                if let version = f["enclosure.version"] ?? f["version"] {
                    items.append(AppcastItem(
                        version: version,
                        shortVersion: f["enclosure.shortVersionString"] ?? f["shortVersionString"],
                        url: f["enclosure.url"].flatMap(URL.init(string:)),
                        length: f["enclosure.length"].flatMap { Int64($0) },
                        edSignature: f["enclosure.edSignature"],
                        minimumSystemVersion: f["minimumSystemVersion"],
                        releaseNotes: f["releaseNotesLink"].flatMap(URL.init(string:)),
                        channel: f["channel"]))
                }
                fields = nil
            }
        }
    }
}

// MARK: - Checking

public struct AvailableUpdate: Sendable, Identifiable {
    public enum Source: Sendable {
        case sparkle(AppcastItem)
        /// The app's App Store page; the App Store installs it.
        case appStore(URL)
    }
    public let app: InstalledApp
    public let newVersion: String
    public let source: Source
    public var id: String { app.bundleID }

    public init(app: InstalledApp, newVersion: String, source: Source) {
        self.app = app
        self.newVersion = newVersion
        self.source = source
    }
}

public struct UpdateCheckResult: Sendable {
    public var updates: [AvailableUpdate] = []
    public var upToDate: [InstalledApp] = []
    /// No feed and not from the App Store: InkSweep cannot know.
    public var noSource: [InstalledApp] = []
    public var failed: [(app: InstalledApp, reason: String)] = []
    public init() {}
}

/// Read-only update check: Sparkle feeds for apps that publish one, Apple's
/// public lookup API for App Store apps. Nothing is downloaded here.
public struct UpdateChecker: Sendable {
    private let fetch: @Sendable (URL) async throws -> Data

    public init(fetch: @escaping @Sendable (URL) async throws -> Data = UpdateChecker.fetchOverNetwork) {
        self.fetch = fetch
    }

    @Sendable public static func fetchOverNetwork(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("InkSweep/0.1 (update check)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private enum Outcome: Sendable {
        case update(AvailableUpdate), current, noSource, failed(String)
    }

    public func check(_ apps: [InstalledApp]) async -> UpdateCheckResult {
        var outcomes = [Outcome?](repeating: nil, count: apps.count)
        await withTaskGroup(of: (Int, Outcome).self) { group in
            var next = 0
            func enqueue() {
                guard next < apps.count else { return }
                let index = next, app = apps[index]
                next += 1
                group.addTask { (index, await self.check(app)) }
            }
            for _ in 0..<8 { enqueue() }
            for await (index, outcome) in group {
                outcomes[index] = outcome
                enqueue()
            }
        }
        var result = UpdateCheckResult()
        for (app, outcome) in zip(apps, outcomes) {
            switch outcome {
            case .update(let u)?: result.updates.append(u)
            case .current?: result.upToDate.append(app)
            case .noSource?, nil: result.noSource.append(app)
            case .failed(let why)?: result.failed.append((app, why))
            }
        }
        return result
    }

    private func check(_ app: InstalledApp) async -> Outcome {
        if app.isAppStore { return await checkAppStore(app) }
        guard let feed = app.sparkleFeed.flatMap(URL.init(string:)), feed.scheme == "https" || feed.scheme == "http"
        else { return .noSource }
        do {
            guard let best = Appcast.best(Appcast.parse(try await fetch(feed))) else { return .current }
            let installed = app.buildVersion ?? app.version ?? "0"
            guard VersionCompare.isNewer(best.version, than: installed) else { return .current }
            return .update(AvailableUpdate(app: app, newVersion: best.shortVersion ?? best.version, source: .sparkle(best)))
        } catch {
            return .failed("feed unreachable")
        }
    }

    private func checkAppStore(_ app: InstalledApp) async -> Outcome {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [URLQueryItem(name: "bundleId", value: app.bundleID),
                                 URLQueryItem(name: "entity", value: "macSoftware")]
        do {
            let data = try await fetch(components.url!)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let first = (json["results"] as? [[String: Any]])?.first,
                  let version = first["version"] as? String else { return .noSource }
            guard VersionCompare.isNewer(version, than: app.version ?? "0") else { return .current }
            let page = (first["trackViewUrl"] as? String).flatMap(URL.init(string:))
                ?? URL(string: "macappstore://apps.apple.com/app/id\(first["trackId"] as? Int ?? 0)")!
            return .update(AvailableUpdate(app: app, newVersion: version, source: .appStore(page)))
        } catch {
            return .failed("App Store lookup failed")
        }
    }
}

// MARK: - Installing

public struct UpdateReceipt: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case updated
        case refused(String)
        case failed(String)
    }
    public let bundleID: String
    public let outcome: Outcome
}

/// Installs a Sparkle update only when everything about it checks out:
/// the archive's EdDSA signature verifies with the key inside the installed
/// app, the new bundle is the same app and newer, its code signature
/// verifies deeply and strictly, and it is signed by the same developer
/// (Team ID). The old version goes to the Trash; a failed swap rolls back.
/// Installer packages and unsigned feeds are never installed silently.
public struct AppUpdater: Sendable {
    private let download: @Sendable (URL) async throws -> URL
    private let verifyCode: @Sendable (URL) -> Bool
    private let teamID: @Sendable (URL) -> String?
    private let isRunning: @Sendable (String) -> Bool
    private let trasher: Trasher

    public init(
        download: @escaping @Sendable (URL) async throws -> URL = AppUpdater.downloadOverNetwork,
        verifyCode: @escaping @Sendable (URL) -> Bool = {
            MaintenanceActions.execute(["/usr/bin/codesign", "--verify", "--deep", "--strict", $0.path]) == 0
        },
        teamID: @escaping @Sendable (URL) -> String? = { AppThinner.staticSigning($0)?.teamID },
        isRunning: @escaping @Sendable (String) -> Bool = { ProcessSnapshot.current().bundleIDs.contains($0.lowercased()) },
        trasher: Trasher = FileManagerTrasher()
    ) {
        self.download = download
        self.verifyCode = verifyCode
        self.teamID = teamID
        self.isRunning = isRunning
        self.trasher = trasher
    }

    @Sendable public static func downloadOverNetwork(_ url: URL) async throws -> URL {
        let (temp, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let kept = FileManager.default.temporaryDirectory
            .appendingPathComponent("inksweep-update-\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: temp, to: kept)
        return kept
    }

    public func install(_ update: AvailableUpdate) async -> UpdateReceipt {
        let app = update.app
        func refuse(_ why: String) -> UpdateReceipt { UpdateReceipt(bundleID: app.bundleID, outcome: .refused(why)) }
        func fail(_ why: String) -> UpdateReceipt { UpdateReceipt(bundleID: app.bundleID, outcome: .failed(why)) }

        guard case .sparkle(let item) = update.source, let source = item.url else {
            return refuse("updates through the App Store")
        }
        let kind = source.pathExtension.lowercased()
        if ["pkg", "mpkg"].contains(kind) { return refuse("ships an installer package — download it and open it yourself") }
        guard let keyText = app.edPublicKey, let keyData = Data(base64Encoded: keyText),
              let signatureText = item.edSignature, let signature = Data(base64Encoded: signatureText),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { return refuse("no EdDSA signature to verify — download it from the developer instead") }
        if isRunning(app.bundleID) { return refuse("\(app.rawName) is running — quit it first") }

        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("inksweep-stage-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: stage) }
        let archive: URL
        do {
            archive = try await download(source)
        } catch {
            return fail("download failed")
        }
        defer { try? fm.removeItem(at: archive) }

        guard let bytes = try? Data(contentsOf: archive), key.isValidSignature(signature, for: bytes) else {
            return refuse("the download's signature does not match the developer's key")
        }
        do {
            try fm.createDirectory(at: stage, withIntermediateDirectories: true)
            try Self.extract(archive, kind: kind, into: stage)
        } catch {
            return fail("could not unpack the update")
        }
        guard let newApp = Self.findApp(in: stage, bundleID: app.bundleID) else {
            return refuse("the archive does not contain \(app.rawName)")
        }
        let newBuild = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist"))?["CFBundleVersion"] as? String ?? "0"
        guard VersionCompare.isNewer(newBuild, than: app.buildVersion ?? "0") else {
            return refuse("the download is not newer than the installed version")
        }
        guard verifyCode(newApp) else { return refuse("the new version's code signature does not verify") }
        guard let oldTeam = teamID(app.url), oldTeam == teamID(newApp) else {
            return refuse("the new version is signed by a different developer")
        }
        if isRunning(app.bundleID) { return refuse("\(app.rawName) is running — quit it first") }

        let trashed: URL?
        do {
            trashed = try trasher.trash(app.url)
        } catch {
            return fail("could not move the old version to the Trash")
        }
        do {
            try fm.moveItem(at: newApp, to: app.url)
        } catch {
            if let trashed { try? fm.moveItem(at: trashed, to: app.url) }
            return fail("could not put the new version in place — the old one was restored")
        }
        return UpdateReceipt(bundleID: app.bundleID, outcome: .updated)
    }

    static func extract(_ archive: URL, kind: String, into dir: URL) throws {
        func run(_ argv: [String]) throws {
            guard MaintenanceActions.execute(argv) == 0 else { throw CocoaError(.fileReadCorruptFile) }
        }
        switch kind {
        case "zip":
            try run(["/usr/bin/ditto", "-x", "-k", archive.path, dir.path])
        case "dmg":
            let mount = dir.appendingPathComponent(".mount", isDirectory: true)
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            try run(["/usr/bin/hdiutil", "attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, archive.path])
            defer { _ = MaintenanceActions.execute(["/usr/bin/hdiutil", "detach", "-quiet", mount.path]) }
            let apps = (try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil))
                .filter { $0.pathExtension == "app" }
            for app in apps { try run(["/usr/bin/ditto", app.path, dir.appendingPathComponent(app.lastPathComponent).path]) }
        default:
            try run(["/usr/bin/tar", "-xf", archive.path, "-C", dir.path])
        }
    }

    static func findApp(in dir: URL, bundleID: String) -> URL? {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil,
                                                    options: [.skipsPackageDescendants]) else { return nil }
        for case let url as URL in e where url.pathExtension == "app" {
            let id = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String
            if id?.lowercased() == bundleID.lowercased() { return url }
        }
        return nil
    }
}
