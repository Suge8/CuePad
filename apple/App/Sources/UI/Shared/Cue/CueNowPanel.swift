import CueStore
import SwiftUI

/// 上下文用了几成不写：换新是自动的、多在歇过一小时后，看了也没有可做的。
/// 在做的会话不在这里：进行中的在会话条上（手机在 Cue 页左边，宽屏在左栏），点进会话只有那一条路，返回落点与行的长相都只有一种。
/// 整块只有面板这一层底，里面不再套卡：分组靠留白与字的大小。从上到下：大脑一排胶囊；三个大数（记忆、定时、技能，各是去那一页的入口，`CueFigures`）；
/// 刚记下的两条；在哪台运行与开关。左右各一条边线（`Spacing.panel`），每一组都贴着它。
/// 面板定高：空、一条、记满都一样高（两条各占一行的位），启用前后大脑那一块按启用了的样子占位（`BrainBlock`）。
/// 否决过：每组一块淡底的拼格——面板本身已是一张浮起的卡，里面再铺五块底就是卡套卡，胶囊在底上又多一层。
/// 面板里不放滚动区：会被写上页面滚动区的内容边距。Cue 的设置（`CueSettingsModel`）整块读一份：选 Mac 与底行的开关读写同一份，改 Mac 的确认框也只挂这一个。
struct CueNowPanel: View {
    let brain: AgentModelChoice?
    let close: () -> Void
    @Environment(Workspace.self) private var workspace
    @State private var settings = CueSettingsModel()

    /// 面板的字号上限：再大胶囊那一排连模型名都要截掉（iPhone 17 上辅助字号第二档就成了"Opus…"）。
    private static let largestType = DynamicTypeSize.accessibility1

    var body: some View {
        let enabled = workspace.cue.canHear
        VStack(spacing: Spacing.part) {
            BrainBlock(brain: brain, settings: settings)
            Group {
                CueFigures(enabled: enabled, memory: { go { workspace.cue.showsMemory = true } }, schedules: { go { workspace.cue.showsSchedules = true } }, library: { go(openLibrary) })
                if enabled { CueRecall { go { workspace.cue.showsMemory = true } } }
            }
            .padding(.horizontal, Spacing.panel)
            CueHostLine(model: settings) { go(openSettings) }
                // 悬停的底就是这一行自己的圆角块（同上面几组）：默认的行底向两边出血，在这里会顶到面板的边、被圆角裁掉
                .rowContainer(RoundedRectangle(cornerRadius: Radius.row), flush: true)
                // 行首图标在它那一列里居中，往左收两点，图标的左沿才对上面几组的字
                .padding(.horizontal, Spacing.panel - Spacing.inset - Spacing.hair)
                .padding(.top, -Spacing.item)
        }
        .padding(.top, Spacing.block).padding(.bottom, Spacing.group)
        .dynamicTypeSize(...Self.largestType)
        .cueSettings(settings)
    }

    private func go(_ action: () -> Void) {
        close()
        action()
    }

    private func openLibrary() {
        #if os(macOS)
        workspace.show(.library)
        #else
        workspace.push(.library)
        #endif
    }

    private func openSettings() {
        #if os(macOS)
        SettingsPane.open(.general)
        #else
        workspace.push(.settings)
        #endif
    }
}

/// 高度总由启用了的那一排定（看不见时也排着），换态时面板不变高。
private struct BrainBlock: View {
    let brain: AgentModelChoice?
    let settings: CueSettingsModel
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let cue = workspace.cue
        let chosen = cue.hostID != nil
        CueConfigControls(choice: brain, alignment: .center)
            .opacity(chosen ? (cue.canHear ? 1 : Self.dimmed) : 0)
            .disabled(!cue.canHear)
            .readerHidden(!chosen)
            .overlay {
                if !chosen { CueHostPick(model: settings) }
            }
            .padding(.horizontal, Spacing.panel)
    }

    private static let dimmed = 0.4
}

/// 三个大数一排，每个是去那一页的入口：数是主角，底下一行小字说它是什么。排法见 `Spread`。没启用时只剩技能那一个（记忆与定时要 Cue 在）。
private struct CueFigures: View {
    let enabled: Bool
    let memory: () -> Void
    let schedules: () -> Void
    let library: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var count: Int?
    @State private var next: [CueMemoryLine]?

