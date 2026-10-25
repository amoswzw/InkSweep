import Foundation

/// Rules cross-checked against the documented conventions of open-source
/// cleanup tools. Every location below was checked against the owning
/// tool's own convention, and each rule is written fresh here. Each `note`
/// says what regenerates the data.
extension KnowledgeBase {
    private static let crossChecked = "cross-checked"

    private static func rule(
        _ id: String, _ category: JunkCategory, _ pattern: String,
        _ strategy: ScanStrategy = .childrenOfDirectory,
        reason: String, source: String, note: String,
        processes: [String] = [], bundles: [String] = []
    ) -> Rule {
        Rule(id: id, category: category, root: .homePattern(pattern), strategy: strategy,
             reason: reason, provenance: Provenance(source: "\(source); \(crossChecked)", note: note),
             ownerProcesses: processes, ownerBundleIDs: bundles)
    }

    static let extendedRules: [Rule] = appleCacheRules + devCacheRules + appCacheRules + [
        rule("diagnostic-reports", .systemLogs, "Library/Logs/DiagnosticReports",
             reason: "Crash and hang reports already sent or no longer needed.",
             source: "macOS ReportCrash conventions",
             note: "Per-report files; the folder itself stays for ReportCrash to write into."),
    ]

    // MARK: Apple caches, cleaned by contents (the daemon-owned folder stays)

    private static let appleCacheRules: [Rule] = [
        ("com.apple.Safari", "Safari web cache.", ["com.apple.Safari"]),
        ("com.apple.WebKit.Networking", "WebKit network cache.", []),
        ("com.apple.AppleMediaServices", "App Store / media services cache.", []),
        ("com.apple.helpd", "macOS Help viewer cache.", []),
        ("com.apple.parsecd", "Spotlight suggestions network cache.", []),
        ("com.apple.python", "Bytecode cache of Apple's bundled Python.", []),
        ("com.apple.QuickLook.thumbnailcache", "Quick Look thumbnail cache.", []),
        ("com.apple.photoanalysisd", "Photos analysis cache (recomputed in the background).", ["com.apple.Photos"]),
        ("com.apple.Music", "Apple Music streaming and artwork cache.", ["com.apple.Music"]),
        ("com.apple.podcasts", "Podcasts streaming cache.", ["com.apple.podcasts"]),
        ("com.apple.TV", "Apple TV app streaming cache.", ["com.apple.TV"]),
        ("com.apple.dt.Xcode", "Xcode's own cache.", ["com.apple.dt.Xcode"]),
        ("com.apple.FinalCut", "Final Cut Pro cache.", ["com.apple.FinalCut"]),
    ].map { name, reason, owners in
        rule("apple-cache-\(name)", .userCaches, "Library/Caches/\(name)", reason: reason,
             source: "~/Library/Caches convention (Apple File System Programming Guide)",
             note: "The owning Apple service refills it on demand.", bundles: owners)
    } + [
        ("com.apple.mediaanalysisd", "Library/Caches", "Media analysis cache."),
        ("com.apple.mediaanalysisd", "tmp", "Media analysis temporary files."),
        ("com.apple.AppStore", "Library/Caches", "App Store cache."),
        ("com.apple.stocks", "Library/Caches", "Stocks cache."),
        ("com.apple.AMPArtworkAgent", "Library/Caches", "Music album-art cache."),
        ("com.apple.CoreDevice.CoreDeviceService", "Library/Caches", "CoreDevice service cache."),
        ("com.apple.geod", "tmp", "Maps service temporary files."),
        ("com.apple.wallpaper.extension.aerials", "tmp", "Aerial wallpaper download temp files."),
    ].map { container, sub, reason in
        rule("apple-container-\(container)-\(sub == "tmp" ? "tmp" : "caches")", .userCaches,
             "Library/Containers/\(container)/Data/\(sub)", reason: reason,
             source: "App Sandbox container layout (Data/Library/Caches, Data/tmp)",
             note: "Sandbox Caches and tmp are regenerable by definition.")
    }

    // MARK: Developer tool caches

