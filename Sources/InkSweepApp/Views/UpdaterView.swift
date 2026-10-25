import AppKit
import InkKit
import SwiftUI
import InkSweepCore

/// Updater — which apps have a newer version, and one place to update them.
/// Feed updates InkSweep can verify (signature, same developer) are
/// installed here, the old version going to the Trash; App Store updates
/// open the App Store; anything unverifiable is offered as a download.
struct UpdaterView: View {
    @ObservedObject var model: AppModel
    @State private var showCurrent = false
    @State private var showNoSource = false

    private var result: UpdateCheckResult? { model.updateResult }
    private var verifiable: [AvailableUpdate] {
        (result?.updates ?? []).filter { $0.canInstallHere && model.updateReceipts[$0.id]?.outcome != .updated }
    }

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(
                title: "Updater",
                subtitle: Tool.updater.subtitle,
                trailing: result == nil ? nil : AnyView(
                    Button(model.updatesChecking ? "Checking…" : "Check again") { model.checkUpdates() }
                        .buttonStyle(InkButtonStyle())
                        .disabled(model.updatesChecking)
                )
            )
            if model.updatesChecking && result == nil {
                CenteredStage { checking }
            } else if let result {
                ScrollView {
                    VStack(spacing: 26) {
                        hero(result)
                        if !result.updates.isEmpty { updatesList(result.updates) }
                        quietLists(result)
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
                    .frame(maxWidth: 900)
                    .frame(maxWidth: .infinity)
                }
            } else {
                CenteredStage {
                    SealButton(character: "新", chinese: "检查", english: "Check for updates", size: 84) { model.checkUpdates() }
                }
            }
        }
        .task { if model.updateResult == nil && !model.updatesChecking { model.checkUpdates() } }
    }

    private var checking: some View {
        VStack(spacing: 16) {
            ZStack {
                EnsoLoop()
                VStack(spacing: 6) {
                    Text("检查中").font(Ink.brush(28)).foregroundStyle(Ink.vermilion)
                    Text("asking each app's update feed").font(Ink.serif(12)).foregroundStyle(Ink.faint)
                }
            }
            .frame(width: 320, height: 320)
            Text("Read-only: nothing is downloaded until you choose an update.")
                .font(Ink.serif(13)).foregroundStyle(Ink.faint)
        }
        .padding(.bottom, 40)
    }

    // MARK: Hero

    private func hero(_ result: UpdateCheckResult) -> some View {
        HStack(spacing: 40) {
            ZStack {
                Enso(progress: 1, vermilion: !result.updates.isEmpty)
                VStack(spacing: 2) {
                    Text("\(result.updates.count)").font(Ink.num(56))
                    Text(result.updates.count == 1 ? "update" : "updates").font(Ink.serif(13)).foregroundStyle(Ink.faint)
                }
            }
            .frame(width: 250, height: 250)

            VStack(alignment: .leading, spacing: 12) {
                Text(result.updates.isEmpty ? "Everything InkSweep can check is up to date."
                     : "\(result.updates.count) of your apps have a newer version.")
                    .font(Ink.serif(18, .semibold))
                Text(summary(result)).font(Ink.serif(13)).foregroundStyle(Ink.faint)
                    .fixedSize(horizontal: false, vertical: true)
                if !verifiable.isEmpty {
                    SealButton(character: "新", chinese: "更新", english: "Update \(verifiable.count) verified", size: 58) {
                        model.installAllFeedUpdates()
                    }
                    .disabled(!model.updating.isEmpty)
                    .padding(.top, 6)
                }
            }
            .frame(maxWidth: 420, alignment: .leading)
        }
        .padding(.top, 8)
    }

    private func summary(_ result: UpdateCheckResult) -> String {
        let store = result.updates.filter { if case .appStore = $0.source { return true } else { return false } }.count
        var parts: [String] = []
        if !verifiable.isEmpty { parts.append("\(verifiable.count) can be installed here — each download's signature and developer are verified first, and the old version goes to the Trash.") }
        if store > 0 { parts.append("\(store) update through the App Store.") }
        parts.append("\(result.upToDate.count) apps are current.")
        return parts.joined(separator: " ")
    }

    // MARK: Lists

    private func updatesList(_ updates: [AvailableUpdate]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            InkSectionHeader(chinese: "可更新", english: "Updates available").padding(.bottom, 4)
            ForEach(updates) { update in
                HStack(spacing: 14) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: update.app.url.path)).resizable().frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(update.app.rawName).font(Ink.serif(14, .semibold))
                        HStack(spacing: 6) {
                            Text(update.app.version ?? "–").foregroundStyle(Ink.faint)
                            Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(Ink.faint)
                            Text(update.newVersion).foregroundStyle(Ink.sumi)
                            Text("· " + sourceLabel(update)).foregroundStyle(Ink.faint)
                        }
                        .font(Ink.num(12, .regular))
                        if let line = statusLine(update) {
                            Text(line.text).font(Ink.serif(11)).foregroundStyle(line.tint)
                        }
                    }
                    Spacer()
                    if case .sparkle(let item) = update.source, let notes = item.releaseNotes {
                        Button("What's new") { NSWorkspace.shared.open(notes) }
                            .buttonStyle(.plain).font(Ink.serif(12)).foregroundStyle(Ink.faint)
                    }
                    action(update)
                }
                .inkCard()
            }
        }
    }

    @ViewBuilder
    private func action(_ update: AvailableUpdate) -> some View {
        if model.updateReceipts[update.id]?.outcome == .updated {
            Text("updated").font(Ink.serif(12)).foregroundStyle(Ink.faint)
        } else if model.updating.contains(update.id) {
            EnsoLoop(vermilion: true).frame(width: 34, height: 34)
        } else if update.canInstallHere {
            Button("Update") { model.install(update) }.buttonStyle(InkVermilionButtonStyle())
        } else if case .appStore = update.source {
            Button("App Store") { model.install(update) }.buttonStyle(InkButtonStyle())
        } else if case .sparkle(let item) = update.source, let url = item.url {
            Button("Download") { NSWorkspace.shared.open(url) }.buttonStyle(InkButtonStyle())
                .help("This feed cannot be verified here; the download opens in your browser.")
        }
    }

    private func sourceLabel(_ update: AvailableUpdate) -> String {
        switch update.source {
        case .appStore: return "App Store"
        case .sparkle: return update.canInstallHere ? "signed update" : "unverified — manual download"
        }
    }

    private func statusLine(_ update: AvailableUpdate) -> (text: String, tint: Color)? {
        guard let receipt = model.updateReceipts[update.id] else { return nil }
        switch receipt.outcome {
        case .updated: return ("Installed — the previous version is in the Trash.", Ink.faint)
        case .refused(let why): return ("Not installed: \(why).", Ink.vermilion)
        case .failed(let why): return ("Failed: \(why).", Ink.vermilion)
        }
    }

    private func quietLists(_ result: UpdateCheckResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            fold(chinese: "最新", english: "Up to date", count: result.upToDate.count, open: $showCurrent) {
                Text(result.upToDate.map(\.rawName).joined(separator: " · "))
                    .font(Ink.serif(12)).foregroundStyle(Ink.faint)
            }
            fold(chinese: "未知", english: "No update source", count: result.noSource.count, open: $showNoSource) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("These apps update themselves (Chrome, VS Code and others run their own updaters) or come from elsewhere, so InkSweep cannot see their latest version.")
                        .font(Ink.serif(12)).foregroundStyle(Ink.faint)
                    Text(result.noSource.map(\.rawName).joined(separator: " · "))
                        .font(Ink.serif(12)).foregroundStyle(Ink.faint)
                }
            }
            if !result.failed.isEmpty {
                Text("Could not reach: " + result.failed.map { "\($0.app.rawName) (\($0.reason))" }.joined(separator: ", "))
                    .font(Ink.serif(12)).foregroundStyle(Ink.vermilion)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fold<C: View>(chinese: String, english: String, count: Int, open: Binding<Bool>,
                               @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { open.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 8) {
                    InkSectionHeader(chinese: chinese, english: "\(english) · \(count)")
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Ink.faint)
                        .rotationEffect(.degrees(open.wrappedValue ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open.wrappedValue { content() }
        }
    }
}
