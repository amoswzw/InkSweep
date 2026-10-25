import InkKit
import SwiftUI
import InkSweepCore

/// Smart Care — the hub. One seal looks at everything at once (clutter,
/// maintenance, updates, space); one seal does the safe part of it. What
/// needs a decision — updates, large items — links to its own tool.
struct SmartCareView: View {
    @ObservedObject var model: AppModel
    @State private var caring = false

    private enum Stage: Equatable { case invite, checking, result, running, done }

    private var stage: Stage {
        if model.phase == .cleaning || model.maintenanceTotal > 0 { return .running }
        if caring && model.completion != nil { return .done }
        if model.phase == .scanning || model.updatesChecking { return .checking }
        return model.hasScanned && model.updateResult != nil ? .result : .invite
    }

    private var careTasks: [MaintenanceTask] {
        // Logs are already part of the clean; the rest of the recommended set runs here.
        MaintenanceTask.catalog(model).filter { $0.kind == .recommended && $0.id != "logs" }
    }
    private var updates: [AvailableUpdate] { model.updateResult?.updates ?? [] }
    private var spaceBytes: Int64 {
        [JunkCategory.projectArtifacts, .installerFiles, .largeOldFiles].reduce(0) { $0 + model.report.bytes(in: $1) }
    }
    private var thingsToDo: Int {
        (model.selectedFindings.isEmpty ? 0 : 1) + (careTasks.isEmpty ? 0 : 1)
            + (updates.isEmpty ? 0 : 1) + (spaceBytes > 0 ? 1 : 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(title: "Smart Care", subtitle: Tool.smartCare.subtitle)
            CenteredStage {
                VStack(spacing: 26) {
                    hero
                    if stage == .result { areas.transition(.opacity.combined(with: .offset(y: 10))) }
                    if stage == .result || stage == .invite { schedule.padding(.top, 10) }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 30)
                .frame(maxWidth: 940)
            }
        }
        .animation(.easeOut(duration: 0.45), value: stage)
        .task { model.refreshSmartCareInfo() }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 14) {
            ZStack {
                Enso(progress: progress, vermilion: stage == .running || stage == .done)
                    .animation(.easeOut(duration: 0.6), value: progress)
                centre.transition(.opacity).id(stage)
            }
            .frame(width: 330, height: 330)
            Text(caption).font(Ink.serif(13)).foregroundStyle(Ink.faint).multilineTextAlignment(.center)
        }
    }

    private var progress: Double {
        switch stage {
        case .invite: return 0
        case .checking: return model.scanProgress * 0.85 + (model.updatesChecking ? 0 : 0.15)
        case .result, .done: return 1
        case .running:
            let total = Double(max(model.maintenanceTotal, 1))
            return model.phase == .cleaning ? 0.4 : 0.4 + 0.6 * Double(model.maintenanceDone) / total
        }
    }

    @ViewBuilder
    private var centre: some View {
        switch stage {
        case .invite:
            SealButton(character: "照", chinese: "照料", english: "Check everything", size: 92) { start() }
        case .checking:
            VStack(spacing: 6) {
                Text("照料中").font(Ink.brush(30)).foregroundStyle(Ink.vermilion)
                Text(model.phase == .scanning ? "reading the disk" : "checking for updates")
                    .font(Ink.serif(12)).foregroundStyle(Ink.faint)
            }
        case .result:
            VStack(spacing: 4) {
                Text(thingsToDo == 0 ? "安" : "\(thingsToDo)")
                    .font(thingsToDo == 0 ? Ink.brush(56) : Ink.num(58))
                Text(thingsToDo == 0 ? "all in order" : (thingsToDo == 1 ? "thing to look at" : "things to look at"))
                    .font(Ink.serif(12)).foregroundStyle(Ink.faint)
                SealButton(character: "净", chinese: "照料", english: "Run care", size: 56) { runCare() }
                    .disabled(model.selectedFindings.isEmpty && careTasks.isEmpty)
                    .padding(.top, 10)
            }
        case .running:
            VStack(spacing: 6) {
                Text("照料中").font(Ink.brush(30)).foregroundStyle(Ink.vermilion)
                Text(model.phase == .cleaning ? "moving clutter to the Trash" : "running maintenance")
                    .font(Ink.serif(12)).foregroundStyle(Ink.faint)
            }
        case .done:
            VStack(spacing: 8) {
                InkSeal(character: "净", size: 84)
                Text(Ink.bytes(model.completion?.freed ?? 0)).font(Ink.num(30))
                Text("freed").font(Ink.serif(12)).foregroundStyle(Ink.faint)
            }
        }
    }

    private var caption: String {
        switch stage {
        case .invite: return "One look at everything: clutter, maintenance, updates and space. Nothing changes until you choose."
        case .checking: return "Reading caches, logs and leftovers, and asking each app's update feed."
        case .result:
            return "Run care cleans what is selected (to the Trash) and runs \(careTasks.count) recommended maintenance tasks. Updates and large items wait for you."
        case .running: return "Everything removed goes to the Trash first."
        case .done:
            return "\(model.completion?.trashed ?? 0) items moved to the Trash, \(careTasks.count) maintenance tasks run."
        }
    }

    // MARK: Areas

    private var areas: some View {
        HStack(alignment: .top, spacing: 0) {
            AreaColumn(character: "清", chinese: "清理", english: "Cleanup",
                       value: Ink.bytes(model.selectedBytes),
                       detail: "\(model.selectedFindings.count) items selected",
                       link: "Review") { model.tool = .smartClean }
            InkRule(seed: 3, vertical: true).frame(height: 120)
            AreaColumn(character: "维", chinese: "维护", english: "Maintenance",
                       value: "\(careTasks.count + 1)",
                       detail: "recommended tasks",
                       link: "Open") { model.tool = .maintenance }
            InkRule(seed: 5, vertical: true).frame(height: 120)
            AreaColumn(character: "新", chinese: "更新", english: "Updates",
                       value: "\(updates.count)",
                       detail: updates.isEmpty ? "all current" : "\(updates.filter(\.canInstallHere).count) install here",
                       link: "Review") { model.tool = .updater }
            InkRule(seed: 8, vertical: true).frame(height: 120)
            AreaColumn(character: "空", chinese: "空间", english: "Space",
                       value: Ink.bytes(spaceBytes),
                       detail: "build artifacts, installers, old files",
                       link: "Review") { model.tool = .smartClean }
        }
    }

    // MARK: Schedule

    private var cliBundled: Bool { Bundle.main.url(forResource: "inksweep", withExtension: nil) != nil }

    private var schedule: some View {
        VStack(alignment: .leading, spacing: 4) {
            InkSectionHeader(chinese: "定时", english: "Schedule")
            Toggle("Check when InkSweep opens", isOn: $model.autoScanOnLaunch)
                .toggleStyle(.switch).font(Ink.serif(13))
                .inkCard()
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Daily background check at 12:00", isOn: Binding(
                    get: { model.dailyScanAgentInstalled },
                    set: { model.setDailyScanAgent($0) }
                ))
                .toggleStyle(.switch).font(Ink.serif(13))
                .disabled(!cliBundled)
                Text(dailyNote).font(Ink.serif(11)).foregroundStyle(Ink.faint)
            }
            .inkCard()
        }
        .frame(maxWidth: 620)
    }

    private var dailyNote: String {
        if !cliBundled { return "Needs the packaged app: the daily check runs the engine bundled inside InkSweep.app." }
        if let last = model.lastDailyScan {
            return "Last background check: \(last.date.formatted(date: .abbreviated, time: .shortened)) — \(Ink.bytes(last.bytes)) found in \(last.items) items. Nothing is cleaned automatically."
        }
        return "A user LaunchAgent reads the disk once a day and records what it finds. Nothing is cleaned automatically."
    }

    // MARK: Actions

    private func start() {
        caring = false
        model.completion = nil
        model.scan()
        model.checkUpdates()
    }

    private func runCare() {
        caring = true
        if !model.selectedFindings.isEmpty, model.selectedTrashFindings.isEmpty {
            model.clean(apply: true)
        }
        model.runMaintenanceBatch(careTasks.compactMap { $0.job(model) })
    }
}

/// One area of the care result: its character, what was found, where to act.
private struct AreaColumn: View {
    let character: String
    let chinese: String
    let english: String
    let value: String
    let detail: String
    let link: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text(character).font(Ink.brush(30)).foregroundStyle(Ink.sumi)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(chinese).font(Ink.brush(14))
                Text(english).font(Ink.serif(12)).foregroundStyle(Ink.faint)
            }
            Text(value).font(Ink.num(22)).padding(.top, 2)
            Text(detail).font(Ink.serif(11)).foregroundStyle(Ink.faint).multilineTextAlignment(.center)
            Button(link) { withAnimation(.easeOut(duration: 0.22)) { action() } }
                .buttonStyle(InkButtonStyle())
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
    }
}
