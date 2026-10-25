import AppKit
import InkKit
import SwiftUI
import InkSweepCore

/// Uninstaller — pick an installed app, see everything it owns, remove it
/// all (reversibly, through the Trash).
struct UninstallerView: View {
    @ObservedObject var model: AppModel
    @State private var search = ""
    @State private var confirming = false

    private var filtered: [InstalledApp] {
        guard !search.isEmpty else { return model.apps }
        let q = search.lowercased()
        return model.apps.filter {
            $0.rawName.lowercased().contains(q) || $0.bundleID.contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(title: "Uninstaller", subtitle: Tool.uninstaller.subtitle)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    InkSearchField(text: $search, prompt: "Search \(model.apps.count) apps")
                        .padding(.horizontal, 32)
                        .padding(.bottom, 6)
                    if model.appsLoading && model.apps.isEmpty {
                        EnsoLoop().frame(width: 160, height: 160).frame(maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(filtered) { app in
                                    AppRow(app: app, selected: model.selectedApp?.id == app.id)
                                        .onTapGesture { model.planUninstall(app) }
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 4)
                        }
                    }
                }
                .frame(width: 380)

                InkRule(seed: 9, vertical: true).padding(.vertical, 12)

                ScrollView {
                    planDetail
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .task { if model.apps.isEmpty { model.loadApps() } }
        .confirmationDialog(
            "Uninstall \(model.selectedApp?.rawName ?? "")?",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button("Move \(model.plan?.findings.count ?? 0) items to Trash", role: .destructive) {
                model.uninstallApply()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything in the plan goes to the Trash — recoverable from there.")
        }
    }

    @ViewBuilder
    private var planDetail: some View {
        if let app = model.selectedApp {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 16) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                        .resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.rawName).font(Ink.serif(22, .semibold))
                        Text("\(app.bundleID) · v\(app.version ?? "–")")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.faint)
                    }
                }

                if model.planLoading {
                    HStack(spacing: 14) {
                        EnsoLoop().frame(width: 70, height: 70)
                        Text("Tracing everything this app owns…").font(Ink.serif(13)).foregroundStyle(Ink.faint)
                    }
                } else if let plan = model.plan {
                    ForEach(plan.warnings, id: \.self) { w in
                        Text(w).font(Ink.serif(12)).foregroundStyle(Ink.vermilion)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(Ink.bytes(plan.totalBytes)).font(Ink.num(36))
                        Text("in \(plan.findings.count) places — the app, its containers, preferences, caches, support data and login items")
                            .font(Ink.serif(12)).foregroundStyle(Ink.faint)
                    }
                    VStack(spacing: 0) {
                        ForEach(plan.findings.sorted { $0.sizeBytes > $1.sizeBytes }) { f in
                            FindingRow(finding: f).padding(.leading, -36)
                                .overlay(alignment: .bottom) { Rectangle().fill(Ink.line).frame(height: 1) }
                        }
                    }
                    HStack {
                        Spacer()
                        SealButton(character: "卸", chinese: "卸载", english: "Uninstall", size: 64) { confirming = true }
                            .disabled(plan.findings.isEmpty)
                        Spacer()
                    }
                    .padding(.top, 10)
                    Text("Everything moves to the Trash — recoverable until you empty it.")
                        .font(Ink.serif(11)).foregroundStyle(Ink.faint)
                        .frame(maxWidth: .infinity)
                }
            }
            .id(model.selectedApp?.id)
            .fadeIn(0.05)
        } else {
            InkEmptyState(character: "卸", chinese: "选择应用", english: "Choose an app",
                          detail: "Pick an app on the left to see everything it owns before anything is removed.")
                .frame(maxWidth: .infinity)
                .padding(.top, 120)
        }
    }
}

private struct AppRow: View {
    let app: InstalledApp
    let selected: Bool
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                .resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.rawName)
                    .font(Ink.serif(13, selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Ink.vermilion : Ink.sumi)
                Text(app.bundleID)
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Ink.faint)
                    .lineLimit(1)
            }
            Spacer()
            Text(app.version ?? "–")
                .font(Ink.num(11, .regular)).foregroundStyle(Ink.faint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Ink.sumi.opacity(0.06) : (hovered ? Ink.sumi.opacity(0.03) : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .accessibilityAddTraits(.isButton)
    }
}
