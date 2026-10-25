import Foundation
import InkSweepCore

func formatBytes(_ b: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f.string(fromByteCount: b)
}

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "scan"
let rest = args.dropFirst()

let engine = InkSweepEngine.standard()
let context = ScanContext(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)

func printReport(_ report: ScanReport) {
    print("InkSweep scan — \(report.findings.count) items, \(formatBytes(report.totalBytes)) reclaimable\n")
    for category in JunkCategory.allCases {
        let bytes = report.bytes(in: category)
        guard bytes > 0 else { continue }
        print(String(format: "  %-16@ %@", category.rawValue as NSString, formatBytes(bytes) as NSString))
    }
    for w in report.warnings { FileHandle.standardError.write(Data(("warning: " + w + "\n").utf8)) }
}

func optionValue(_ name: String) -> String? {
    guard let idx = rest.firstIndex(of: name) else { return nil }
    let after = rest.index(after: idx)
    return after < rest.endIndex ? rest[after] : nil
}

func encodeJSON<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = (try? encoder.encode(value)) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

switch command {
case "scan":
    let report = engine.scan(context: context)
    if rest.contains("--json") {
        let json = encodeJSON(report)
        if let out = optionValue("--output") {
            try? json.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(json)
        }
    } else {
        printReport(report)
        if rest.contains("--list") {
            print()
            for f in report.findings.sorted(by: { $0.sizeBytes > $1.sizeBytes }) {
                print("  \(formatBytes(f.sizeBytes))\t\(f.category.rawValue)\t\(f.url.path)")
            }
        }
        if let out = optionValue("--output") {
            // --output without --json: write the human summary
            var text = "InkSweep scan — \(report.findings.count) items, \(formatBytes(report.totalBytes)) reclaimable\n"
            for category in JunkCategory.allCases {
                let bytes = report.bytes(in: category)
                guard bytes > 0 else { continue }
                text += "  \(category.rawValue): \(formatBytes(bytes))\n"
            }
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
        }
    }

case "clean":
    let apply = rest.contains("--apply")
    let emptyTrash = rest.contains("--empty-trash")
    var categoryArg: JunkCategory?
    if let name = optionValue("--category") {
        guard let category = JunkCategory(rawValue: name) else {
            let valid = JunkCategory.allCases.map(\.rawValue).joined(separator: ", ")
            FileHandle.standardError.write(Data("error: unknown category '\(name)' (valid: \(valid))\n".utf8))
            exit(1)
        }
        categoryArg = category
    }
    var report = engine.scan(context: context)
    if let category = categoryArg {
        report.findings = report.findings(in: category)
    } else {
        // Same opt-in set as the app: these need to be asked for by name.
        let optIn: Set<JunkCategory> = [.installerFiles, .projectArtifacts]
        let skipped = report.findings.filter { optIn.contains($0.category) }
        report.findings.removeAll { optIn.contains($0.category) }
        if !skipped.isEmpty {
            FileHandle.standardError.write(Data("note: \(skipped.count) installer/build-artifact findings excluded — clean them with --category installerFiles or projectArtifacts\n".utf8))
        }
    }
    // Analysis-only findings (lipo waste, language files, root locations)
    // are never handed to the cleaner.
    let all = report.findings
    report.findings = all.filter { $0.reversible }
    let excluded = all.count - report.findings.count
    if excluded > 0 {
        FileHandle.standardError.write(Data("note: \(excluded) analysis-only findings excluded (universal binaries: use `inksweep thin`; root locations need the privileged helper)\n".utf8))
    }
    let trashItems = report.findings.filter { $0.category == .trash }
    let toTrash = report.findings.filter { $0.category != .trash }
    if !trashItems.isEmpty && !emptyTrash {
        FileHandle.standardError.write(Data("note: \(trashItems.count) Trash items excluded — add --empty-trash to delete them permanently\n".utf8))
    }
    let receipts = Cleaner().clean(toTrash, dryRun: !apply)
    let emptied = emptyTrash ? TrashEmptier().empty(trashItems, dryRun: !apply) : []
    let failures = (receipts + emptied).filter { if case .failed = $0.outcome { return true } else { return false } }
    let reclaimed = (receipts + emptied).reduce(Int64(0)) { $0 + $1.reclaimedBytes }
    if apply {
        print("Trashed \(receipts.filter { $0.reclaimedBytes > 0 }.count) items (recoverable), permanently emptied \(emptied.filter { $0.reclaimedBytes > 0 }.count) Trash items; reclaimed \(formatBytes(reclaimed)).")
        if !failures.isEmpty { print("\(failures.count) failed.") }
    } else {
        let wouldBytes = (toTrash + (emptyTrash ? trashItems : [])).reduce(Int64(0)) { $0 + $1.sizeBytes }
        print("Dry run: would trash \(toTrash.count) items\(emptyTrash ? " and permanently empty \(trashItems.count) Trash items" : ""), reclaiming \(formatBytes(wouldBytes)).")
        print("Re-run with --apply to act (Trash moves are recoverable; --empty-trash is not).")
    }

case "thin":
    let apply = rest.contains("--apply")
    let thinner = AppThinner()
    let targets = rest.filter { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    let apps = targets.isEmpty ? UniversalBinaryScanner.apps(in: context.applicationRoots) : targets
    var total: Int64 = 0
    for app in apps {
        switch thinner.plan(app: app, ignoringRunning: !apply) {
        case .failure(let refusal):
            if !targets.isEmpty { print("skip  \(app.lastPathComponent): \(refusal.rawValue)") }
        case .success(let plan):
            total += plan.savings
            guard apply else {
                print("\(formatBytes(plan.savings))\t\(plan.files.count) binaries\t\(app.path)")
                continue
            }
            let receipt = thinner.thin(app: app)
            switch receipt.outcome {
            case .thinned: print("thinned  \(app.lastPathComponent): \(formatBytes(receipt.savedBytes)) (original in the Trash)")
            case .refused(let why): print("skip  \(app.lastPathComponent): \(why)")
            case .failed(let why): print("FAILED  \(app.lastPathComponent): \(why)")
            }
        }
    }
    if !apply {
        print("\nThinnable without re-signing: \(formatBytes(total)). Re-run with --apply <App.app> to thin (original goes to the Trash).")
    }

case "updates":
    let apps = UninstallPlanner.installedApps(context: context)
    let result = await UpdateChecker().check(apps)
    for u in result.updates {
        let how: String
        switch u.source {
        case .sparkle(let item): how = item.edSignature == nil || u.app.edPublicKey == nil ? "feed (unsigned — manual)" : "feed (signed)"
        case .appStore: how = "App Store"
        }
        print("\(u.app.rawName)\t\(u.app.version ?? "–") → \(u.newVersion)\t\(how)")
    }
    for f in result.failed { print("?\t\(f.app.rawName)\t\(f.reason)") }
    print("\n\(result.updates.count) updates · \(result.upToDate.count) up to date · \(result.noSource.count) without an update source · \(result.failed.count) unreachable")

case "apps":
    let apps = UninstallPlanner.installedApps(context: context)
    for app in apps {
        print("\(app.bundleID)\t\(app.version ?? "–")\t\(app.rawName)")
    }
    FileHandle.standardError.write(Data("\(apps.count) apps\n".utf8))

case "uninstall":
    guard let bundleID = optionValue("--bundle-id") else {
        FileHandle.standardError.write(Data("usage: inksweep uninstall --bundle-id <id> [--apply]\n".utf8))
        exit(1)
    }
    let apply = rest.contains("--apply")
    let plan = UninstallPlanner().plan(bundleID: bundleID, context: context) { [] }
    for w in plan.warnings { FileHandle.standardError.write(Data(("warning: " + w + "\n").utf8)) }
    guard !plan.findings.isEmpty else {
        print("Nothing to uninstall for \(bundleID).")
        exit(1)
    }
    print("Uninstall plan for \(plan.app?.rawName ?? bundleID): \(plan.findings.count) targets, \(formatBytes(plan.totalBytes))\n")
    for f in plan.findings.sorted(by: { $0.sizeBytes > $1.sizeBytes }) {
        print("  \(formatBytes(f.sizeBytes))\t\(f.reason)\t\(f.url.path)")
    }
    if apply {
        let receipts = Cleaner().clean(plan.findings, dryRun: false)
        let ok = receipts.filter { if case .trashed = $0.outcome { return true } else { return false } }
        print("\nMoved \(ok.count)/\(receipts.count) targets to the Trash — recoverable.")
    } else {
        print("\nDry run — re-run with --apply to move these to the Trash (recoverable).")
    }

case "duplicates":
    let minMB = Int(optionValue("--min-size-mb") ?? "1") ?? 1
    let scanner = DuplicateFileScanner(minimumSizeBytes: Int64(minMB) * 1_000_000)
    let groups = scanner.scan(context: context)
    if rest.contains("--json") {
        print(encodeJSON(groups))
    } else {
        let wasted = groups.reduce(Int64(0)) { $0 + $1.wastedBytes }
        print("Duplicates — \(groups.count) groups, \(formatBytes(wasted)) reclaimable\n")
        for g in groups {
            print("  \(formatBytes(g.files[0].sizeBytes)) ×\(g.files.count)  \(formatBytes(g.wastedBytes)) wasted")
            for f in g.files {
                print("      \(f.url.path)")
            }
        }
    }

case "shred":
    let apply = rest.contains("--apply")
    let paths = rest.filter { !$0.hasPrefix("--") }
    guard !paths.isEmpty else {
        FileHandle.standardError.write(Data("usage: inksweep shred [--apply] <path>…\n".utf8))
        exit(1)
    }
    let urls = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    let receipts = Shredder().shred(urls, dryRun: !apply)
    for r in receipts {
        switch r.outcome {
        case .shredded: print("shredded  \(r.url.path)")
        case .skippedDryRun: print("would shred  \(r.url.path)")
        case .failed(let e): print("FAILED  \(r.url.path): \(e)")
        }
    }
    if !apply { print("\nDry run — nothing was destroyed. Re-run with --apply to shred permanently.") }

default:
    print("""
    inksweep — ink-styled macOS maintenance (engine CLI)

    Cleaning:
      inksweep scan [--list] [--json] [--output <file>]   Scan; summarize by category
      inksweep clean [--category <name>] [--apply] [--empty-trash]
                                                           Dry-run by default; --apply moves to Trash
      inksweep duplicates [--min-size-mb N] [--json]      Content-hashed duplicate finder

    Tools:
      inksweep apps                                        List installed apps (id, version, name)
      inksweep uninstall --bundle-id <id> [--apply]        Full uninstall plan (Trash, recoverable)
      inksweep shred [--apply] <path>…                     Permanent shred (3-pass overwrite)
      inksweep thin [--apply] [<App.app>…]                 Remove slices this Mac can't run (verified, original to Trash)
    """)
}