    var body: some View {
        let skills = workspace.library
        let tidy = skills?.tidies.isEmpty == false
        Spread(gap: Spacing.item) {
            if enabled {
                Figure(value: count.map { Text(verbatim: "\($0)") }, caption: Text("记忆"), action: memory)
                Figure(
                    value: next?.first?.remindAt.map { Text(verbatim: Self.clock($0)) },
                    caption: Text(Dotted(String(localized: "定时"), next?.first.flatMap { ScheduleText.overdue($0) ?? $0.remindAt.map(Self.day) })),
                    edge: .center, action: schedules)
            }
            Figure(
                value: skills.map { Text(verbatim: "\($0.skills.count)") }, caption: Text("技能与规则"), alert: tidy ? palette.ink : nil,
                edge: enabled ? .trailing : .leading, action: library)
                .accessibilityValue(tidy ? String(localized: "有该整理的") : "")
        }
        .observing(services.store, into: $count, onError: workspace.fail) { try $0.recentCueMemory(limit: 0).count }
        .observing(services.store, into: $next, onError: workspace.fail) { try $0.cueScheduleLines() }
    }

    /// 只写几点几分、不带上午下午：三个数差不多宽才排得齐，"上午 8:00"比旁边两个数宽出一倍。12 小时制还是 24 小时制跟系统的设置。
    private static func clock(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
    }

    /// 哪一天；12 小时制时上午下午接在它后面（大数里省掉的那半句）。
    private static func day(_ date: Date) -> String {
        let calendar = Calendar.current, shown = date.formatted(date: .omitted, time: .shortened)
        let period = [calendar.amSymbol, calendar.pmSymbol].first(where: shown.contains)
        return [ScheduleText.day(date), period].compactMap(\.self).joined(separator: " ")
    }
}

/// 头一个贴左边、末一个贴右边、中间那个压在正中；正中放不下时让开宽的那一头，还放不下就只给它两头剩下的宽（它的小字自己缩）。
/// 不分三等份：小字长短差得多（英文的"Schedule · Tomorrow AM"），等分时中间那格先被截。只有一个时贴左边。
private struct Spread: Layout {
    let gap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let natural = sizes.reduce(0) { $0 + $1.width } + gap * CGFloat(max(sizes.count - 1, 0))
        return CGSize(width: proposal.width ?? natural, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let first = subviews.first, let last = subviews.last else { return }
        let lead = first.sizeThatFits(.unspecified).width
        first.place(at: bounds.origin, proposal: .unspecified)
        guard subviews.count > 1 else { return }
        let trail = last.sizeThatFits(.unspecified).width
        last.place(at: CGPoint(x: bounds.maxX - trail, y: bounds.minY), proposal: .unspecified)
        let low = bounds.minX + lead + gap, room = bounds.maxX - trail - gap - low
        for middle in subviews.dropFirst().dropLast() {
            let fit = ProposedViewSize(width: room, height: nil), width = middle.sizeThatFits(fit).width
            middle.place(at: CGPoint(x: max(low, min(bounds.midX - width / 2, low + room - width)), y: bounds.minY), proposal: fit)
        }
    }
}

private struct Figure: View {
    let value: Text?
    let caption: Text
    var alert: Color?
    var edge = HorizontalAlignment.leading
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            VStack(alignment: edge, spacing: Spacing.hair) {
                (value ?? Text(verbatim: "—")).font(Typography.heading).monospacedDigit().foregroundStyle(value == nil ? palette.ink3 : palette.ink)
                    .lineLimit(1).minimumScaleFactor(0.6)
                HStack(spacing: Spacing.tight) {
                    if let alert { StatusDot(color: alert) }
                    caption.lineLimit(1).minimumScaleFactor(0.8)
                    Chevron(.forward)
                }
                .font(Typography.meta).foregroundStyle(palette.ink3)
            }
            .fixedSize(horizontal: false, vertical: true)
            .hoverRoom()
        }
        .buttonStyle(PressStyle())
        .hoverRoomTaken()
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    /// 面板里不带框的按钮：悬停的淡底比字宽出一圈，不贴着字的边画；`hoverRoomTaken` 在按钮外把这一圈收回，字仍对着面板的边线。
    func hoverRoom(_ side: CGFloat = Spacing.item) -> some View { padding(.horizontal, side).padding(.vertical, Spacing.glyph).contentShape(.rect) }
    func hoverRoomTaken(_ side: CGFloat = Spacing.item) -> some View { padding(.horizontal, -side).padding(.vertical, -Spacing.glyph) }
}

/// 最近记下的两条各一行（字在左、几时记的在右），点哪里都去记忆页。
private struct CueRecall: View {
    let open: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var recent: CueMemoryRecent?

    nonisolated private static let shown = 2
    /// 悬停底的两边与底下运行那一行的对齐（那一行离面板边 `panel - inset - hair`）。
    private static let room = Spacing.inset + Spacing.hair

