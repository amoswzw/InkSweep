import CryptoKit
import XCTest
@testable import InkSweepCore

final class VersionCompareTests: XCTestCase {
    func testNumericComponentsCompareAsNumbers() {
        XCTAssertEqual(VersionCompare.compare("1.10", "1.9"), .orderedDescending)
        XCTAssertEqual(VersionCompare.compare("2.0", "2.0.0"), .orderedSame)
        XCTAssertEqual(VersionCompare.compare("156.0.8078.48", "156.0.8078.101"), .orderedAscending)
        XCTAssertEqual(VersionCompare.compare("3.6.8", "3.6.8"), .orderedSame)
        XCTAssertEqual(VersionCompare.compare("1.0b2", "1.0b10"), .orderedAscending)
    }
}

final class AppcastTests: XCTestCase {
    private let feed = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
      <item>
        <title>2.5 beta</title>
        <sparkle:channel>beta</sparkle:channel>
        <enclosure url="https://example.com/App-2.5b.zip" sparkle:version="250" sparkle:shortVersionString="2.5b" length="10"/>
      </item>
      <item>
        <title>2.4</title>
        <sparkle:version>240</sparkle:version>
        <sparkle:shortVersionString>2.4</sparkle:shortVersionString>
        <sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion>
        <enclosure url="https://example.com/App-2.4.zip" length="10"/>
      </item>
      <item>
        <title>2.3</title>
        <sparkle:releaseNotesLink>https://example.com/notes/2.3</sparkle:releaseNotesLink>
        <enclosure url="https://example.com/App-2.3.zip" sparkle:version="230" sparkle:shortVersionString="2.3"
                   length="4096" sparkle:edSignature="c2ln"/>
      </item>
      <item>
        <title>2.2</title>
        <enclosure url="https://example.com/App-2.2.zip" sparkle:version="220" sparkle:shortVersionString="2.2" length="10"/>
      </item>
    </channel>
    </rss>
    """

    func testParsesElementAndAttributeForms() {
        let items = Appcast.parse(Data(feed.utf8))
        XCTAssertEqual(items.map(\.version), ["250", "240", "230", "220"])
        XCTAssertEqual(items[1].shortVersion, "2.4")
        XCTAssertEqual(items[2].edSignature, "c2ln")
        XCTAssertEqual(items[2].length, 4096)
        XCTAssertEqual(items[2].releaseNotes?.absoluteString, "https://example.com/notes/2.3")
        XCTAssertEqual(items[0].channel, "beta")
    }

    // Sparkle offers neither beta channels nor builds needing a newer macOS.
    func testBestSkipsChannelsAndUnsupportedSystems() {
        let best = Appcast.best(Appcast.parse(Data(feed.utf8)),
                                os: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
        XCTAssertEqual(best?.version, "230")
    }
}

final class UpdateCheckerTests: XCTestCase {
    private func app(_ id: String, build: String, short: String, feed: String? = nil, url: URL? = nil) -> InstalledApp {
        InstalledApp(url: url ?? URL(fileURLWithPath: "/Applications/\(id).app"), bundleID: id, name: id, rawName: id,
                     version: short, sparkleFeed: feed, buildVersion: build)
    }

    func testSparkleUpdateFoundAndUpToDateSeparated() async {
        let feed = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
        <enclosure url="https://example.com/a.zip" sparkle:version="230" sparkle:shortVersionString="2.3" length="1"/>
        </item></channel></rss>
        """
        let checker = UpdateChecker(fetch: { _ in Data(feed.utf8) })
        let result = await checker.check([
            app("com.old.app", build: "220", short: "2.2", feed: "https://example.com/old.xml"),
            app("com.new.app", build: "230", short: "2.3", feed: "https://example.com/new.xml"),
            app("com.nofeed.app", build: "1", short: "1.0"),
        ])

        XCTAssertEqual(result.updates.map(\.app.bundleID), ["com.old.app"])
        XCTAssertEqual(result.updates.first?.newVersion, "2.3")
        XCTAssertEqual(result.upToDate.map(\.bundleID), ["com.new.app"])
        XCTAssertEqual(result.noSource.map(\.bundleID), ["com.nofeed.app"])
    }

    func testAppStoreAppsAreCheckedThroughTheLookupAPI() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mas-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = root.appendingPathComponent("Pages.app")
        try FileManager.default.createDirectory(at: appURL.appendingPathComponent("Contents/_MASReceipt"),
                                                withIntermediateDirectories: true)
        try Data("r".utf8).write(to: appURL.appendingPathComponent("Contents/_MASReceipt/receipt"))
        let lookup = #"{"resultCount":1,"results":[{"version":"14.6","trackId":409201541,"trackViewUrl":"https://apps.apple.com/app/pages/id409201541"}]}"#
        let checker = UpdateChecker(fetch: { url in
            XCTAssertTrue(url.absoluteString.contains("bundleId=com.apple.iwork.pages"))
            return Data(lookup.utf8)
        })

        let result = await checker.check([app("com.apple.iwork.pages", build: "8000", short: "14.5", url: appURL)])

        XCTAssertEqual(result.updates.first?.newVersion, "14.6")
        guard case .appStore(let page)? = result.updates.first?.source else { return XCTFail("not an App Store update") }
        XCTAssertEqual(page.absoluteString, "https://apps.apple.com/app/pages/id409201541")
    }

    func testUnreachableFeedIsReportedNotHidden() async {
        let checker = UpdateChecker(fetch: { _ in throw URLError(.timedOut) })
        let result = await checker.check([app("com.down.app", build: "1", short: "1", feed: "https://example.com/x.xml")])
        XCTAssertEqual(result.failed.map(\.app.bundleID), ["com.down.app"])
    }
}

