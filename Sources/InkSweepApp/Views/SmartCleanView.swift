import InkKit
import SwiftUI
import InkSweepCore

/// Smart Clean — one sheet, one act. A seal invites the scan; an ensō is
/// brushed as the scanners run, each category's character inking in on its
/// rim; the result is one number and one seal to press; a 净 stamp closes it.
struct SmartCleanView: View {
    @ObservedObject var model: AppModel
    @State private var confirmingEmptyTrash = false

    private enum Stage: Equatable { case invite, scanning, result, cleaning, done }

    private var stage: Stage {
        switch model.phase {
        case .scanning: return .scanning
        case .cleaning: return .cleaning
        case .idle:
            if model.completion != nil { return .done }
            return model.hasScanned || !model.report.findings.isEmpty ? .result : .invite
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(
                title: "Smart Clean",
                subtitle: Tool.smartClean.subtitle,
                trailing: stage == .result ? AnyView(
                    Button { model.scan() } label: { Text("Scan again") }
                        .buttonStyle(InkButtonStyle())
                ) : nil
            )
            if stage != .result {
                CenteredStage {
                    VStack(spacing: 18) {
                        hero
                        statusLine
                    }
                    .padding(.bottom, 40)
                }
            } else {
            ScrollView {
                VStack(spacing: 18) {
                    hero
                    statusLine
                    if stage == .result {
                        CategoryLedger(model: model)
                            .padding(.top, 18)
                            .transition(.opacity.combined(with: .offset(y: 12)))
                        if !model.report.warnings.isEmpty {
                            WarningNotes(model: model)
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 36)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            }
        }
        .animation(.easeOut(duration: 0.45), value: stage)
        .confirmationDialog(
            "Empty \(model.selectedTrashFindings.count) Trash items permanently?",
            isPresented: $confirmingEmptyTrash
        ) {
            Button("Clean and empty Trash", role: .destructive) { model.clean(apply: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Trash items cannot be recovered afterwards. Everything else still moves to the Trash.")
        }
    }

    private func clean() {
        if model.selectedTrashFindings.isEmpty { model.clean(apply: true) } else { confirmingEmptyTrash = true }
    }

    // MARK: Hero

    private var hero: some View {
        ZStack {
            Enso(progress: ensoProgress, vermilion: stage == .cleaning || stage == .done)
            RimCharacters(model: model, scanning: stage == .scanning)
            centre
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .id(stage)
        }
        .frame(width: 380, height: 380)
        .padding(.top, 4)
    }

    private var ensoProgress: Double {
        switch stage {
        case .invite: return 0
        case .scanning: return model.scanProgress
        case .result, .cleaning, .done: return 1
        }
    }

    @ViewBuilder
    private var centre: some View {
        switch stage {
        case .invite:
            SealButton(character: "扫", chinese: "扫描", english: "Scan", size: 96) { model.scan() }
        case .scanning:
            VStack(spacing: 6) {
                Text("\(model.scanFindingsSoFar)")
                    .font(Ink.num(52).monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.3), value: model.scanFindingsSoFar)
                Text("found").font(Ink.serif(12)).foregroundStyle(Ink.faint)
                phaseLabel.padding(.top, 8)
            }
        case .result:
            VStack(spacing: 4) {
                Text(Ink.bytes(model.selectedBytes))
                    .font(Ink.num(44))
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.5), value: model.selectedBytes)
                Text("ready to clean").font(Ink.serif(12)).foregroundStyle(Ink.faint)
                SealButton(character: "清", chinese: "清理", english: "Clean", size: 62) { clean() }
                    .disabled(model.selectedFindings.isEmpty)
                    .padding(.top, 14)
            }
        case .cleaning:
            VStack(spacing: 6) {
                Text("清理中").font(Ink.brush(30)).foregroundStyle(Ink.vermilion)
                Text("moving to the Trash…").font(Ink.serif(12)).foregroundStyle(Ink.faint)
            }
        case .done:
            DoneStamp(freed: model.completion?.freed ?? 0)
        }
    }

    @ViewBuilder
    private var phaseLabel: some View {
        if let category = JunkCategory(rawValue: model.scanPhaseTitle) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(category.chinese).font(Ink.brush(18)).foregroundStyle(Ink.vermilion)
                Text(category.title).font(Ink.serif(12)).foregroundStyle(Ink.sumi)
            }
        } else {
            Text(model.scanPhaseTitle == "done" ? "finishing" : "reading the disk")
                .font(Ink.serif(12)).foregroundStyle(Ink.faint)
        }
    }

