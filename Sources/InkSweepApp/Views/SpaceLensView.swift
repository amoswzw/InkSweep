import InkKit
import SwiftUI
import InkSweepCore

/// Space Lens — where the disk went, as an ink sunburst plus a ranked list.
struct SpaceLensView: View {
    @ObservedObject var model: AppModel
    @State private var selected: SpaceNode?

    private struct LensRoot: Identifiable {
        let name: String
        let url: URL
        var id: String { name }
    }

    private var roots: [LensRoot] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            LensRoot(name: "Home", url: home),
            LensRoot(name: "Downloads", url: home.appendingPathComponent("Downloads")),
            LensRoot(name: "Documents", url: home.appendingPathComponent("Documents")),
            LensRoot(name: "Desktop", url: home.appendingPathComponent("Desktop")),
            LensRoot(name: "Applications", url: URL(fileURLWithPath: "/Applications")),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(
                title: "Space Lens",
                subtitle: Tool.spaceLens.subtitle,
                trailing: AnyView(
                    InkChoice(label: "Look through", selection: Binding<String>(
                        get: { model.lensRootName },
                        set: { name in
                            if let r = roots.first(where: { $0.name == name }) {
                                model.loadLens(root: r.url, name: name)
                            }
                        }
                    ), options: roots.map { ($0.name, $0.name) })
                )
            )

            if model.lensLoading {
                Spacer()
                ZStack {
                    EnsoLoop()
                    VStack(spacing: 6) {
                        Text("量度中").font(Ink.brush(26)).foregroundStyle(Ink.vermilion)
                        Text("measuring \(model.lensRootName)").font(Ink.serif(12)).foregroundStyle(Ink.faint)
                    }
                }
                .frame(width: 320, height: 320)
                Text("Allocated bytes, symlinks never followed.")
                    .font(Ink.serif(12)).foregroundStyle(Ink.faint)
                Spacer()
            } else if let tree = model.lensTree {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(alignment: .top, spacing: 24) {
                            SunburstView(tree: tree, selected: $selected)
                                .aspectRatio(1, contentMode: .fit)
                                .frame(maxWidth: 460)
                            selectedDetail(tree: tree)
                        }
                        if let children = tree.children, !children.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                InkSectionHeader(chinese: "最大", english: "Largest in \(model.lensRootName)")
                                rankedList(children)
                            }
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                }
            } else {
                Spacer()
                SealButton(character: "量", chinese: "量度", english: "Measure Home", size: 80) {
                    model.loadLens(root: roots[0].url, name: roots[0].name)
                }
                Spacer()
            }
        }
        .task {
            if model.lensTree == nil && !model.lensLoading {
                model.loadLens(root: roots[0].url, name: roots[0].name)
            }
        }
    }

    @ViewBuilder
    private func selectedDetail(tree: SpaceNode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let sel = selected {
                stat(sel.name, Ink.bytes(sel.sizeBytes), sel.url.path)
            } else {
                stat(model.lensRootName, Ink.bytes(tree.sizeBytes), tree.url.path)
            }
            Text("Click a ring segment to inspect it.")
                .font(Ink.serif(11)).foregroundStyle(Ink.faint)
            if let sel = selected {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([sel.url]) }
                    .buttonStyle(InkButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
    }

    private func stat(_ name: String, _ bytes: String, _ path: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(Ink.serif(18, .semibold)).foregroundStyle(Ink.sumi)
                .lineLimit(1).truncationMode(.middle)
            Text(bytes).font(Ink.num(34)).foregroundStyle(Ink.vermilion)
                .contentTransition(.numericText())
            Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Ink.faint)
                .lineLimit(2).truncationMode(.middle)
        }
    }

    private func rankedList(_ children: [SpaceNode]) -> some View {
        let maxBytes = children.first?.sizeBytes ?? 1
        return VStack(spacing: 4) {
            ForEach(Array(children.prefix(15).enumerated()), id: \.element.id) { _, child in
                HStack(spacing: 10) {
                    Text(child.name)
                        .font(Ink.serif(12)).foregroundStyle(selected?.id == child.id ? Ink.vermilion : Ink.sumi)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(width: 220, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2).fill(Ink.line)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(selected?.id == child.id ? Ink.vermilion : Ink.sumi.opacity(0.7))
                                .frame(width: geo.size.width * CGFloat(child.sizeBytes) / CGFloat(max(maxBytes, 1)))
                        }
                    }
                    Text(Ink.bytes(child.sizeBytes))
                        .font(Ink.num(11, .regular)).foregroundStyle(Ink.faint)
                        .frame(width: 72, alignment: .trailing)
                }
                .contentShape(Rectangle())
                .onTapGesture { selected = child }
                .padding(.vertical, 3)
            }
        }
    }
}

/// Two-ring sunburst. Ring 1: the root's children; ring 2: their children.
/// Segment spans are proportional to size; click hit-tests by angle+radius.
private struct SunburstView: View {
    let tree: SpaceNode
    @Binding var selected: SpaceNode?
    @State private var appeared = false
    // Canvas cannot resolve appearance-dependent colours; draw with the palette.
    @Environment(\.inkLook) private var look

