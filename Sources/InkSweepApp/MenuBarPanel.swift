import AppKit
import InkKit
import SwiftUI
import InkSweepCore

/// The menu bar panel: InkSweep's state at a glance and the one safe act —
/// clean the default selection to the Trash — without opening the window.
struct MenuBarPanel: View {
    @ObservedObject var model: AppModel
    /// Closes the popover the panel lives in.
    var close: () -> Void = {}
    @Environment(\.colorScheme) private var scheme

    private var look: InkLook { InkLook(theme: .ink, dark: scheme == .dark) }
    private var updates: Int { model.updateResult?.updates.count ?? 0 }
    private var busy: Bool { model.phase != .idle || model.updatesChecking }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 12)
            hero
            InkRule(seed: 4).padding(.vertical, 10)
            row("更新", "Updates") {
                Button(updates == 0 ? (model.updateResult == nil ? "not checked" : "all current") : "\(updates) available") {
                    open(.updater)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .font(Ink.serif(12, updates > 0 ? .semibold : .regular))
                .foregroundStyle(updates > 0 ? Ink.vermilion : Ink.faint)
            }
            row("上次", "Last clean") {
                Text(model.lastClean.map { "\(Ink.bytes($0.freed)) · \($0.date.formatted(.relative(presentation: .named)))" } ?? "nothing yet")
                    .font(Ink.serif(12)).foregroundStyle(Ink.faint)
            }
            DiskInkwell().padding(.horizontal, -8).padding(.top, 10)
            InkRule(seed: 9).padding(.vertical, 10)
            footer
        }
        .padding(18)
        .frame(width: 320)
        .foregroundStyle(Ink.sumi)
        .background(PaperBackground(look: look))
        .environment(\.inkLook, look)
        .tint(Ink.vermilion)
    }

    private var header: some View {
        HStack(spacing: 10) {
            InkSeal(character: "掃", size: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text("墨扫").font(Ink.brush(18))
                Text(status).font(Ink.serif(10)).foregroundStyle(Ink.faint)
            }
            Spacer()
        }
    }

    private var status: String {
        if model.phase == .scanning || model.updatesChecking { return "checking…" }
        if model.phase == .cleaning { return "cleaning…" }
        guard let date = model.lastScanDate else { return "not checked yet" }
        return "checked " + date.formatted(.relative(presentation: .named))
    }

    private var hero: some View {
        HStack(spacing: 16) {
            ZStack {
                if busy { EnsoLoop(vermilion: model.phase == .cleaning) } else { Enso(progress: model.hasScanned ? 1 : 0) }
                VStack(spacing: 0) {
                    Text(model.hasScanned ? Ink.bytes(model.selectedBytes) : "—").font(Ink.num(15))
                    Text("to clean").font(Ink.serif(9)).foregroundStyle(Ink.faint)
                }
            }
            .frame(width: 112, height: 112)

            VStack(alignment: .leading, spacing: 8) {
                if let done = model.completion {
                    Text("Freed \(Ink.bytes(done.freed))").font(Ink.serif(14, .semibold))
                    Text("\(done.trashed) items are in the Trash, recoverable.").font(Ink.serif(11)).foregroundStyle(Ink.faint)
                        .fixedSize(horizontal: false, vertical: true)
                } else if model.hasScanned {
                    Text("\(model.selectedFindings.count) items ready").font(Ink.serif(14, .semibold))
                    Text("Moves them to the Trash — recoverable.").font(Ink.serif(11)).foregroundStyle(Ink.faint)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Clean") { model.clean(apply: true) }
                        .buttonStyle(InkVermilionButtonStyle())
                        .disabled(busy || model.selectedFindings.isEmpty || !model.selectedTrashFindings.isEmpty)
                } else {
                    Text("Not checked yet").font(Ink.serif(14, .semibold))
                    Button("Check now") { checkNow() }.buttonStyle(InkVermilionButtonStyle()).disabled(busy)
                }
            }
        }
    }

    private func row<Trailing: View>(_ chinese: String, _ english: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(chinese).font(Ink.brush(12)).foregroundStyle(Ink.faint)
            Text(english).font(Ink.serif(11)).foregroundStyle(Ink.faint)
            Spacer()
            trailing()
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Open InkSweep") { open(model.tool) }.buttonStyle(InkButtonStyle())
            Button("Check now") { checkNow() }.buttonStyle(InkButtonStyle()).disabled(busy)
            Spacer()
            Button { NSApplication.shared.terminate(nil) } label: {
                Image(systemName: "power").font(.system(size: 12)).foregroundStyle(Ink.faint)
            }
            .buttonStyle(.plain)
            .help("Quit InkSweep")
            .accessibilityLabel("Quit InkSweep")
        }
    }

    private func checkNow() {
        model.completion = nil
        model.scan()
        model.checkUpdates()
    }

    private func open(_ tool: Tool) {
        close()
        model.showMainWindow(tool)
    }

    /// A brushed broom (掃, "sweep") as a template image, so the menu bar
    /// tints it like every other status item. The ensō is InkBar's mark;
    /// this one has to be told apart from it at a glance.
    static let icon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            let ink = NSColor.black.cgColor
            // Handle: from the top right down to the binding.
            InkBrush.stroke(cg, [CGPoint(x: 15.2, y: 1.6), CGPoint(x: 11.4, y: 6.4), CGPoint(x: 8.6, y: 9.6)],
                            width: 1.7, color: ink, paper: nil, seed: 2, texture: 0.4)
            // Bristles: three strokes fanning from the binding.
            for (i, end) in [CGPoint(x: 1.4, y: 11.6), CGPoint(x: 2.9, y: 14.6), CGPoint(x: 5.8, y: 16.8)].enumerated() {
                InkBrush.stroke(cg, [CGPoint(x: 9.2, y: 9.0), CGPoint(x: (9.2 + end.x) / 2, y: (9.0 + end.y) / 2 + 0.4), end],
                                width: 1.9, color: ink, paper: nil, seed: 11 + i, texture: 0.5)
            }
            // The swept stroke on the ground.
            InkBrush.stroke(cg, [CGPoint(x: 9.5, y: 16.6), CGPoint(x: 13.0, y: 16.2), CGPoint(x: 16.6, y: 15.2)],
                            width: 1.4, color: ink, paper: nil, seed: 21, texture: 0.4)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "InkSweep"
        return image
    }()

    /// `-InkSweepDumpIcon <png>` writes the icon at 8× and exits (design check).
    static func dumpIconIfAsked() {
        guard let path = UserDefaults.standard.string(forKey: "InkSweepDumpIcon") else { return }
        let scale: CGFloat = 8
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(18 * scale), pixelsHigh: Int(18 * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: 18, height: 18)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 18, height: 18).fill()
        icon.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        exit(0)
    }
}
