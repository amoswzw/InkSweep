import AppKit
import InkKit
import SwiftUI
import InkSweepCore

// MARK: - Tokens
//
// The ink-wash world of InkKit (shared with InkBar, InkStats, InkShot): rice
// paper, sumi ink, one vermilion kept for seals, selection and the primary
// act. Every colour resolves per appearance from InkKit's palettes.

enum Ink {
    private static func dynamic(_ pick: @escaping (Palette) -> CGColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(cgColor: pick(Palette.make(.ink, dark: dark))) ?? .textColor
        })
    }

    static let paper = dynamic(\.paper)
    static let sumi = dynamic(\.ink)
    static let faint = dynamic(\.sub)
    static let vermilion = dynamic(\.red)
    static let line = sumi.opacity(0.13)
    /// A faint ink wash where a region needs to read as set apart.
    static let card = sumi.opacity(0.035)

    static func bytes(_ b: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: b)
    }

    /// Serif numerals, as InkKit's ink theme sets them.
    static func num(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// Brush lettering for the Chinese half of every bilingual label.
    static func brush(_ size: CGFloat) -> Font { Font(Fonts.brush(size)) }
}

extension Tool {
    var chinese: String {
        switch self {
        case .smartClean: return "清理"
        case .uninstaller: return "卸载"
        case .duplicates: return "重复"
        case .spaceLens: return "空间"
        case .maintenance: return "维护"
        case .shredder: return "粉碎"
        case .updater: return "更新"
        case .smartCare: return "照料"
        }
    }
}

extension JunkCategory {
    /// One character per category: it sits on the ensō's rim during a scan
    /// and is carved into the category's selection seal.
    var character: String {
        switch self {
        case .userCaches: return "缓"
        case .systemLogs: return "志"
        case .systemJunk: return "系"
        case .trash: return "篓"
        case .browserData: return "私"
        case .appLeftovers: return "残"
        case .developerJunk: return "码"
        case .largeOldFiles: return "旧"
        case .mailAttachments: return "邮"
        case .installerFiles: return "装"
        case .projectArtifacts: return "构"
        }
    }

    var chinese: String {
        switch self {
        case .userCaches: return "缓存"
        case .systemLogs: return "日志"
        case .systemJunk: return "系统"
        case .trash: return "废纸篓"
        case .browserData: return "隐私"
        case .appLeftovers: return "残留"
        case .developerJunk: return "开发"
        case .largeOldFiles: return "大旧文件"
        case .mailAttachments: return "邮件"
        case .installerFiles: return "安装包"
        case .projectArtifacts: return "构建产物"
        }
    }
}

// MARK: - Window shell