    var body: some View {
        let lines = recent?.lines ?? []
        Button(action: open) {
            VStack(alignment: .leading, spacing: Spacing.glyph) {
                Text("刚记下").font(Typography.label).foregroundStyle(palette.ink3)
                ForEach(0..<Self.shown, id: \.self) { index in
                    RecallLine(line: lines.indices.contains(index) ? lines[index] : nil)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if recent != nil, lines.isEmpty {
                    Text("还没记住什么").font(Typography.body).foregroundStyle(palette.ink3)
                }
            }
            .hoverRoom(Self.room)
        }
        .buttonStyle(PressStyle())
        .hoverRoomTaken(Self.room)
        .observing(services.store, into: $recent, onError: workspace.fail) { try $0.recentCueMemory(limit: Self.shown) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Dotted([String(localized: "刚记下")] + lines.map(\.text)).spoken)
        .accessibilityAddTraits(.isButton)
    }
}

private struct RecallLine: View {
    let line: CueMemoryLine?
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.item) {
            Text(verbatim: line?.text ?? " ")
                .font(Typography.body).foregroundStyle(palette.ink).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let line {
                HStack(spacing: Spacing.hair) {
                    if line.pinned { Image(.pin).font(Glyph.mark).foregroundStyle(palette.signature) }
                    Text(line.createdAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                }
                .font(Typography.meta).monospacedDigit().foregroundStyle(palette.ink3).fixedSize()
            }
        }
    }
}

/// 名片上没有可数的时它不在的那一句已写在名字下面（`CueNow.quietLine`），同一屏不写两遍，这一句回到"Cue 的设置"。
/// 还没选过在哪台运行时开关占着位置、看不见：那时的下一步是上面的选 Mac（`CueHostPick`）；还没和 iCloud 对过、手机上还没有哪台 Mac 时开关停用。
private struct CueHostLine: View {
    let model: CueSettingsModel
    let open: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    fileprivate enum Lead {
        case host(String)
        case settings(String)
        case problem(String, failed: Bool)
    }

    var body: some View {
        let lead = lead
        let settings = model.settings ?? .empty
        LinkRow(title: Text(lead.text).foregroundStyle(lead.failed ? palette.failure : palette.ink), open: open) {
            Image(lead.icon)
        } trailing: {
            CueSwitch(model: model, here: workspace.localHost)
                .disabled(!model.isOn && (settings.gate(services).waitingReason != nil || settings.hosts(here: workspace.localHost).isEmpty))
                .opacity(workspace.cue.hostID == nil ? 0 : 1)
                .readerHidden(workspace.cue.hostID == nil)
        }
        .animation(Motion.fade, value: lead.text)
    }

    private var lead: Lead {
        let cue = workspace.cue
        if cue.hostID != nil, let failure = model.failure { return .problem(failure, failed: true) }
        let host = cue.hostName ?? MacAgents.unnamed
        let settings = Lead.settings(String(localized: "\(cue.name) 的设置"))
        switch cue.presence {
        case .disabled: return settings
        case .asleep, .unreachable:
            guard !cue.now.ledger.isEmpty, let why = cue.presence.line(host: host, ranBefore: true) else { return settings }
            return .problem(why, failed: cue.presence.isUnreachable)
        case .unconfirmed, .idle, .sending, .working: return .host(String(localized: "在「\(host)」上运行"))
        }
    }
}

private extension CueHostLine.Lead {
    var text: String {
        switch self {
        case .host(let text), .settings(let text), .problem(let text, _): text
        }
    }

    var icon: Icon {
        if case .settings = self { .settings } else { .mac }
    }

    var failed: Bool {
        if case .problem(_, failed: true) = self { true } else { false }
    }
}

private struct CueHostPick: View {
    let model: CueSettingsModel
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    private static var title: String { String(localized: "选在哪台 Mac 上运行") }

    var body: some View {
        let settings = model.settings ?? .empty
        let hosts = settings.hosts(here: workspace.localHost)
        VStack(spacing: Spacing.glyph) {
            if let waiting = settings.gate(services).waitingReason {
                HStack(spacing: Spacing.item) {
                    Spinner(.small)
                    Text(waiting)
                }
                .font(Typography.secondary).foregroundStyle(palette.ink3)
            } else if hosts.isEmpty {
                // 只在手机上：Mac 上这台总在列表里
                #if os(iOS)
                Text(CueSettings.noHost(services)).font(Typography.secondary).foregroundStyle(palette.ink3)
                #endif
            } else {
                HStack(spacing: Spacing.item) {
                    CueHostMenu(hosts: hosts, use: .enable { model.choose($0, services) }, accessibilityLabel: Self.title) {
                        Label(Self.title, icon: .mac)
                            .labelStyle(.titleAndIcon)
                            .modifier(ControlSurface())
                    }
                    if model.enabling != nil { Spinner(.small) }
                }
                .disabled(model.enabling != nil)
            }
            if let failure = model.failure {
                Text(failure).font(Typography.meta).foregroundStyle(palette.failure).multilineTextAlignment(.center).lineLimit(2)
            }
        }
    }
}
