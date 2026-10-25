import AppKit
import InkKit
import SwiftUI
import UniformTypeIdentifiers
import InkSweepCore

/// Shredder — explicit, irreversible deletion. Kept deliberately separate
/// from every reversible flow: it only ever runs from this screen, behind a
/// destructive confirmation.
struct ShredderView: View {
    @ObservedObject var model: AppModel
    @State private var confirming = false
    @State private var dropping = false

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(
                title: "Shredder",
                subtitle: Tool.shredder.subtitle,
                trailing: model.shredTargets.isEmpty ? nil : AnyView(
                    Button("Add more…") { addTargets() }.buttonStyle(InkButtonStyle())
                )
            )
            Text("Everything else in InkSweep goes to the Trash first. This does not: files are overwritten and deleted. On APFS the overwrite is best-effort.")
                .font(Ink.serif(12))
                .foregroundStyle(Ink.vermilion)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.bottom, 6)

            if model.shredTargets.isEmpty {
                dropTarget.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.shredTargets, id: \.path) { url in
                            HStack(spacing: 12) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                    .resizable().frame(width: 22, height: 22)
                                Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .font(.system(size: 12, design: .monospaced))
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button {
                                    model.shredTargets.removeAll { $0.path == url.path }
                                } label: {
                                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(Ink.faint).frame(width: 22, height: 22)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(url.lastPathComponent)")
                            }
                            .inkCard()
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 8)
                }
                .onDrop(of: [.fileURL], isTargeted: $dropping, perform: accept)
            }

            if !model.shredTargets.isEmpty || !model.shredReceipts.isEmpty {
                InkActionBar {
                    Text(receiptLine ?? "\(model.shredTargets.count) items — this cannot be undone")
                        .font(Ink.serif(12))
                        .foregroundStyle(receiptLine == nil ? Ink.vermilion : Ink.faint)
                } trailing: {
                    Button("Shred permanently…") { confirming = true }
                        .buttonStyle(InkVermilionButtonStyle())
                        .disabled(model.shredTargets.isEmpty)
                }
            }
        }
        .confirmationDialog(
            "Shred \(model.shredTargets.count) items permanently?",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button("Shred — overwrite 3× and delete", role: .destructive) {
                model.shredApply()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Files are overwritten with three passes of random data, then deleted. On APFS/SSD no overwrite guarantees physical erasure of every copy. There is no Trash step.")
        }
    }

    private var dropTarget: some View {
        VStack(spacing: 16) {
            ZStack {
                Enso(progress: dropping ? 1 : 0, vermilion: dropping)
                    .animation(.easeOut(duration: 0.5), value: dropping)
                SealButton(character: "碎", chinese: "粉碎", english: "Choose files", size: 82) { addTargets() }
            }
            .frame(width: 320, height: 320)
            Text("Drop files or folders here, or choose them. Nothing is shredded until you confirm.")
                .font(Ink.serif(12)).foregroundStyle(Ink.faint)
        }
        .padding(.bottom, 40)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $dropping, perform: accept)
    }

    private var receiptLine: String? {
        guard model.shredTargets.isEmpty, !model.shredReceipts.isEmpty else { return nil }
        let ok = model.shredReceipts.filter { $0.outcome == .shredded }.count
        let failed = model.shredReceipts.count - ok
        return "Shredded \(ok) items\(failed == 0 ? "" : ", \(failed) refused or failed")."
    }

    private func accept(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    if !model.shredTargets.contains(url) { model.shredTargets.append(url) }
                }
            }
        }
        return true
    }

    private func addTargets() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose files or folders to shred"
        if panel.runModal() == .OK {
            for url in panel.urls where !model.shredTargets.contains(url) {
                model.shredTargets.append(url)
            }
        }
    }
}
