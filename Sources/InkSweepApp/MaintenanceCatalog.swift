import InkSweepCore

/// Every maintenance task the app offers, shared by the Maintenance tool and
/// Smart Care: what it is called, what it does in plain words, how safe it
/// is, and the job that performs it.
struct MaintenanceTask: Identifiable {
    enum Kind {
        /// Safe and undoable or read-only: preselected.
        case recommended
        /// Fine to run, but only when you want it.
        case optional
        /// Cannot be undone: always confirmed first.
        case irreversible
        /// Has its own screen (binary thinning).
        case separate
        /// Needs the privileged helper, which does not exist yet.
        case locked
    }

    let id: String
    let character: String
    let chinese: String
    let title: String
    let explanation: String
    let kind: Kind
    let job: (AppModel) -> AppModel.MaintenanceJob?
}

extension MaintenanceTask {
    @MainActor
    static func catalog(_ model: AppModel) -> [MaintenanceTask] {
        func action(_ id: String, _ work: @escaping @Sendable (MaintenanceActions) -> MaintenanceOutcome)
            -> (AppModel) -> AppModel.MaintenanceJob? {
            { _ in AppModel.MaintenanceJob(id: id) { work(MaintenanceActions()) } }
        }
        let logs = model.report.findings(in: .systemLogs).filter(\.reversible)
        let trash = model.report.findings(in: .trash)
        let thin = model.report.findings.filter { $0.ruleID == "universal-binary" }
        return [
            MaintenanceTask(
                id: "quicklook", character: "览", chinese: "预览", title: "Refresh Quick Look",
                explanation: "Resets Quick Look's thumbnail cache and reloads its preview plug-ins. Fixes blank or stale previews in Finder.",
                kind: .recommended, job: action("quicklook") { $0.refreshQuickLook() }),
            MaintenanceTask(
                id: "verify", character: "验", chinese: "校验", title: "Verify startup disk",
                explanation: "A read-only check of the startup disk's file system (diskutil verifyVolume /). Nothing is changed; if it finds problems, run First Aid in Disk Utility.",
                kind: .recommended, job: action("verify") { $0.verifyStartupDisk() }),
            MaintenanceTask(
                id: "logs", character: "志", chinese: "日志", title: "Clear user logs",
                explanation: "Moves the logs apps keep in ~/Library/Logs to the Trash — \(logs.count) items, \(Ink.bytes(logs.reduce(0) { $0 + $1.sizeBytes })). Apps start new logs when they need them.",
                kind: .recommended, job: { $0.cleanJob("logs", .systemLogs) }),
            MaintenanceTask(
                id: "overrides", character: "复", chinese: "复原", title: "Remove legacy tweak overrides",
                explanation: "Removes the App Nap and disk-image-verification overrides old tweak tools leave behind, so macOS defaults apply again. Only those settings are touched.",
                kind: .recommended, job: action("overrides") { $0.removeLegacyOverrides() }),
            MaintenanceTask(
                id: "dsstore", character: "净", chinese: "禁写", title: "Stop .DS_Store on network & USB drives",
                explanation: "Tells Finder not to write its hidden .DS_Store files onto network shares and USB drives. A Finder preference you can turn back on.",
                kind: .optional, job: action("dsstore") { $0.preventNetworkDSStore() }),
            MaintenanceTask(
                id: "browser", character: "私", chinese: "隐私", title: "Clear browser data",
                explanation: "Moves history, cookies and download lists of closed browsers to the Trash. You will be signed out of websites. Running browsers are skipped.",
                kind: .optional, job: { $0.cleanJob("browser", .browserData) }),
            MaintenanceTask(
                id: "trash", character: "篓", chinese: "清空", title: "Empty Trash",
                explanation: "Deletes the \(trash.count) items in the Trash for good (\(Ink.bytes(trash.reduce(0) { $0 + $1.sizeBytes }))).",
                kind: .irreversible, job: { $0.cleanJob("trash", .trash) }),
            MaintenanceTask(
                id: "quarantine", character: "录", chinese: "记录", title: "Clear download history",
                explanation: "Clears Gatekeeper's log of what was downloaded from where. Files keep their quarantine flags; only the history is erased.",
                kind: .irreversible, job: action("quarantine") { $0.clearQuarantineHistory() }),
            MaintenanceTask(
                id: "simulators", character: "模", chinese: "模拟器", title: "Delete unavailable simulators",
                explanation: "Deletes iOS simulators whose runtime is no longer installed, with their data. Needs Xcode.",
                kind: .irreversible,
                job: action("simulators") { $0.deleteUnavailableSimulators(developerDirectory: AppModel.developerDirectory()) }),
            MaintenanceTask(
                id: "thin", character: "瘦", chinese: "瘦身", title: "Thin universal binaries",
                explanation: "Removes the code this Mac cannot run from \(thin.count) apps — \(Ink.bytes(thin.reduce(0) { $0 + $1.sizeBytes })) — without breaking their signatures. Chosen app by app.",
                kind: .separate, job: { _ in nil }),
            MaintenanceTask(
                id: "dns", character: "网", chinese: "域名", title: "Refresh DNS cache",
                explanation: "Signals mDNSResponder through launchd to drop cached DNS answers. Needs administrator rights.",
                kind: .locked, job: { _ in nil }),
            MaintenanceTask(
                id: "spotlight", character: "索", chinese: "索引", title: "Rebuild Spotlight index",
                explanation: "Erases and rebuilds the startup disk's Spotlight index (mdutil -E). Needs administrator rights.",
                kind: .locked, job: { _ in nil }),
            MaintenanceTask(
                id: "periodic", character: "期", chinese: "周期", title: "Run maintenance scripts",
                explanation: "Runs macOS's daily, weekly and monthly maintenance scripts (periodic). Needs administrator rights.",
                kind: .locked, job: { _ in nil }),
            MaintenanceTask(
                id: "permissions", character: "权", chinese: "权限", title: "Reset home folder permissions",
                explanation: "Resets ownership and permissions in your home folder (diskutil resetUserPermissions). Needs administrator rights.",
                kind: .locked, job: { _ in nil }),
            MaintenanceTask(
                id: "routes", character: "路", chinese: "路由", title: "Flush network routes",
                explanation: "Flushes the routing table and ARP cache. Needs administrator rights.",
                kind: .locked, job: { _ in nil }),
        ]
    }

    @MainActor
    static func recommendedIDs(_ model: AppModel) -> Set<String> {
        Set(catalog(model).filter { $0.kind == .recommended }.map(\.id))
    }
}