/// The app window: rice paper reaching under a hidden title bar, a
/// brush-lettered sidebar, a brushed divider, the chosen tool.
struct RootView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openWindow) private var openWindow
    private var tool: Tool { model.tool }

    private var look: InkLook { InkLook(theme: .ink, dark: scheme == .dark) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 238)
            InkRule(seed: 21, vertical: true).padding(.vertical, 26)
            Group {
                switch tool {
                case .smartClean: SmartCleanView(model: model)
                case .uninstaller: UninstallerView(model: model)
                case .duplicates: DuplicatesView(model: model)
                case .spaceLens: SpaceLensView(model: model)
                case .maintenance: MaintenanceView(model: model)
                case .shredder: ShredderView(model: model)
                case .updater: UpdaterView(model: model)
                case .smartCare: SmartCareView(model: model)
                }
            }
            .id(tool)
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .font(Ink.serif(13))
        .foregroundStyle(Ink.sumi)
        .background(PaperBackground(look: look).ignoresSafeArea())
        .environment(\.inkLook, look)
        .tint(Ink.vermilion)
        .task {
            model.openMainWindow = { [openWindow] in openWindow(id: "main") }
            if model.autoScanOnLaunch && model.report.findings.isEmpty {
                model.scan()
                model.checkUpdates()
            }
        }
    }

    /// The tools in three bilingual groups, the hub first.
    private static let groups: [(chinese: String, english: String, tools: [Tool])] = [
        ("照料", "Care", [.smartCare, .smartClean, .duplicates]),
        ("应用", "Apps", [.uninstaller, .updater]),
        ("工具", "Tools", [.spaceLens, .maintenance, .shredder]),
    ]

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                InkSeal(character: "掃", size: 36)
                VStack(alignment: .leading, spacing: 0) {
                    Text("墨扫").font(Ink.brush(22)).foregroundStyle(Ink.sumi)
                    Text("InkSweep").font(Ink.serif(11)).foregroundStyle(Ink.faint)
                }
            }
            .padding(.bottom, 14)

            ForEach(Self.groups, id: \.english) { group in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(group.chinese).font(Ink.brush(12))
                    Text(group.english).font(Ink.serif(10))
                }
                .foregroundStyle(Ink.faint)
                .padding(.leading, 8)
                .padding(.top, 14)
                .padding(.bottom, 2)
                ForEach(group.tools) { t in
                    SidebarRow(tool: t, selected: tool == t, badge: badge(for: t)) {
                        withAnimation(.easeOut(duration: 0.22)) { model.tool = t }
                    }
                }
            }

            Spacer(minLength: 20)
            lastCleanNote
            DiskInkwell()
        }
        .padding(.top, 46)
        .padding(.bottom, 20)
        .padding(.horizontal, 18)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var lastCleanNote: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("上次").font(Ink.brush(12))
                Text("Last clean").font(Ink.serif(10))
            }
            .foregroundStyle(Ink.faint)
            if let last = model.lastClean {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Ink.bytes(last.freed)).font(Ink.num(15))
                    Text("freed " + last.date.formatted(.relative(presentation: .named)))
                        .font(Ink.serif(10)).foregroundStyle(Ink.faint)
                }
            } else {
                Text("Nothing removed yet").font(Ink.serif(11)).foregroundStyle(Ink.faint)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 14)
    }

    /// What is waiting in a tool, from data already measured — nothing is
    /// scanned just to fill the sidebar.
    private func badge(for tool: Tool) -> SidebarRow.Badge? {
        switch tool {
        case .smartClean:
            return model.hasScanned && model.selectedBytes > 0 ? .init(text: Ink.bytes(model.selectedBytes), urgent: false) : nil
        case .updater:
            let n = model.updateResult?.updates.count ?? 0
            return n > 0 ? .init(text: "\(n)", urgent: true) : nil
        case .duplicates:
            let wasted = model.duplicateGroups.reduce(Int64(0)) { $0 + $1.wastedBytes }
            return wasted > 0 ? .init(text: Ink.bytes(wasted), urgent: false) : nil
        default:
            return nil
        }
    }
}

private struct SidebarRow: View {
    struct Badge { let text: String; let urgent: Bool }