    private static let devCacheRules: [Rule] = [
        rule("npm-cacache", .developerJunk, ".npm/_cacache", reason: "npm package cache.",
             source: "npm docs: `npm cache` (content-addressable, self-healing)",
             note: "Re-downloaded on the next install.", processes: ["npm", "npx"]),
        rule("npm-npx", .developerJunk, ".npm/_npx", reason: "npx one-off package installs.",
             source: "npm docs: npx cache", note: "Fetched again when the command is next run.",
             processes: ["npm", "npx"]),
        rule("npm-logs", .developerJunk, ".npm/_logs", .directoryItself, reason: "npm debug logs.",
             source: "npm docs: logs-dir", note: "Diagnostic only.", processes: ["npm", "npx"]),
        rule("yarn-berry-cache", .developerJunk, ".yarn/berry/cache", reason: "Yarn 2+ global package cache.",
             source: "Yarn docs: globalFolder (~/.yarn/berry)", note: "Re-fetched on install.",
             processes: ["yarn"]),
        rule("bun-cache", .developerJunk, ".bun/install/cache", reason: "Bun package cache.",
             source: "Bun docs: install cache", note: "Re-fetched on install.", processes: ["bun"]),
        rule("cargo-registry-cache", .developerJunk, ".cargo/registry/cache",
             reason: "Downloaded Rust crate archives.",
             source: "Cargo book: CARGO_HOME/registry/cache",
             note: "Extracted sources stay; archives are re-downloaded when needed.",
             processes: ["cargo", "rustc"]),
        rule("rustup-downloads", .developerJunk, ".rustup/downloads", reason: "Rustup download leftovers.",
             source: "rustup: RUSTUP_HOME/downloads", note: "Partial or finished toolchain downloads.",
             processes: ["rustup", "cargo"]),
        rule("go-mod-download", .developerJunk, "go/pkg/mod/cache/download",
             reason: "Go module download cache (zips).",
             source: "Go docs: GOMODCACHE/cache/download",
             note: "Re-downloaded by the go command when a module is next needed.", processes: ["go"]),
        rule("gradle-build-cache", .developerJunk, ".gradle/caches/build-cache-*",
             reason: "Gradle local build cache.", source: "Gradle docs: build cache (GRADLE_USER_HOME)",
             note: "Task outputs are rebuilt on a cache miss.", processes: ["java"]),
        rule("gradle-daemon-logs", .developerJunk, ".gradle/daemon",
             reason: "Gradle daemon logs and registries of stopped daemons.",
             source: "Gradle docs: daemon", note: "Recreated when a daemon next starts.", processes: ["java"]),
        rule("uv-cache", .developerJunk, ".cache/uv", .directoryItself, reason: "uv Python package cache.",
             source: "uv docs: cache directory (`uv cache clean`)", note: "Re-fetched on install.",
             processes: ["uv"]),
        rule("pre-commit-cache", .developerJunk, ".cache/pre-commit", .directoryItself,
             reason: "pre-commit hook environments.", source: "pre-commit docs: `pre-commit clean`",
             note: "Rebuilt on the next hook run.", processes: ["pre-commit"]),
        rule("ruff-cache", .developerJunk, ".cache/ruff", .directoryItself, reason: "Ruff global cache.",
             source: "Ruff docs: cache-dir", note: "Recomputed on the next lint.", processes: ["ruff"]),
        rule("pyenv-cache", .developerJunk, ".pyenv/cache", reason: "pyenv source download cache.",
             source: "pyenv: PYENV_ROOT/cache", note: "Python builds download it again.", processes: ["pyenv"]),
        rule("rbenv-cache", .developerJunk, ".rbenv/cache", reason: "rbenv/ruby-build download cache.",
             source: "ruby-build: RUBY_BUILD_CACHE_PATH", note: "Ruby builds download it again."),
        rule("gem-specs", .developerJunk, ".gem/specs", reason: "RubyGems remote spec cache.",
             source: "RubyGems: spec cache", note: "Refetched from the gem source.", processes: ["gem", "bundle"]),
        rule("typescript-cache", .developerJunk, ".cache/typescript", reason: "TypeScript automatic type-acquisition cache.",
             source: "TypeScript: typingsInstaller global cache", note: "Re-acquired by the language server."),
        rule("electron-cache", .developerJunk, ".cache/electron", reason: "Electron build download cache.",
             source: "@electron/get: cache directory", note: "Re-downloaded by the next build."),
        rule("node-gyp-cache", .developerJunk, ".cache/node-gyp", reason: "node-gyp header downloads.",
             source: "node-gyp: devdir", note: "Re-downloaded for the next native build.", processes: ["node-gyp"]),
        rule("prisma-cache", .developerJunk, ".cache/prisma", reason: "Prisma engine downloads.",
             source: "Prisma: engine cache", note: "Re-downloaded by `prisma generate`."),
        rule("zig-cache", .developerJunk, ".cache/zig", .directoryItself, reason: "Zig global build cache.",
             source: "Zig: global cache directory", note: "Rebuilt on demand.", processes: ["zig"]),
        rule("android-sdk-cache", .developerJunk, ".android/cache", reason: "Android SDK manager cache.",
             source: "Android SDK: ~/.android/cache", note: "Refetched by the SDK manager."),
        rule("composer-cache", .developerJunk, ".composer/cache", reason: "PHP Composer legacy cache.",
             source: "Composer docs: cache-dir", note: "Re-downloaded on install.", processes: ["composer"]),
        rule("hex-cache", .developerJunk, ".hex/cache", reason: "Elixir Hex package cache.",
             source: "Hex: cache directory", note: "Re-fetched on deps.get.", processes: ["mix", "beam.smp"]),
        rule("opam-download-cache", .developerJunk, ".opam/download-cache", reason: "opam download cache.",
             source: "opam: download-cache", note: "Re-downloaded on install.", processes: ["opam"]),
        rule("cpan-build", .developerJunk, ".cpan/build", reason: "CPAN build directories.",
             source: "CPAN: build_dir", note: "Leftover unpacked build trees.", processes: ["cpan"]),
        rule("kube-cache", .developerJunk, ".kube/cache", reason: "kubectl discovery and HTTP cache.",
             source: "kubectl: --cache-dir", note: "Rebuilt on the next kubectl call.", processes: ["kubectl"]),
        rule("gcloud-logs", .developerJunk, ".config/gcloud/logs", reason: "Google Cloud SDK logs.",
             source: "gcloud: configuration logs", note: "Diagnostic only.", processes: ["gcloud"]),
        rule("azure-cli-logs", .developerJunk, ".azure/logs", reason: "Azure CLI logs.",
             source: "Azure CLI: logs directory", note: "Diagnostic only.", processes: ["az"]),
        rule("xcode-ib-support", .developerJunk, "Library/Developer/Xcode/UserData/IB Support",
             reason: "Interface Builder rendering support cache.", source: "Xcode UserData",
             note: "Rebuilt when a storyboard is next opened.", bundles: ["com.apple.dt.Xcode"]),
        rule("simulator-device-tmp", .developerJunk, "Library/Developer/CoreSimulator/Devices/*/data/tmp",
             reason: "Temporary files inside simulator devices.", source: "CoreSimulator device layout",
             note: "Each device's tmp; device data and apps stay.",
             bundles: ["com.apple.iphonesimulator", "com.apple.dt.Xcode"]),
    ]