    // MARK: Status line

    @ViewBuilder
    private var statusLine: some View {
        switch stage {
        case .invite:
            Text("Eleven kinds of clutter, one sweep. Nothing is removed until you choose.")
                .font(Ink.serif(13)).foregroundStyle(Ink.faint)
        case .scanning:
            Text("Reading caches, logs, leftovers and more — nothing is touched.")
                .font(Ink.serif(13)).foregroundStyle(Ink.faint)
        case .result:
            HStack(spacing: 14) {
                Text(selectionSummary).font(Ink.serif(12)).foregroundStyle(Ink.faint)
                Button("Preview") { model.clean(apply: false) }
                    .buttonStyle(InkButtonStyle())
                    .disabled(model.selectedFindings.isEmpty)
            }
        case .cleaning:
            EmptyView()
        case .done:
            VStack(spacing: 12) {
                Text(doneSummary).font(Ink.serif(13)).foregroundStyle(Ink.sumi)
                    .multilineTextAlignment(.center)
                Button("Done") { model.finishClean() }.buttonStyle(InkButtonStyle())
            }
        }
    }

    private var selectionSummary: String {
        var parts = ["\(model.selectedFindings.count) items selected"]
        if !model.receipts.isEmpty && !model.receiptsWereApply {
            parts = ["Preview: \(model.receipts.count) items would move to the Trash — nothing touched"]
        }
        if model.selectedAnalysisOnly > 0 { parts.append("\(model.selectedAnalysisOnly) analysis-only shown, not cleaned") }
        return parts.joined(separator: " · ")
    }