    let tool: Tool
    let selected: Bool
    var badge: Badge? = nil
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(tool.chinese)
                    .font(Ink.brush(18))
                    .foregroundStyle(selected ? Ink.vermilion : Ink.sumi)
                Text(tool.title)
                    .font(Ink.serif(12))
                    .foregroundStyle(selected || hovered ? Ink.sumi : Ink.faint)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 4)
                if let badge {
                    Text(badge.text)
                        .font(Ink.num(11, badge.urgent ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(badge.urgent ? Ink.vermilion : Ink.faint)
                        .contentTransition(.numericText())
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(alignment: .bottomLeading) {
                if selected {
                    InkRule(seed: 5).frame(width: 70).offset(x: 6, y: 1).transition(.opacity)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Focus lands on the first row at launch; a mark there would read as
        // a second selection, so rows carry selection only.
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.15), value: hovered)
        .accessibilityLabel(tool.title + (badge.map { ", \($0.text)" } ?? ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The startup disk as an inkwell: a brushed bar of what is used, and how
/// much room is left — the number every cleaner exists to move.
struct DiskInkwell: View {
    @State private var usage: (used: Int64, total: Int64, name: String)?
    @Environment(\.inkLook) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("磁盘").font(Ink.brush(12))
                Text(usage?.name ?? "Startup disk").font(Ink.serif(10)).lineLimit(1)
            }
            .foregroundStyle(Ink.faint)
            Canvas { context, size in
                guard let u = usage, u.total > 0 else { return }
                let share = CGFloat(Double(u.used) / Double(u.total))
                let y = size.height / 2
                context.withCGContext { cg in
                    let palette = look.palette
                    let ghost = palette.ink.copy(alpha: palette.isDark ? 0.14 : 0.1) ?? palette.ink
                    InkBrush.stroke(cg, [CGPoint(x: 2, y: y), CGPoint(x: size.width - 2, y: y)], width: 7,
                                    color: ghost, paper: nil, seed: 4, texture: 0.4)
                    InkBrush.stroke(cg, [CGPoint(x: 2, y: y), CGPoint(x: 2 + (size.width - 4) * share, y: y)], width: 9,
                                    color: share > 0.9 ? palette.red : palette.ink, paper: palette.paper, seed: 4, texture: 1)
                }
            }
            .frame(height: 14)
            if let u = usage {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Ink.bytes(u.total - u.used)).font(Ink.num(15))
                    Text("free of \(Ink.bytes(u.total))").font(Ink.serif(10)).foregroundStyle(Ink.faint)
                }
            }
        }
        .padding(.horizontal, 8)
        .task { refresh() }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in refresh() }
        .accessibilityElement(children: .combine)
    }

    private func refresh() {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedNameKey]
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = v.volumeTotalCapacity, let free = v.volumeAvailableCapacityForImportantUsage else { return }
        withAnimation(.easeOut(duration: 0.6)) {
            usage = (Int64(total) - free, Int64(total), v.volumeLocalizedName ?? "Startup disk")
        }
    }
}

// MARK: - Page header

/// Bilingual page title: brush Chinese, serif English, a brush rule, the
/// page's one-line purpose, and an optional trailing control.
struct ToolHeader: View {
    let title: String
    let subtitle: String
    var trailing: AnyView? = nil

    private var chinese: String? { Tool.allCases.first { $0.title == title }?.chinese }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    if let chinese {
                        Text(chinese).font(Ink.brush(34)).foregroundStyle(Ink.sumi)
                    }
                    Text(title).font(Ink.serif(16)).foregroundStyle(Ink.faint)
                }
                InkRule(seed: title.count).frame(width: 150)
                Text(subtitle).font(Ink.serif(12)).foregroundStyle(Ink.faint)
                    .padding(.top, 2)
            }
            Spacer()
            if let trailing { trailing.padding(.top, 10) }
        }
        .padding(.horizontal, 32)
        .padding(.top, 34)
        .padding(.bottom, 8)
    }
}

// MARK: - Ruled rows (no cards on paper)

/// A block on the page: separated by a faint ink rule, washed on hover when
/// it can be clicked. Replaces floating white cards.
struct RuledRow: ViewModifier {
    var interactive: Bool = false
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 12)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovered && interactive ? Ink.sumi.opacity(0.045) : .clear)
            )
            .overlay(alignment: .bottom) { Rectangle().fill(Ink.line).frame(height: 1) }
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.15), value: hovered)
    }
}

extension View {
    func inkCard(interactive: Bool = false) -> some View {
        modifier(RuledRow(interactive: interactive))
    }
}

/// A short brush mark, kept for empty states.
struct BrushStroke: View {
    var body: some View { InkRule(seed: 11) }
}

// MARK: - Buttons

/// Secondary action: serif lettering in an ink outline on paper.
struct InkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        InkButtonBody(configuration: configuration)
    }

    private struct InkButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .font(Ink.serif(13, .semibold))
                .foregroundStyle(Ink.sumi)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Ink.sumi.opacity(configuration.isPressed ? 0.1 : (hovered ? 0.05 : 0)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Ink.sumi.opacity(0.4), lineWidth: 1)
                )
                .opacity(enabled ? 1 : 0.4)
                .onHover { hovered = $0 }
                .animation(.easeOut(duration: 0.12), value: hovered)
        }
    }
}

