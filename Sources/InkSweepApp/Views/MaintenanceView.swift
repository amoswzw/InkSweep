import InkKit
import SwiftUI
import InkSweepCore

/// Maintenance — tick what to run, press one seal. Recommended tasks are
/// preselected; irreversible ones are confirmed by name; tasks that need
/// administrator rights are shown, locked, for the helper phase.
struct MaintenanceView: View {
    @ObservedObject var model: AppModel
    @State private var checked: Set<String> = []
    @State private var focus: String = "quicklook"
    @State private var confirming = false
    @State private var showingThinning = false
    @State private var seeded = false

    private var tasks: [MaintenanceTask] { MaintenanceTask.catalog(model) }
    private var running: Bool { model.maintenanceTotal > 0 }
    private var chosen: [MaintenanceTask] { tasks.filter { checked.contains($0.id) } }
    private var irreversibleChosen: [MaintenanceTask] { chosen.filter { $0.kind == .irreversible } }

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(title: "Maintenance", subtitle: Tool.maintenance.subtitle)
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        section("推荐", "Recommended", .recommended)
                        section("按需", "When you need it", .optional, also: [.irreversible, .separate])
                        section("需助手", "Needs administrator rights", .locked)
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 8)
                }
                .frame(width: 440)

                InkRule(seed: 13, vertical: true).padding(.vertical, 12)

                CenteredStage { stage.padding(.horizontal, 28).padding(.bottom, 30) }
            }
        }
        .task {
            if model.report.findings.isEmpty { model.scan() }
            if !seeded { checked = MaintenanceTask.recommendedIDs(model); seeded = true }
        }
        .sheet(isPresented: $showingThinning) { ThinningSheet(model: model) }
        .confirmationDialog("Run \(chosen.count) tasks?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Run, including \(irreversibleChosen.count) that cannot be undone", role: .destructive) { run() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Cannot be undone: " + irreversibleChosen.map(\.title).joined(separator: ", ") + ".")
        }
    }

    // MARK: Task list

    private func section(_ chinese: String, _ english: String, _ kind: MaintenanceTask.Kind,
                         also: [MaintenanceTask.Kind] = []) -> some View {
        let rows = tasks.filter { $0.kind == kind || also.contains($0.kind) }
        return VStack(alignment: .leading, spacing: 0) {
            InkSectionHeader(chinese: chinese, english: english).padding(.bottom, 4)
            ForEach(rows) { row($0) }
        }
    }

    private func row(_ task: MaintenanceTask) -> some View {
        let isOn = Binding(
            get: { checked.contains(task.id) },
            set: { on in if on { checked.insert(task.id) } else { checked.remove(task.id) } })
        return HStack(spacing: 12) {
            switch task.kind {
            case .locked:
                Image(systemName: "lock").font(.system(size: 11)).foregroundStyle(Ink.faint).frame(width: 15)
            case .separate:
                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Ink.faint).frame(width: 15)
            default:
                InkCheck(isOn: isOn, label: task.title).disabled(running)
            }
            Text(task.chinese).font(Ink.brush(15)).foregroundStyle(task.kind == .locked ? Ink.faint : Ink.sumi)
                .frame(width: 58, alignment: .leading).lineLimit(1)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title).font(Ink.serif(13, focus == task.id ? .semibold : .regular))
                    .foregroundStyle(task.kind == .locked ? Ink.faint : Ink.sumi)
                if let status = status(task) {
                    Text(status.text).font(Ink.serif(11)).foregroundStyle(status.tint)
                } else if task.kind == .irreversible {
                    Text("cannot be undone").font(Ink.serif(11)).foregroundStyle(Ink.vermilion.opacity(0.8))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(focus == task.id ? Ink.sumi.opacity(0.05) : .clear))
        .overlay(alignment: .bottom) { Rectangle().fill(Ink.line).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture {
            focus = task.id
            if task.kind == .separate { showingThinning = true }
        }
    }

    private func status(_ task: MaintenanceTask) -> (text: String, tint: Color)? {
        if model.maintenanceRunning.contains(task.id) { return ("running…", Ink.vermilion) }
        guard let outcome = model.maintenanceOutcomes[task.id] else { return nil }
        switch outcome.status {
        case .failed: return ("✕ " + outcome.detail, Ink.vermilion)
        case .skipped: return ("skipped — " + outcome.detail, Ink.faint)
        case .applied, .unchanged: return ("✓ " + outcome.detail, Ink.faint)
        }
    }

    // MARK: Stage

    private var stage: some View {
        VStack(spacing: 22) {
            ZStack {
                Enso(progress: running ? Double(model.maintenanceDone) / Double(max(model.maintenanceTotal, 1)) : (lastRunFinished ? 1 : 0))
                    .animation(.easeOut(duration: 0.6), value: model.maintenanceDone)
                if running {
                    VStack(spacing: 6) {
                        Text("运行中").font(Ink.brush(28)).foregroundStyle(Ink.vermilion)
                        Text("\(model.maintenanceDone) of \(model.maintenanceTotal)").font(Ink.num(20))
                    }
                } else {
                    SealButton(character: "维", chinese: "运行", english: chosen.isEmpty ? "Choose tasks" : "Run \(chosen.count) tasks", size: 84) {
                        irreversibleChosen.isEmpty ? run() : (confirming = true)
                    }
                    .disabled(chosen.isEmpty)
                }
            }
            .frame(width: 320, height: 320)

            if let task = tasks.first(where: { $0.id == focus }) {
                VStack(spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(task.chinese).font(Ink.brush(22))
                        Text(task.title).font(Ink.serif(16, .semibold))
                    }
                    Text(task.explanation)
                        .font(Ink.serif(13)).foregroundStyle(Ink.faint)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    if task.kind == .separate {
                        Button("Choose apps to thin…") { showingThinning = true }.buttonStyle(InkButtonStyle())
                    }
                }
                .id(task.id)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: focus)
    }

    private var lastRunFinished: Bool {
        !model.maintenanceOutcomes.isEmpty && model.maintenanceRunning.isEmpty
    }

    private func run() {
        let jobs = chosen.compactMap { $0.job(model) }
        model.runMaintenanceBatch(jobs)
    }
}

