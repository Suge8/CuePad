import CueStore
import SwiftUI

/// 上下文用了几成不写：换新是自动的、多在歇过一小时后，看了也没有可做的。
/// 在做的会话不在这里：进行中的在会话条上（手机在 Cue 页左边，宽屏在左栏），点进会话只有那一条路，返回落点与行的长相都只有一种。
/// 一格一件事的拼格（`CueTile`，每一格都是同一块淡底）：大脑一格，刚记下的两条一格，定时与技能各半格，在哪台运行一格。
/// 面板定高：空、一条、记满都一样高（两条各占一行的位），启用前后大脑那一块按启用了的样子占位（`BrainBlock`）。
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
        VStack(spacing: Spacing.item) {
            BrainBlock(brain: brain, settings: settings)
                .padding(.vertical, Spacing.item).frame(maxWidth: .infinity)
                .background(CueTile.fill)
            if enabled { CueRecall { go { workspace.cue.showsMemory = true } } }
            HStack(spacing: Spacing.item) {
                if enabled { ScheduleTile { go { workspace.cue.showsSchedules = true } } }
                LibraryTile { go(openLibrary) }
            }
            .fixedSize(horizontal: false, vertical: true)
            CueHostLine(model: settings) { go(openSettings) }
                .padding(.vertical, Spacing.tight)
                .background(CueTile.fill)
                .rowContainer(CueTile.shape)
        }
        .padding(Spacing.group)
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

/// 拼格的一格：一块淡底，四周同一道边。
private enum CueTile {
    static let shape = RoundedRectangle(cornerRadius: Radius.block)

    @MainActor static var fill: some View { Fill() }

    private struct Fill: View {
        @Environment(\.palette) private var palette
        var body: some View { shape.fill(palette.fill) }
    }
}

private extension View {
    /// `paired`：并排的两格取齐高（那一排自己收成内容的高）。
    func cueTile(paired: Bool = false) -> some View {
        padding(Spacing.group).frame(maxWidth: .infinity, maxHeight: paired ? .infinity : nil, alignment: .topLeading)
            .background(CueTile.fill).contentShape(CueTile.shape)
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
    }

    private static let dimmed = 0.4
}

/// 记忆那一格：最近记下的两条各一行（字在左、几时记的在右），点哪里都去记忆页。
private struct CueRecall: View {
    let open: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var recent: CueMemoryRecent?

    nonisolated private static let shown = 2

    var body: some View {
        let lines = recent?.lines ?? []
        Button(action: open) {
            VStack(alignment: .leading, spacing: Spacing.item) {
                TileHead(icon: .memory, title: Text("刚记下")) {
                    if let count = recent?.count, count > 0 { Text("全部 \(count) 条").monospacedDigit() }
                }
                VStack(alignment: .leading, spacing: Spacing.glyph) {
                    ForEach(0..<Self.shown, id: \.self) { index in
                        RecallLine(line: lines.indices.contains(index) ? lines[index] : nil)
                    }
                }
                .overlay(alignment: .leading) {
                    if recent != nil, lines.isEmpty {
                        Text("还没记住什么").font(Typography.body).foregroundStyle(palette.ink3)
                    }
                }
            }
            .cueTile()
        }
        .buttonStyle(PressStyle())
        .observing(services.store, into: $recent, onError: workspace.fail) { try $0.recentCueMemory(limit: Self.shown) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Dotted(
            [String(localized: "刚记下")] + lines.map(\.text) + [String(localized: "全部 \(recent?.count ?? 0) 条")]).spoken)
        .accessibilityAddTraits(.isButton)
    }
}

private struct RecallLine: View {
    let line: CueMemoryLine?
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.item) {
            Text(verbatim: line?.text ?? " ")
                .font(Typography.body.weight(.medium)).foregroundStyle(palette.ink).lineLimit(1)
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

/// 一格顶上那一行：签名色的图标与名字，右边是去处的小字与箭头。
private struct TileHead<Trailing: View>: View {
    let icon: Icon
    let title: Text
    @ViewBuilder var trailing: Trailing
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Spacing.glyph) {
            Image(icon).foregroundStyle(palette.signature)
            title.foregroundStyle(palette.ink2)
            Spacer(minLength: Spacing.item)
            trailing.font(Typography.meta).foregroundStyle(palette.ink3)
            Chevron(.forward).foregroundStyle(palette.ink3)
        }
        .font(Typography.secondary).lineLimit(1)
    }
}

/// 一格去处：名字在上，此刻的那个数在下面大一号。
private struct LinkTile: View {
    let icon: Icon
    let title: Text
    var value: Text?
    var alert: Color?
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.item) {
            TileHead(icon: icon, title: title) { EmptyView() }
            HStack(spacing: Spacing.glyph) {
                (value ?? Text(verbatim: "—")).font(Typography.bodyStrong).monospacedDigit().foregroundStyle(value == nil ? palette.ink3 : palette.ink)
                    .lineLimit(1).minimumScaleFactor(0.8)
                if let alert { StatusDot(color: alert) }
            }
        }
        .cueTile(paired: true)
        .accessibilityElement(children: .combine)
    }
}

private struct ScheduleTile: View {
    let open: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @State private var schedules: [CueMemoryLine]?

    var body: some View {
        Button(action: open) {
            LinkTile(icon: .schedule, title: Text("定时"), value: schedules?.first?.remindAt.map { Text(verbatim: ScheduleText.moment($0)) })
        }
        .buttonStyle(PressStyle())
        .observing(services.store, into: $schedules, onError: workspace.fail) { try $0.cueScheduleLines() }
    }
}

private struct LibraryTile: View {
    let open: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let library = workspace.library
        let tidy = library?.tidies.isEmpty == false
        Button(action: open) {
            LinkTile(icon: .skill, title: Text("技能与规则"), value: library.map { Text("\($0.skills.count) 个技能") }, alert: tidy ? palette.ink : nil)
        }
        .buttonStyle(PressStyle())
        .accessibilityValue(tidy ? String(localized: "有该整理的") : "")
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