/// Primary action: vermilion, paper lettering — the seal's colour.
struct InkVermilionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        VermilionBody(configuration: configuration)
    }

    private struct VermilionBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(Ink.serif(13, .semibold))
                .foregroundStyle(Ink.paper)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Ink.vermilion.opacity(configuration.isPressed ? 0.8 : 1))
                )
                .shadow(color: Ink.vermilion.opacity(0.25), radius: 5, x: 0, y: 2)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .opacity(enabled ? 1 : 0.4)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// The large seal that carries a page's one primary act: a carved vermilion
/// character with its bilingual name beneath. Pressing presses it into the paper.
struct SealButton: View {
    let character: String
    let chinese: String
    let english: String
    var size: CGFloat = 92
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                InkSeal(character: character, size: size)
                    .rotationEffect(.degrees(hovered ? -2 : 0))
                    .shadow(color: Ink.vermilion.opacity(hovered ? 0.3 : 0.15), radius: hovered ? 10 : 5, x: 0, y: 3)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(chinese).font(Ink.brush(16)).foregroundStyle(Ink.vermilion)
                    Text(english).font(Ink.serif(12, .semibold)).foregroundStyle(Ink.sumi)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SealPress())
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovered = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovered)
        .accessibilityLabel(english)
    }

    private struct SealPress: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}

// MARK: - Controls

/// A search field written on the page: magnifier, serif text, a ruled line.
struct InkSearchField: View {
    @Binding var text: String
    var prompt: String = "Search"
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Ink.faint)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(Ink.serif(13))
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Ink.faint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            Rectangle().fill(focused ? Ink.vermilion : Ink.line).frame(height: focused ? 1.5 : 1)
        }
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}

/// A choice set in serif with a small chevron; opens a native menu.
struct InkChoice<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { value, title in
                Button(title) { selection = value }
            }
        } label: {
            HStack(spacing: 5) {
                Text(label).foregroundStyle(Ink.faint)
                Text(options.first { $0.0 == selection }?.1 ?? "").foregroundStyle(Ink.sumi)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Ink.faint)
            }
            .font(Ink.serif(13))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// A checkbox on paper: an ink square, filled vermilion with a paper tick when on.
struct InkCheck: View {
    @Binding var isOn: Bool
    var label: String = ""

    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(isOn ? Ink.vermilion : .clear)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(isOn ? Ink.vermilion : Ink.sumi.opacity(0.4), lineWidth: 1.2)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Ink.paper)
                    .opacity(isOn ? 1 : 0)
            }
            .frame(width: 15, height: 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: isOn)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "on" : "off")
    }
}

// MARK: - Waiting and emptiness

/// An ensō drawn again and again while work of unknown length runs.
struct EnsoLoop: View {
    var vermilion = false

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.8)
            let drawn = min(1, t / 2.0)
            Enso(progress: drawn * drawn * (3 - 2 * drawn), vermilion: vermilion)
                .opacity(t > 2.3 ? 1 - (t - 2.3) / 0.5 : 1)
        }
    }
}

/// An empty page: a faint carved character, a bilingual line, what to do next.
struct InkEmptyState: View {
    let character: String
    let chinese: String
    let english: String
    var detail: String? = nil

    var body: some View {
        VStack(spacing: 12) {
            Text(character)
                .font(Ink.brush(46))
                .foregroundStyle(Ink.faint.opacity(0.55))
                .frame(width: 74, height: 74)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Ink.faint.opacity(0.35), lineWidth: 1.2))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(chinese).font(Ink.brush(18))
                Text(english).font(Ink.serif(14))
            }
            if let detail {
                Text(detail).font(Ink.serif(12)).foregroundStyle(Ink.faint)
                    .multilineTextAlignment(.center).frame(maxWidth: 380)
            }
        }
    }
}

/// The ink action bar at a page's foot: paper, a brush rule above, the summary
/// on the left, the act on the right. Replaces grey material bars.
struct InkActionBar<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            InkRule(seed: 17).padding(.horizontal, 24)
            HStack(spacing: 12) {
                leading()
                Spacer()
                trailing()
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 12)
        }
    }
}

/// A page's stage: scrolls when it must, but sits centred in the space it has,
/// so a composition never clings to the top of an empty sheet.
struct CenteredStage<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                content()
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geo.size.height)
            }
        }
    }
}