final class AppUpdaterTests: FixtureTestCase {
    private let key = Curve25519.Signing.PrivateKey()

    /// A fake app bundle with an id, a build number and a payload file.
    private func makeApp(at rel: String, id: String = "com.vendor.demo", build: String, payload: String) throws -> URL {
        let url = fixture.appendingPathComponent(rel)
        try writePlist(["CFBundleIdentifier": id, "CFBundleVersion": build, "CFBundleShortVersionString": build],
                       to: "\(rel)/Contents/Info.plist")
        try Data(payload.utf8).write(to: url.appendingPathComponent("Contents/payload"))
        return url
    }

    /// Zips `app` the way Sparkle archives are made and signs the archive.
    private func archive(_ app: URL) throws -> (URL, String) {
        let zip = fixture.appendingPathComponent("update-\(UUID().uuidString).zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", app.path, zip.path]
        try p.run(); p.waitUntilExit()
        let signature = try key.signature(for: Data(contentsOf: zip)).base64EncodedString()
        return (zip, signature)
    }

    private func update(for installed: URL, archive: URL, signature: String?, publicKey: String?) -> AvailableUpdate {
        let app = InstalledApp(url: installed, bundleID: "com.vendor.demo", name: "demo", rawName: "Demo",
                               version: "1", sparkleFeed: "https://example.com/feed.xml", buildVersion: "1",
                               edPublicKey: publicKey)
        let item = AppcastItem(version: "2", shortVersion: "2", url: URL(string: "https://example.com/Demo.zip"),
                               length: nil, edSignature: signature, minimumSystemVersion: nil,
                               releaseNotes: nil, channel: nil)
        return AvailableUpdate(app: app, newVersion: "2", source: .sparkle(item))
    }

    private func updater(archive: URL, team: String? = "ABCDE12345", newTeam: String? = "ABCDE12345",
                         running: Bool = false) -> AppUpdater {
        AppUpdater(
            download: { _ in
                let copy = self.fixture.appendingPathComponent("dl-\(UUID().uuidString).zip")
                try FileManager.default.copyItem(at: archive, to: copy)
                return copy
            },
            verifyCode: { _ in true },
            teamID: { url in url.path.contains("/Applications/") ? team : newTeam },
            isRunning: { _ in running },
            trasher: MovingTrasher(trash: fixture.appendingPathComponent(".Trash")))
    }

    func testVerifiedUpdateReplacesTheAppAndTrashesTheOldOne() async throws {
        let installed = try makeApp(at: "Applications/Demo.app", build: "1", payload: "old")
        let new = try makeApp(at: "build/Demo.app", build: "2", payload: "new")
        let (zip, sig) = try archive(new)
        let pub = key.publicKey.rawRepresentation.base64EncodedString()

        let receipt = await updater(archive: zip).install(update(for: installed, archive: zip, signature: sig, publicKey: pub))

        XCTAssertEqual(receipt.outcome, .updated)
        XCTAssertEqual(try String(contentsOf: installed.appendingPathComponent("Contents/payload"), encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: fixture.appendingPathComponent(".Trash/Demo.app/Contents/payload"), encoding: .utf8), "old")
    }

    func testRefusesBadSignatureMissingKeyOtherTeamAndRunningApp() async throws {
        let installed = try makeApp(at: "Applications/Demo.app", build: "1", payload: "old")
        let new = try makeApp(at: "build/Demo.app", build: "2", payload: "new")
        let (zip, sig) = try archive(new)
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()

        let cases: [(AppUpdater, AvailableUpdate, String)] = [
            (updater(archive: zip), update(for: installed, archive: zip, signature: sig, publicKey: other), "signature"),
            (updater(archive: zip), update(for: installed, archive: zip, signature: nil, publicKey: nil), "signature"),
            (updater(archive: zip, newTeam: "ZZZZZ99999"), update(for: installed, archive: zip, signature: sig, publicKey: pub), "developer"),
            (updater(archive: zip, running: true), update(for: installed, archive: zip, signature: sig, publicKey: pub), "running"),
        ]
        for (u, upd, expected) in cases {
            let receipt = await u.install(upd)
            guard case .refused(let why) = receipt.outcome else { return XCTFail("\(expected): \(receipt.outcome)") }
            XCTAssertTrue(why.contains(expected), "\(expected) vs \(why)")
            XCTAssertEqual(try String(contentsOf: installed.appendingPathComponent("Contents/payload"), encoding: .utf8), "old")
        }
    }
}