    // MARK: App-specific caches outside ~/Library/Caches

    private static let appCacheRules: [Rule] = [
        rule("steam-htmlcache", .userCaches, "Library/Application Support/Steam/htmlcache",
             reason: "Steam web view cache.", source: "Steam client data layout",
             note: "Rebuilt when Steam starts.", bundles: ["com.valvesoftware.steam"]),
        rule("steam-appcache", .userCaches, "Library/Application Support/Steam/appcache",
             reason: "Steam app-info cache.", source: "Steam client data layout",
             note: "Re-downloaded by Steam.", bundles: ["com.valvesoftware.steam"]),
        rule("steam-depotcache", .userCaches, "Library/Application Support/Steam/depotcache",
             reason: "Steam depot manifests cache.", source: "Steam client data layout",
             note: "Re-downloaded on the next update.", bundles: ["com.valvesoftware.steam"]),
        rule("steam-shadercache", .userCaches, "Library/Application Support/Steam/steamapps/shadercache",
             reason: "Steam shader pre-cache.", source: "Steam client data layout",
             note: "Recompiled or re-downloaded per game.", bundles: ["com.valvesoftware.steam"]),
        rule("steam-logs", .systemLogs, "Library/Application Support/Steam/logs",
             reason: "Steam client logs.", source: "Steam client data layout",
             note: "Diagnostic only.", bundles: ["com.valvesoftware.steam"]),
        rule("adobe-media-cache", .userCaches, "Library/Application Support/Adobe/Common/Media Cache Files",
             reason: "Adobe media cache (conformed audio, peak files).",
             source: "Adobe Premiere/After Effects docs: Media Cache",
             note: "Regenerated when media is next imported.", bundles: ["com.adobe.*"]),
        rule("adobe-media-cache-db", .userCaches, "Library/Application Support/Adobe/Common/Media Cache",
             reason: "Adobe media cache database.", source: "Adobe docs: Media Cache database",
             note: "Rebuilt with the media cache.", bundles: ["com.adobe.*"]),
        rule("davinci-cacheclip", .userCaches, "Movies/CacheClip", reason: "DaVinci Resolve render cache.",
             source: "DaVinci Resolve manual: cache files", note: "Re-rendered on playback.",
             bundles: ["com.blackmagic-design.DaVinciResolve*"]),
        rule("sketch-cache", .userCaches, "Library/Application Support/com.bohemiancoding.sketch3/cache",
             reason: "Sketch cache.", source: "Sketch data layout", note: "Rebuilt by Sketch.",
             bundles: ["com.bohemiancoding.sketch3"]),
        rule("minecraft-webcache", .userCaches, "Library/Application Support/minecraft/webcache2",
             reason: "Minecraft launcher web cache.", source: "Minecraft launcher data layout",
             note: "Rebuilt by the launcher.", bundles: ["com.mojang.minecraftlauncher"]),
        rule("minecraft-logs", .systemLogs, "Library/Application Support/minecraft/logs",
             reason: "Minecraft game logs.", source: "Minecraft data layout", note: "Diagnostic only.",
             processes: ["java"], bundles: ["com.mojang.minecraftlauncher"]),
        rule("zed-node-cache", .userCaches, "Library/Application Support/Zed/node/cache",
             reason: "Zed's bundled-Node npm cache.", source: "Zed data layout",
             note: "Re-fetched for language servers.", bundles: ["dev.zed.Zed"]),
        rule("googleupdater-crx", .userCaches, "Library/Application Support/Google/GoogleUpdater/crx_cache",
             reason: "Google updater download cache.", source: "Chromium updater layout",
             note: "Update payloads already applied or re-downloadable."),
        rule("messages-previews", .userCaches, "Library/Messages/Caches/Previews",
             reason: "Messages link and attachment previews.", source: "Messages data layout",
             note: "Previews are regenerated; attachments themselves stay.", bundles: ["com.apple.MobileSMS"]),
    ]
}