    private var doneSummary: String {
        guard let c = model.completion else { return "" }
        var lines = ["\(c.trashed) items moved to the Trash — recoverable until you empty it."]
        if c.emptied > 0 { lines.append("\(c.emptied) Trash items emptied permanently.") }
        if c.failed > 0 { lines.append("\(c.failed) could not be moved.") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Ensō

/// An ensō brushed with InkKit's brush: a faint ghost of the whole circle,
/// and the live stroke drawn to `progress` (0…1 of the circle).
struct Enso: View, Animatable {
    var progress: Double
    var vermilion = false
    @Environment(\.inkLook) private var look

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { context, size in
            // Proportions of the 380-pt page ensō, kept at every size.
            let side = min(size.width, size.height)
            let radius = side / 2 * 0.76
            let brush = max(3, side * 16 / 380)
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            context.withCGContext { cg in
                let palette = look.palette
                let ghost = palette.ink.copy(alpha: palette.isDark ? 0.12 : 0.08) ?? palette.ink
                InkBrush.stroke(cg, Self.points(centre, radius, 1), width: brush * 0.8, color: ghost,
                                paper: nil, seed: 7, texture: 0.5)
                if progress > 0.01 {
                    InkBrush.stroke(cg, Self.points(centre, radius, progress), width: brush,
                                    color: vermilion ? palette.red : palette.ink,
                                    paper: palette.paper, seed: 7, texture: 1)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// The ensō leaves its gap: the stroke starts just left of the top and
    /// sweeps 340° clockwise, its radius breathing slightly like a hand.
    static func points(_ c: CGPoint, _ r: CGFloat, _ progress: Double) -> [CGPoint] {
        let start = -CGFloat.pi / 2 - 0.22
        let sweep = 2 * CGFloat.pi * 0.945 * CGFloat(min(max(progress, 0), 1))
        let n = max(2, Int(110 * progress) + 2)
        return (0..<n).map { i in
            let t = CGFloat(i) / CGFloat(n - 1)
            let a = start + sweep * t
            let rr = r * (1 + 0.012 * sin(a * 3 + 1))
            return CGPoint(x: c.x + cos(a) * rr, y: c.y + sin(a) * rr)
        }
    }
}

/// Each category's character on the ensō's rim: faint until its scanner
/// runs, vermilion while it reads, ink once read; after the scan, ink where
/// something was found and faint where the category is clean.
private struct RimCharacters: View {
    @ObservedObject var model: AppModel
    let scanning: Bool

    var body: some View {
        GeometryReader { geo in
            let r = min(geo.size.width, geo.size.height) / 2 - 12
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let all = JunkCategory.allCases
            ForEach(Array(all.enumerated()), id: \.element) { i, category in
                let a = -Double.pi / 2 + 2 * Double.pi * Double(i) / Double(all.count)
                Text(category.character)
                    .font(Ink.brush(15))
                    .foregroundStyle(color(for: category))
                    .scaleEffect(isCurrent(category) ? 1.25 : 1)
                    .position(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
                    .animation(.easeOut(duration: 0.4), value: model.scannedCategories)
                    .help(category.title)
            }
        }
        .accessibilityHidden(true)
    }

    private func isCurrent(_ category: JunkCategory) -> Bool {
        scanning && model.scanPhaseTitle == category.rawValue
    }

    private func color(for category: JunkCategory) -> Color {
        if scanning {
            if isCurrent(category) { return Ink.vermilion }
            return model.scannedCategories.contains(category) ? Ink.sumi : Ink.faint.opacity(0.35)
        }
        if !model.hasScanned { return Ink.faint.opacity(0.35) }
        return model.report.findings(in: category).isEmpty ? Ink.faint.opacity(0.35) : Ink.sumi
    }
}

/// The closing stamp: a 净 seal pressed onto the page, and what it freed.
private struct DoneStamp: View {
    let freed: Int64
    @State private var pressed = false

    var body: some View {
        VStack(spacing: 10) {
            InkSeal(character: "净", size: 92)
                .rotationEffect(.degrees(pressed ? -4 : -14))
                .scaleEffect(pressed ? 1 : 1.5)
                .opacity(pressed ? 1 : 0)
            Text(Ink.bytes(freed)).font(Ink.num(34))
            Text("freed").font(Ink.serif(12)).foregroundStyle(Ink.faint)
        }
        .onAppear {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.62).delay(0.1)) { pressed = true }
        }
    }
}

// MARK: - Category ledger

/// What was found, one ruled row per category. The category's seal is its
/// selection: carved vermilion when it will be cleaned, an ink outline when not.
private struct CategoryLedger: View {
    @ObservedObject var model: AppModel
    @State private var expanded: Set<JunkCategory> = []

    private var withFindings: [JunkCategory] {
        JunkCategory.allCases.filter { !model.report.findings(in: $0).isEmpty }
    }
    private var clean: [JunkCategory] {
        JunkCategory.allCases.filter { model.report.findings(in: $0).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InkSectionHeader(chinese: "类别", english: "What was found")
                .padding(.bottom, 6)
            ForEach(withFindings, id: \.self) { category in
                row(category)
                if expanded.contains(category) {
                    FindingsDetail(findings: model.report.findings(in: category))
                        .transition(.opacity)
                }
            }
            if !clean.isEmpty {
                Text("Clean: " + clean.map { "\($0.chinese) \($0.title)" }.joined(separator: " · "))
                    .font(Ink.serif(11)).foregroundStyle(Ink.faint)
                    .padding(.top, 12)
            }
        }
    }

    private func row(_ category: JunkCategory) -> some View {
        let findings = model.report.findings(in: category)
        let cleanable = findings.filter(\.reversible)
        let analysisOnly = findings.count - cleanable.count
        let included = model.included.contains(category)
        let optIn: Set<JunkCategory> = [.trash, .installerFiles, .projectArtifacts]

        return HStack(spacing: 14) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    if included { model.included.remove(category) } else { model.included.insert(category) }
                }
            } label: {
                CategorySeal(character: category.character, selected: included && !cleanable.isEmpty)
            }
            .buttonStyle(.plain)
            .disabled(cleanable.isEmpty)
            .accessibilityLabel("\(included ? "Exclude" : "Include") \(category.title)")

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(category.chinese).font(Ink.brush(17))
                    Text(category.title).font(Ink.serif(13, .semibold))
                }
                if optIn.contains(category) || analysisOnly > 0 {
                    Text(note(category, analysisOnly: analysisOnly, optIn: optIn.contains(category)))
                        .font(Ink.serif(11)).foregroundStyle(Ink.faint)
                }
            }
            .opacity(included || cleanable.isEmpty ? 1 : 0.55)

            Spacer()
            Text("\(findings.count) · \(Ink.bytes(model.report.bytes(in: category)))")
                .font(Ink.num(13, .regular).monospacedDigit())
                .foregroundStyle(Ink.faint)
            Button {
                withAnimation(.easeOut(duration: 0.25)) {
                    if expanded.contains(category) { expanded.remove(category) } else { expanded.insert(category) }
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .rotationEffect(.degrees(expanded.contains(category) ? 90 : 0))
                    .foregroundStyle(Ink.faint)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show \(category.title) items")
        }
        .inkCard()
    }

    private func note(_ category: JunkCategory, analysisOnly: Int, optIn: Bool) -> String {
        var parts: [String] = []
        if category == .trash { parts.append("opt-in · emptying is permanent") } else if optIn { parts.append("opt-in · review before cleaning") }
        if analysisOnly > 0 { parts.append("\(analysisOnly) analysis-only — see Maintenance") }
        return parts.joined(separator: " · ")
    }
}

/// A category's selection seal: carved vermilion when selected, an ink
/// outline around the brushed character when not.
private struct CategorySeal: View {
    let character: String
    let selected: Bool

    var body: some View {
        ZStack {
            if selected {
                InkSeal(character: character, size: 30).transition(.scale(scale: 1.3).combined(with: .opacity))
            } else {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(Ink.sumi.opacity(0.35), lineWidth: 1.2)
                    .frame(width: 28, height: 28)
                Text(character).font(Ink.brush(18)).foregroundStyle(Ink.faint)
            }
        }
        .frame(width: 32, height: 32)
    }
}

/// The items of one category, largest first.
private struct FindingsDetail: View {
    let findings: [Finding]
    private let limit = 150

    var body: some View {
        let sorted = findings.sorted { $0.sizeBytes > $1.sizeBytes }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sorted.prefix(limit)) { FindingRow(finding: $0) }
            if sorted.count > limit {
                Text("and \(sorted.count - limit) smaller items")
                    .font(Ink.serif(11)).foregroundStyle(Ink.faint)
                    .padding(.vertical, 8).padding(.leading, 56)
            }
        }
        .padding(.bottom, 6)
    }
}