/// Per-app binary thinning. Each app is thinned on a verified copy; the
/// original goes to the Trash, so every run is recoverable.
private struct ThinningSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirming: Finding?

    private var candidates: [Finding] {
        model.report.findings.filter { $0.ruleID == "universal-binary" }.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("瘦身").font(Ink.brush(24))
                Text("Thin universal binaries").font(Ink.serif(15, .semibold))
            }
            Text("Only code sealed by its own signature is thinned; the copy must pass codesign and Gatekeeper before it replaces the app. The original goes to the Trash.")
                .font(Ink.serif(12)).foregroundStyle(Ink.faint)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(candidates) { finding in row(finding) }
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(InkButtonStyle()) }
        }
        .padding(24)
        .frame(width: 560, height: 500)
        .background(Ink.paper)
        .confirmationDialog(
            "Thin \(confirming?.url.deletingPathExtension().lastPathComponent ?? "")?",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
        ) {
            Button("Thin") { if let f = confirming { model.thinApp(f.url) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Quit the app first. The original stays in the Trash until you empty it.")
        }
    }

    @ViewBuilder
    private func row(_ finding: Finding) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: finding.url.path)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(finding.url.deletingPathExtension().lastPathComponent)
                    .font(Ink.serif(13, .semibold)).foregroundStyle(Ink.sumi)
                Text(status(finding.url) ?? Ink.bytes(finding.sizeBytes) + " can go")
                    .font(Ink.serif(12)).foregroundStyle(Ink.faint)
            }
            Spacer()
            Button("Thin") { confirming = finding }
                .buttonStyle(InkButtonStyle())
                .disabled(model.thinning.contains(finding.url) || model.thinReceipts[finding.url]?.outcome == .thinned)
        }
        .inkCard()
    }

    private func status(_ app: URL) -> String? {
        if model.thinning.contains(app) { return "thinning…" }
        guard let receipt = model.thinReceipts[app] else { return nil }
        switch receipt.outcome {
        case .thinned: return "thinned — \(Ink.bytes(receipt.savedBytes)) saved"
        case .refused(let why): return "skipped — \(why)"
        case .failed(let why): return why
        }
    }
}
