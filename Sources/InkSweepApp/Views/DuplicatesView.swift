import InkKit
import SwiftUI
import InkSweepCore

/// Duplicates — byte-identical files; keep the oldest, trash the rest.
/// Staged like Smart Clean: a seal invites the search, an ensō is drawn
/// while files are hashed, then the groups are laid out to choose from.
struct DuplicatesView: View {
    @ObservedObject var model: AppModel

    private var totalWasted: Int64 {
        model.duplicateGroups.reduce(0) { $0 + $1.wastedBytes }
    }
    private var selectedBytes: Int64 {
        model.duplicateGroups
            .flatMap(\.files)
            .filter { model.duplicateSelection.contains($0.url) }
            .reduce(0) { $0 + $1.sizeBytes }
    }
    private let sizes: [(Int, String)] = [(1, "1 MB+"), (10, "10 MB+"), (50, "50 MB+"), (100, "100 MB+")]

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(
                title: "Duplicates",
                subtitle: Tool.duplicates.subtitle,
                trailing: model.duplicateGroups.isEmpty ? nil : AnyView(
                    HStack(spacing: 14) {
                        InkChoice(label: "files", selection: $model.duplicatesMinMB, options: sizes)
                        Button("Search again") { model.scanDuplicates() }
                            .buttonStyle(InkButtonStyle())
                            .disabled(model.duplicatesLoading)
                    }
                )
            )
            if model.duplicateGroups.isEmpty {
                stage.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                results
            }
        }
    }

    // MARK: Before results

    @ViewBuilder
    private var stage: some View {
        VStack(spacing: 18) {
            ZStack {
                if model.duplicatesLoading {
                    EnsoLoop()
                    VStack(spacing: 6) {
                        Text("寻找中").font(Ink.brush(26)).foregroundStyle(Ink.vermilion)
                        Text("hashing files").font(Ink.serif(12)).foregroundStyle(Ink.faint)
                    }
                } else if model.duplicatesScanned {
                    Enso(progress: 1)
                    InkEmptyState(character: "一", chinese: "无重复", english: "No duplicates")
                } else {
                    Enso(progress: 0)
                    SealButton(character: "寻", chinese: "寻找", english: "Find duplicates", size: 88) {
                        model.scanDuplicates()
                    }
                }
            }
            .frame(width: 340, height: 340)

            if model.duplicatesLoading {
                Text("Grouping by size, comparing the first 64 KB, then verifying whole files.")
                    .font(Ink.serif(13)).foregroundStyle(Ink.faint)
            } else {
                if model.duplicatesScanned {
                    Text("No two files of \(sizes.first { $0.0 == model.duplicatesMinMB }?.1 ?? "") are identical in Downloads, Documents and Desktop.")
                        .font(Ink.serif(13)).foregroundStyle(Ink.faint)
                }
                HStack(spacing: 14) {
                    InkChoice(label: "Compare files of", selection: $model.duplicatesMinMB, options: sizes)
                    if model.duplicatesScanned {
                        Button("Search again") { model.scanDuplicates() }.buttonStyle(InkButtonStyle())
                    }
                }
                Text("Only byte-identical files count. The oldest copy is kept; the rest go to the Trash.")
                    .font(Ink.serif(12)).foregroundStyle(Ink.faint)
            }
        }
        .padding(.bottom, 40)
    }

    // MARK: Results

    private var results: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text(Ink.bytes(totalWasted)).font(Ink.num(40))
                        Text("held twice, in \(model.duplicateGroups.count) groups")
                            .font(Ink.serif(13)).foregroundStyle(Ink.faint)
                    }
                    .padding(.top, 8)
                    ForEach(model.duplicateGroups) { group in
                        DuplicateGroupSection(group: group, selection: $model.duplicateSelection)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
            }
            InkActionBar {
                Text(receiptLine ?? "\(model.duplicateSelection.count) files · \(Ink.bytes(selectedBytes)) selected")
                    .font(Ink.serif(12)).foregroundStyle(Ink.faint)
            } trailing: {
                Button("Move to Trash") { model.cleanDuplicates() }
                    .buttonStyle(InkVermilionButtonStyle())
                    .disabled(model.duplicatesLoading || model.duplicateSelection.isEmpty)
            }
        }
    }

    private var receiptLine: String? {
        guard !model.duplicateReceipts.isEmpty else { return nil }
        let ok = model.duplicateReceipts.filter { $0.reclaimedBytes > 0 }.count
        return "Moved \(ok) files to the Trash — recoverable."
    }
}

/// One set of identical files: the keeper first, then the copies to choose.
private struct DuplicateGroupSection: View {
    let group: DuplicateGroup
    @Binding var selection: Set<URL>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Ink.bytes(group.files[0].sizeBytes)) × \(group.files.count)")
                    .font(Ink.serif(14, .semibold))
                Text(group.files[0].url.lastPathComponent)
                    .font(Ink.serif(12)).foregroundStyle(Ink.faint).lineLimit(1)
                Spacer()
                Text("\(Ink.bytes(group.wastedBytes)) to reclaim")
                    .font(Ink.num(12, .regular)).foregroundStyle(Ink.faint)
            }
            .padding(.bottom, 4)
            ForEach(Array(group.files.enumerated()), id: \.element.url) { index, file in
                HStack(spacing: 12) {
                    if index == 0 {
                        Text("留").font(Ink.brush(13)).foregroundStyle(Ink.sumi)
                            .frame(width: 15, height: 15)
                            .help("Keeper — the oldest copy stays")
                    } else {
                        InkCheck(isOn: Binding(
                            get: { selection.contains(file.url) },
                            set: { on in if on { selection.insert(file.url) } else { selection.remove(file.url) } }
                        ), label: file.url.lastPathComponent)
                    }
                    Text(file.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if let d = file.lastModified {
                        Text(d, style: .date).font(Ink.serif(11)).foregroundStyle(Ink.faint)
                    }
                    Text(index == 0 ? "keep" : "copy")
                        .font(Ink.serif(11)).foregroundStyle(index == 0 ? Ink.sumi : Ink.faint)
                        .frame(width: 34, alignment: .trailing)
                }
                .padding(.vertical, 7)
                .overlay(alignment: .bottom) { Rectangle().fill(Ink.line).frame(height: 1) }
            }
        }
    }
}
