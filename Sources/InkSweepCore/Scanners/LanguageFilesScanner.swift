import Foundation

/// Language-file analysis: counts the size of .lproj localization bundles
/// inside each application that the user's preferred languages don't need —
/// the analysis half of a classic cleaner capability. Like the universal-
/// binary scanner, this walks every app bundle, which is real scan work.
///
/// Analysis only: deleting .lproj bundles modifies app bundles (breaks code
/// signatures → re-signing required), so the operation belongs to the
/// privileged-helper phase. Findings are `reversible: false` and excluded
/// from every clean action by design.
public struct LanguageFilesScanner: Scanner {
    public let category: JunkCategory = .systemJunk

    private let appRoots: [URL]?
    private let preferredLanguages: [String]
    private let sizer: FileTreeSizer

    public init(
        appRoots: [URL]? = nil,
        preferredLanguages: [String]? = nil,
        sizer: FileTreeSizer = FileTreeSizer()
    ) {
        self.appRoots = appRoots
        if let preferredLanguages {
            self.preferredLanguages = preferredLanguages
        } else {
            // The user's first two system languages, always keeping English
            // and Base — the conservative reading of "unneeded localization".
            let apple = UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? []
            var langs = Array(apple.prefix(2))
            if !langs.contains("en") { langs.append("en") }
            self.preferredLanguages = langs
        }
        self.sizer = sizer
    }

    public func scan(context: ScanContext, knowledgeBase: KnowledgeBase) -> ScanReport {
        var report = ScanReport()
        let fm = FileManager.default
        var preferredTokens = Set(preferredLanguages.map(Self.firstToken))
        preferredTokens.insert("base")   // Base.lproj is shared resources, never junk

        for root in appRoots ?? context.applicationRoots {
            guard let apps = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for appDir in apps where appDir.pathExtension == "app" {
                let resources = appDir.appendingPathComponent("Contents/Resources", isDirectory: true)
                guard let entries = try? fm.contentsOfDirectory(
                    at: resources, includingPropertiesForKeys: nil
                ) else { continue }

                var waste: Int64 = 0
                var names: [String] = []
                for entry in entries {
                    let name = entry.lastPathComponent
                    guard name.hasSuffix(".lproj") else { continue }
                    let lang = String(name.dropLast(".lproj".count))
                    if preferredTokens.contains(Self.firstToken(lang)) { continue }
                    waste += sizer.size(of: entry)
                    names.append(lang)
                }
                guard waste > 0, !names.isEmpty else { continue }
                report.findings.append(Finding(
                    url: appDir,
                    category: .systemJunk,
                    sizeBytes: waste,
                    ruleID: "language-files",
                    reason: "Extra localizations (\(names.sorted().prefix(4).joined(separator: ", "))\(names.count > 4 ? "…" : "")) — removal needs the privileged helper (re-sign follows).",
                    reversible: false,
                    lastModified: nil
                ))
            }
        }
        return report
    }

    /// Pre-ISO folder names older bundles still ship ("English.lproj").
    private static let legacyNames: [String: String] = [
        "english": "en", "french": "fr", "german": "de", "japanese": "ja",
        "spanish": "es", "italian": "it", "dutch": "nl",
    ]

    /// "zh-Hans" → "zh", "pt_BR" → "pt", "English" → "en".
    private static func firstToken(_ language: String) -> String {
        let token = String(language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? Substring(language))
            .lowercased()
        return legacyNames[token] ?? token
    }
}