    var body: some View {
        GeometryReader { geo in
            let layout = Layout(tree: tree, size: geo.size)
            ZStack {
                Canvas { ctx, size in
                    let l = Layout(tree: tree, size: size)
                    // Center disk.
                    let center = CGRect(
                        x: size.width / 2 - l.rootRadius, y: size.height / 2 - l.rootRadius,
                        width: l.rootRadius * 2, height: l.rootRadius * 2
                    )
                    let ink = Color(cgColor: look.palette.ink)
                    ctx.fill(Path(ellipseIn: center), with: .color(ink.opacity(0.04)))
                    ctx.stroke(Path(ellipseIn: center), with: .color(ink.opacity(0.15)), lineWidth: 1)

                    // Rings.
                    for seg in l.segments() {
                        var path = Path()
                        path.addArc(center: l.center, radius: seg.outerRadius,
                                    startAngle: seg.start, endAngle: seg.end, clockwise: false)
                        path.addArc(center: l.center, radius: seg.innerRadius,
                                    startAngle: seg.end, endAngle: seg.start, clockwise: true)
                        path.closeSubpath()
                        let isSel = selected != nil && selected!.id == seg.node.id
                        ctx.fill(path, with: .color(
                            isSel ? Color(cgColor: look.palette.red) : ink.opacity(seg.opacity)))
                        ctx.stroke(path, with: .color(Color(cgColor: look.palette.paper)), lineWidth: 1)
                    }
                }
                Text("\(tree.name)\n\(Ink.bytes(tree.sizeBytes))")
                    .font(Ink.num(11, .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Ink.sumi)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .allowsHitTesting(false)
            }
            .gesture(
                SpatialTapGesture().onEnded { tap in
                    selected = layout.node(at: tap.location)
                }
            )
        }
        .scaleEffect(appeared ? 1 : 0.72)
        .opacity(appeared ? 1 : 0)
        .onAppear { bloom() }
        .onChange(of: tree) { _ in bloom() }
    }

    private func bloom() {
        appeared = false
        withAnimation(.spring(response: 0.65, dampingFraction: 0.82)) { appeared = true }
    }

    /// Deterministic layout math shared by drawing and hit-testing.
    struct Layout {
        let tree: SpaceNode
        let size: CGSize
        let center: CGPoint
        let rootRadius: CGFloat
        let ringWidth: CGFloat

        struct Segment {
                            let node: SpaceNode
            let start: Angle
            let end: Angle
            let innerRadius: CGFloat
            let outerRadius: CGFloat
            let opacity: Double
        }

        init(tree: SpaceNode, size: CGSize) {
            self.tree = tree
            self.size = size
            self.center = CGPoint(x: size.width / 2, y: size.height / 2)
            let maxRadius = min(size.width, size.height) / 2 - 3
            self.rootRadius = maxRadius * 0.22
            self.ringWidth = (maxRadius - rootRadius) / 2
        }

        func segments() -> [Segment] {
            var out: [Segment] = []
            let top = Array((tree.children ?? []).prefix(14))
            let total = max(top.reduce(Int64(0)) { $0 + $1.sizeBytes }, 1)
            var cursor = -90.0
            for (rank, child) in top.enumerated() {
                let sweep = 360.0 * Double(child.sizeBytes) / Double(total)
                let start = Angle.degrees(cursor)
                let end = Angle.degrees(cursor + max(sweep - 0.6, 0.2))
                cursor += sweep
                out.append(Segment(
                    node: child, start: start, end: end,
                    innerRadius: rootRadius + 2, outerRadius: rootRadius + ringWidth,
                    opacity: 0.85 - Double(rank) * 0.05
                ))
                // Ring 2.
                let subs = Array((child.children ?? []).prefix(10))
                let subTotal = max(subs.reduce(Int64(0)) { $0 + $1.sizeBytes }, 1)
                var subCursor = cursor - sweep
                for (subRank, sub) in subs.enumerated() {
                    let subSweep = sweep * Double(sub.sizeBytes) / Double(subTotal)
                    out.append(Segment(
                        node: sub,
                        start: .degrees(subCursor),
                        end: .degrees(subCursor + max(subSweep - 0.5, 0.15)),
                        innerRadius: rootRadius + ringWidth + 2,
                        outerRadius: rootRadius + ringWidth * 2,
                        opacity: 0.5 - Double(subRank) * 0.04
                    ))
                    subCursor += subSweep
                }
            }
            return out
        }

        func node(at point: CGPoint) -> SpaceNode? {
            let dx = point.x - center.x
            let dy = point.y - center.y
            let r = sqrt(dx * dx + dy * dy)
            guard r > rootRadius else { return nil }
            // Same frame as the segments: 0° at three o'clock, -90° at the
            // top, increasing clockwise through 270°.
            var angle = atan2(dy, dx) * 180 / .pi
            if angle < -90 { angle += 360 }
            return segments()
                .first { seg in
                    let a = seg.start.degrees
                    let b = seg.end.degrees
                    let inAngle = angle >= a && angle <= b
                    let inRadius = r >= seg.innerRadius && r <= seg.outerRadius
                    return inAngle && inRadius
                }?
                .node
        }
    }
}