struct FindingRow: View {
    let finding: Finding
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Ink.faint)
                .frame(width: 12)
                .opacity(finding.reversible ? 0 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Ink.sumi)
                    .lineLimit(1).truncationMode(.middle)
                Text(finding.reason)
                    .font(Ink.serif(11)).foregroundStyle(Ink.faint)
                    .lineLimit(1)
            }
            Spacer()
            Text(Ink.bytes(finding.sizeBytes))
                .font(Ink.num(11, .regular).monospacedDigit())
                .foregroundStyle(Ink.faint)
        }
        .padding(.leading, 44)
        .padding(.trailing, 34)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 5).fill(hovered ? Ink.sumi.opacity(0.04) : .clear)
        )
        .onHover { hovered = $0 }
        .help(finding.url.path)
    }
}

// MARK: - Warnings

private struct WarningNotes: View {
    @ObservedObject var model: AppModel
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            InkSectionHeader(chinese: "提示", english: "Skipped this time")
            Button {
                withAnimation(.easeOut(duration: 0.2)) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("\(model.report.warnings.count) things were skipped — running apps, protected folders")
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .font(Ink.serif(12)).foregroundStyle(Ink.faint)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                ForEach(model.report.warnings, id: \.self) { w in
                    Text(w).font(Ink.serif(12)).foregroundStyle(Ink.faint)
                }
                .padding(.leading, 12)
            }
            if model.needsFullDiskAccess {
                Button("Grant Full Disk Access…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(InkVermilionButtonStyle())
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 14)
    }
}
