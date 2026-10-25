import AppKit
import SwiftUI
import InkSweepCore

// MARK: - Motion helpers

/// Staggered entrance: fade + rise, delayed per index.
struct FadeIn: ViewModifier {
    let delay: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 16)
            .onAppear {
                withAnimation(.easeOut(duration: 0.45).delay(delay)) { shown = true }
            }
    }
}

extension View {
    func fadeIn(_ delay: Double = 0) -> some View { modifier(FadeIn(delay: delay)) }
}

// MARK: - Category presentation

extension JunkCategory {
    var title: String {
        switch self {
        case .userCaches: return "Caches"
        case .systemLogs: return "Logs"
        case .systemJunk: return "System Junk"
        case .trash: return "Trash"
        case .browserData: return "Privacy"
        case .appLeftovers: return "Leftovers"
        case .developerJunk: return "Developer"
        case .largeOldFiles: return "Large & Old"
        case .mailAttachments: return "Mail"
        case .installerFiles: return "Installers"
        case .projectArtifacts: return "Build Artifacts"
        }
    }

    var glyph: String {
        switch self {
        case .userCaches: return "internaldrive"
        case .systemLogs: return "doc.text"
        case .systemJunk: return "desktopcomputer"
        case .trash: return "trash"
        case .browserData: return "globe"
        case .appLeftovers: return "square.stack.3d.up"
        case .developerJunk: return "wrench.and.screwdriver"
        case .largeOldFiles: return "clock.arrow.circlepath"
        case .mailAttachments: return "envelope"
        case .installerFiles: return "shippingbox"
        case .projectArtifacts: return "hammer"
        }
    }
}

// MARK: - Tools

enum Tool: String, CaseIterable, Identifiable {
    case smartClean, uninstaller, duplicates, spaceLens, maintenance, shredder, updater, smartCare

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smartClean: return "Smart Clean"
        case .uninstaller: return "Uninstaller"
        case .duplicates: return "Duplicates"
        case .spaceLens: return "Space Lens"
        case .maintenance: return "Maintenance"
        case .shredder: return "Shredder"
        case .updater: return "Updater"
        case .smartCare: return "Smart Care"
        }
    }

    var glyph: String {
        switch self {
        case .smartClean: return "paintbrush"
        case .uninstaller: return "shippingbox"
        case .duplicates: return "square.on.square"
        case .spaceLens: return "camera.aperture"
        case .maintenance: return "wrench.and.screwdriver"
        case .shredder: return "scissors"
        case .updater: return "arrow.triangle.2.circlepath"
        case .smartCare: return "heart.text.square"
        }
    }

    var subtitle: String {
        switch self {
        case .smartClean: return "eleven kinds of clutter, one sweep"
        case .uninstaller: return "remove an app and everything it left"
        case .duplicates: return "byte-identical files, keep one"
        case .spaceLens: return "see where the disk went"
        case .maintenance: return "keep the machine tuned"
        case .shredder: return "delete permanently, three passes"
        case .updater: return "newer versions, verified before they are installed"
        case .smartCare: return "everything at a glance, one seal to care for it"
        }
    }
}

// MARK: - Model

@MainActor
final class AppModel: ObservableObject {
    /// One model for the window and the menu bar item.
    static let shared = AppModel()

    /// Set by the main window: opens it again after it was closed.
    var openMainWindow: (() -> Void)?

    /// Brings the main window forward on `tool` — reusing the open window,
    /// or opening one when it was closed.
    func showMainWindow(_ tool: Tool) {
        self.tool = tool
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    enum Phase: Equatable { case idle, scanning, cleaning }

    /// The tool on screen. `-InkSweepTool <rawValue>` opens on it (used for screenshots).
    @Published var tool: Tool = UserDefaults.standard.string(forKey: "InkSweepTool").flatMap(Tool.init(rawValue:)) ?? .smartCare

    // Smart clean
    @Published var phase: Phase = .idle
    @Published var report: ScanReport = ScanReport()
    /// Opt-in categories: emptying the Trash is irreversible; installers and
    /// build artifacts are worth a look before they go.
    @Published var included: Set<JunkCategory> = Set(JunkCategory.allCases)
        .subtracting([.trash, .installerFiles, .projectArtifacts])
    @Published var receipts: [CleanReceipt] = []
    @Published var receiptsWereApply = false

    // Live scan progress (honest: one update per scanner phase).
    @Published var scanPhaseTitle: String = ""
    @Published var scanFindingsSoFar = 0
    /// Share of scanners that have started, 0…1.
    @Published var scanProgress: Double = 0
    /// Categories whose scanner has run in this sweep, in order.
    @Published var scannedCategories: [JunkCategory] = []
    @Published var hasScanned = false
    @Published var lastScanDate: Date?

    /// What the last applied clean did, until the user acknowledges it.
    struct CleanCompletion: Equatable {
        let freed: Int64
        let trashed: Int
        let emptied: Int
        let failed: Int
    }
    @Published var completion: CleanCompletion? {
        didSet {
            guard let c = completion, c.freed > 0 else { return }
            lastClean = (Date(), c.freed)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastCleanDate")
            UserDefaults.standard.set(c.freed, forKey: "lastCleanFreed")
        }
    }
    /// The last clean that freed something, remembered across launches.
    @Published var lastClean: (date: Date, freed: Int64)? = {
        let t = UserDefaults.standard.double(forKey: "lastCleanDate")
        guard t > 0 else { return nil }
        return (Date(timeIntervalSince1970: t), Int64(UserDefaults.standard.integer(forKey: "lastCleanFreed")))
    }()

    // Uninstaller
    @Published var apps: [InstalledApp] = []
    @Published var appsLoading = false
    @Published var plan: UninstallPlanner.Plan?
    @Published var planLoading = false
    @Published var selectedApp: InstalledApp?

    // Duplicates
    @Published var duplicateGroups: [DuplicateGroup] = []
    @Published var duplicatesLoading = false
    @Published var duplicateSelection: Set<URL> = []
    @Published var duplicateReceipts: [CleanReceipt] = []
    @Published var duplicatesMinMB: Int = 1
    @Published var duplicatesScanned = false

    // Space Lens
    @Published var lensTree: SpaceNode?
    @Published var lensLoading = false
    @Published var lensRootName: String = "Home"

    // Shredder
    @Published var shredTargets: [URL] = []
    @Published var shredReceipts: [ShredReceipt] = []
    @Published var shredCompleted = false

    // Smart Care
    @Published var autoScanOnLaunch: Bool {
        didSet { UserDefaults.standard.set(autoScanOnLaunch, forKey: "autoScanOnLaunch") }
    }
    @Published var dailyScanAgentInstalled = false
    @Published var lastDailyScan: (date: Date, bytes: Int64, items: Int)?

    private let engine = InkSweepEngine.standard()
    private let planner = UninstallPlanner()

    static let smartCareAgentLabel = "com.amosw.inksweep.smartcare"
    static let smartCareOutputPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/InkSweep/smart-care.json")

    init() {
        UserDefaults.standard.register(defaults: ["autoScanOnLaunch": true])
        autoScanOnLaunch = UserDefaults.standard.bool(forKey: "autoScanOnLaunch")
        dailyScanAgentInstalled = FileManager.default.fileExists(atPath: Self.agentPlistPath())
        refreshLastDailyScan()
    }

    // MARK: Smart clean

    var selectedFindings: [Finding] {
        report.findings.filter { included.contains($0.category) && $0.reversible }
    }

    var selectedBytes: Int64 {
        selectedFindings.reduce(0) { $0 + $1.sizeBytes }
    }

    /// Analysis-only items in the selected categories (lipo waste, language
    /// files, root-owned locations) — visible but never cleaned.
    var selectedAnalysisOnly: Int {
        report.findings.filter { included.contains($0.category) && !$0.reversible }.count
    }

    var needsFullDiskAccess: Bool {
        report.warnings.contains { $0.contains("Full Disk Access") }
    }

    func scan() {
        guard phase == .idle else { return }
        phase = .scanning
        scanPhaseTitle = "starting"
        scanFindingsSoFar = 0
        scanProgress = 0
        scannedCategories = []
        completion = nil
        let engine = self.engine
        let total = Double(max(engine.scanners.count, 1))
        let context = ScanContext(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        Task.detached(priority: .userInitiated) {
            let report = engine.scan(context: context) { phase, count in
                Task { @MainActor in
                    self.scanPhaseTitle = phase
                    self.scanFindingsSoFar = count
                    if phase == "done" {
                        withAnimation(.easeOut(duration: 0.6)) { self.scanProgress = 1 }
                    } else {
                        withAnimation(.easeOut(duration: 0.6)) { self.scanProgress = min(1, self.scanProgress + 1 / total) }
                        if let category = JunkCategory(rawValue: phase), !self.scannedCategories.contains(category) {
                            self.scannedCategories.append(category)
                        }
                    }
                }
            }
            // Let the brush finish its circle before the result replaces it.
            try? await Task.sleep(nanoseconds: 450_000_000)
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.5)) {
                    self.report = report
                    self.phase = .idle
                    self.hasScanned = true
                    self.lastScanDate = Date()
                }
            }
        }
    }

    /// Selected Trash items; Smart Clean must confirm before emptying them.
    var selectedTrashFindings: [Finding] {
        selectedFindings.filter { $0.category == .trash }
    }

    func clean(apply: Bool) {
        guard phase == .idle else { return }
        let findings = selectedFindings
        guard !findings.isEmpty else { return }
        phase = .cleaning
        receiptsWereApply = apply
        Task.detached(priority: .userInitiated) {
            let receipts = Self.runClean(findings, apply: apply)
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.5)) {
                    self.receipts = receipts
                    self.phase = .idle
                    if apply {
                        self.completion = CleanCompletion(
                            freed: receipts.reduce(0) { $0 + $1.reclaimedBytes },
                            trashed: receipts.filter { if case .trashed = $0.outcome { return true } else { return false } }.count,
                            emptied: receipts.filter { $0.outcome == .deleted }.count,
                            failed: receipts.filter { if case .failed = $0.outcome { return true } else { return false } }.count)
                    }
                }
            }
        }
    }

    /// Acknowledge a finished clean and read the disk again.
    func finishClean() {
        completion = nil
        receipts = []
        scan()
    }

    func cleanCategory(_ category: JunkCategory, apply: Bool = true) {
        guard phase == .idle else { return }
        let findings = report.findings(in: category).filter(\.reversible)
        guard !findings.isEmpty else { return }
        phase = .cleaning
        receiptsWereApply = apply
        Task.detached(priority: .userInitiated) {
            let receipts = Self.runClean(findings, apply: apply)
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.4)) {
                    self.receipts = receipts
                    self.phase = .idle
                }
                if apply { self.scan() }
            }
        }
    }

    /// Trash items are permanently emptied; everything else goes to the Trash.
    nonisolated static func runClean(_ findings: [Finding], apply: Bool) -> [CleanReceipt] {
        let trash = findings.filter { $0.category == .trash }
        let rest = findings.filter { $0.category != .trash }
        return Cleaner().clean(rest, dryRun: !apply) + TrashEmptier().empty(trash, dryRun: !apply)
    }

    // MARK: Maintenance

    @Published var maintenanceOutcomes: [String: MaintenanceOutcome] = [:]
    @Published var maintenanceRunning: Set<String> = []
    /// Batch progress: tasks finished out of tasks queued (0 when idle).
    @Published var maintenanceDone = 0
    @Published var maintenanceTotal = 0

    struct MaintenanceJob: Sendable {
        let id: String
        let run: @Sendable () -> MaintenanceOutcome
    }

    /// Runs the chosen tasks one after another — several clean the disk, so
    /// they must not overlap — and re-reads the disk afterwards.
    func runMaintenanceBatch(_ jobs: [MaintenanceJob]) {
        guard maintenanceTotal == 0, !jobs.isEmpty else { return }
        maintenanceTotal = jobs.count
        maintenanceDone = 0
        for job in jobs { maintenanceOutcomes[job.id] = nil }
        Task.detached(priority: .userInitiated) {
            for job in jobs {
                await MainActor.run { _ = self.maintenanceRunning.insert(job.id) }
                let outcome = job.run()
                await MainActor.run {
                    self.maintenanceRunning.remove(job.id)
                    withAnimation(.easeOut(duration: 0.4)) {
                        self.maintenanceOutcomes[job.id] = outcome
                        self.maintenanceDone += 1
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
            await MainActor.run {
                self.maintenanceTotal = 0
                self.maintenanceDone = 0
                if self.phase == .idle { self.scan() }
            }
        }
    }

    /// A batch job that moves one category's findings to the Trash (or, for
    /// the Trash itself, empties it).
    func cleanJob(_ id: String, _ category: JunkCategory) -> MaintenanceJob {
        let findings = report.findings(in: category).filter(\.reversible)
        return MaintenanceJob(id: id) {
            let receipts = AppModel.runClean(findings, apply: true)
            let freed = receipts.reduce(Int64(0)) { $0 + $1.reclaimedBytes }
            let done = receipts.filter { $0.reclaimedBytes > 0 }.count
            return MaintenanceOutcome(status: done > 0 ? .applied : .unchanged,
                                      detail: done > 0 ? "\(done) items, \(Ink.bytes(freed))" : "nothing to remove")
        }
    }

    // MARK: Updates

    @Published var updateResult: UpdateCheckResult?
    @Published var updatesChecking = false
    @Published var updating: Set<String> = []
    @Published var updateReceipts: [String: UpdateReceipt] = [:]

    func checkUpdates() {
        guard !updatesChecking else { return }
        updatesChecking = true
        let context = ScanContext(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        Task.detached(priority: .userInitiated) {
            let apps = UninstallPlanner.installedApps(context: context)
            let result = await UpdateChecker().check(apps)
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.5)) {
                    self.apps = apps
                    self.updateResult = result
                    self.updatesChecking = false
                }
            }
        }
    }

    /// App Store updates open the App Store; feed updates are verified and
    /// installed, the old version going to the Trash.
    func install(_ update: AvailableUpdate) {
        if case .appStore(let page) = update.source {
            NSWorkspace.shared.open(page)
            return
        }
        guard !updating.contains(update.id) else { return }
        updating.insert(update.id)
        Task.detached(priority: .userInitiated) {
            let receipt = await AppUpdater().install(update)
            await MainActor.run {
                self.updating.remove(update.id)
                withAnimation { self.updateReceipts[update.id] = receipt }
            }
        }
    }

    /// Installs every verifiable feed update in turn.
    func installAllFeedUpdates() {
        for update in updateResult?.updates ?? [] where update.canInstallHere && updateReceipts[update.id] == nil {
            install(update)
        }
    }

    func runMaintenance(_ id: String, _ work: @escaping @Sendable (MaintenanceActions) -> MaintenanceOutcome) {
        guard !maintenanceRunning.contains(id) else { return }
        maintenanceRunning.insert(id)
        Task.detached(priority: .userInitiated) {
            let outcome = work(MaintenanceActions())
            await MainActor.run {
                self.maintenanceRunning.remove(id)
                withAnimation { self.maintenanceOutcomes[id] = outcome }
            }
        }
    }

    @Published var thinning: Set<URL> = []
    @Published var thinReceipts: [URL: ThinReceipt] = [:]

    func thinApp(_ app: URL) {
        guard !thinning.contains(app) else { return }
        thinning.insert(app)
        Task.detached(priority: .userInitiated) {
            let receipt = AppThinner().thin(app: app)
            await MainActor.run {
                self.thinning.remove(app)
                withAnimation { self.thinReceipts[app] = receipt }
            }
        }
    }

    /// The selected developer directory, read without triggering the CLT prompt.
    nonisolated static func developerDirectory() -> String? {
        let (status, out) = MaintenanceActions.executeCapturing(["/usr/bin/xcode-select", "-p"])
        let dir = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return status == 0 && !dir.isEmpty ? dir : nil
    }

    // MARK: Uninstaller

    nonisolated static func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    func loadApps() {
        guard !appsLoading else { return }
        appsLoading = true
        let context = ScanContext(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        Task.detached(priority: .userInitiated) {
            let apps = UninstallPlanner.installedApps(context: context)
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.4)) { self.apps = apps }
                self.appsLoading = false
            }
        }
    }

    func planUninstall(_ app: InstalledApp) {
        selectedApp = app
        plan = nil
        planLoading = true
        let planner = self.planner
        let context = ScanContext(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        Task.detached(priority: .userInitiated) {
            let plan = planner.plan(bundleID: app.bundleID, context: context) {
                Self.runningBundleIDs()
            }
            await MainActor.run {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    self.plan = plan
                }
                self.planLoading = false
            }
        }
    }

    func uninstallApply() {
        guard let plan, !plan.findings.isEmpty, !planLoading else { return }
        phase = .cleaning
        let findings = plan.findings
        Task.detached(priority: .userInitiated) {
            let receipts = Cleaner().clean(findings, dryRun: false)
            await MainActor.run {
                self.receipts = receipts
                self.phase = .idle
                withAnimation { self.plan = nil; self.selectedApp = nil }
                self.loadApps()
                self.scan()
            }
        }
    }

    // MARK: Duplicates

    func scanDuplicates() {
        guard !duplicatesLoading else { return }
        duplicatesLoading = true
        duplicateGroups = []
        duplicateSelection = []
        let scanner = DuplicateFileScanner(minimumSizeBytes: Int64(duplicatesMinMB) * 1_000_000)
        let context = ScanContext(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        Task.detached(priority: .userInitiated) {
            let groups = scanner.scan(context: context)
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.5)) { self.duplicateGroups = groups }
                var selection = Set<URL>()
                for g in groups {
                    for f in g.files.dropFirst() { selection.insert(f.url) }
                }
                self.duplicateSelection = selection
                self.duplicatesLoading = false
                self.duplicatesScanned = true
            }
        }
    }

    func cleanDuplicates() {
        let urls = duplicateSelection
        guard !urls.isEmpty else { return }
        duplicatesLoading = true
        let findings = duplicateGroups
            .flatMap(\.files)
            .filter { urls.contains($0.url) }
            .map {
                Finding(url: $0.url, category: .largeOldFiles, sizeBytes: $0.sizeBytes,
                        ruleID: "duplicate", reason: "Duplicate copy — the keeper stays.",
                        reversible: true, lastModified: $0.lastModified)
            }
        Task.detached(priority: .userInitiated) {
            let receipts = Cleaner().clean(findings, dryRun: false)
            await MainActor.run {
                self.duplicateReceipts = receipts
                self.duplicatesLoading = false
                self.scanDuplicates()
            }
        }
    }

    // MARK: Space Lens

    func loadLens(root: URL, name: String) {
        lensLoading = true
        lensRootName = name
        lensTree = nil
        let scanner = SpaceLensScanner()
        Task.detached(priority: .userInitiated) {
            let tree = scanner.tree(root: root)
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.8)) { self.lensTree = tree }
                self.lensLoading = false
            }
        }
    }

    // MARK: Shredder

    func shredApply() {
        guard !shredTargets.isEmpty else { return }
        let targets = shredTargets
        shredTargets = []
        Task.detached(priority: .userInitiated) {
            let receipts = Shredder().shred(targets, dryRun: false)
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.4)) {
                    self.shredReceipts = receipts
                    self.shredCompleted = true
                }
            }
        }
    }

    // MARK: Smart Care

    private static func agentPlistPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(smartCareAgentLabel).plist").path
    }

    func setDailyScanAgent(_ on: Bool) {
        let path = Self.agentPlistPath()
        let fm = FileManager.default
        if on {
            guard let cli = Bundle.main.url(forResource: "inksweep", withExtension: nil) else { return }
            try? fm.createDirectory(
                at: Self.smartCareOutputPath.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let plist: [String: Any] = [
                "Label": Self.smartCareAgentLabel,
                "ProgramArguments": [cli.path, "scan", "--json", "--output", Self.smartCareOutputPath.path],
                "StartCalendarInterval": ["Hour": 12, "Minute": 0],
            ]
            let data = (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
            if let data {
                try? data.write(to: URL(fileURLWithPath: path))
                // A plist dropped into LaunchAgents only loads at next login.
                Self.launchctl(["bootstrap", "gui/\(getuid())", path])
            }
        } else {
            Self.launchctl(["bootout", "gui/\(getuid())/\(Self.smartCareAgentLabel)"])
            try? fm.removeItem(atPath: path)
        }
        withAnimation { dailyScanAgentInstalled = fm.fileExists(atPath: path) }
    }

    private static func launchctl(_ arguments: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = arguments
        try? p.run()
        p.waitUntilExit()
    }

    private func refreshLastDailyScan() {
        guard let data = try? Data(contentsOf: Self.smartCareOutputPath),
              let report = try? JSONDecoder().decode(ScanReport.self, from: data),
              let date = (try? Self.smartCareOutputPath.resourceValues(
                  forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return }
        lastDailyScan = (date, report.totalBytes, report.findings.count)
    }

    func refreshSmartCareInfo() {
        refreshLastDailyScan()
        dailyScanAgentInstalled = FileManager.default.fileExists(atPath: Self.agentPlistPath())
    }
}

// MARK: - App entry

@main
struct InkSweepApp: App {
    @StateObject private var model = AppModel.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        MenuBarPanel.dumpIconIfAsked()
        // `-InkSweepAppearance light|dark` pins the appearance (used for screenshots).
        switch UserDefaults.standard.string(forKey: "InkSweepAppearance") {
        case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView(model: model)
                .frame(minWidth: 1100, minHeight: 720)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
