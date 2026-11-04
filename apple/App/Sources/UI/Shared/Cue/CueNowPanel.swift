import CueStore
import SwiftUI

/// Cue 的面板：只放 Cue 自己的、会天天变的，三端同这一份。手机与 iPad 是名牌长出的（`CueHeader`，名牌长成名片、面板在它下面），
/// Mac 是从 Cue 栏头的头像那一块长出的气泡（`CueTitle`：开合不逐帧长大，同额度明细）。沿中轴排三块：
/// 它的大脑（Agent、模型与思考强度，`CueConfigControls`）；它的记忆（`CueRecall`：刚记下的两条，整块点进记忆）；
/// 底下几行：它的定时（`ScheduleLine`，点了打开定时），它在用的技能与规则（`LibraryLine`，点了去技能与规则），它在哪台 Mac 上运行（点了进设置）与它的开关。
/// 上下文用了几成不在这里：换新是自动的、多在歇过一小时后，看了也没有可做的，只留在 Mac 的"运行情况"（`CueContextLine`，Cue 在这台 Mac 上值班时末尾多一行开它，`RunLine`）。
/// 在做的会话不在这里：进行中的在会话条上（手机在 Cue 页左边，宽屏在左栏），点进会话只有那一条路，返回落点与行的长相都只有一种。
/// 面板定高：空、一条、记满都一样高（两条各占两行的位），启用前后大脑那一块按启用了的样子占位（`BrainBlock`）。
/// 底下几行是点进去的行（`LinkRow`，高 `RowMetrics.height`），字离行框 `Spacing.inset`：那一组只让出面板内边多出的那一截，字与上面两块对齐，按下与悬停的底铺到面板边。
/// 还没启用（`CueWatch.canHear`）时没有刚记下与定时两项：它不值班，记忆与定时都不会动，面板里只有大脑（选在哪台运行）与底下的去处、开关。
/// 面板里不放滚动区（docs/layout.md）。Cue 的设置（`CueSettingsModel`）整块读一份：选 Mac 与底行的开关读写同一份，改 Mac 的确认框也只挂这一个。
struct CueNowPanel: View {
    let brain: AgentModelChoice?
    let close: () -> Void
    @Environment(Workspace.self) private var workspace
    @State private var settings = CueSettingsModel()

    /// 面板的字号上限：再大胶囊那一排连模型名都要截掉（iPhone 17 上辅助字号第二档就成了"Opus…"）。
    private static let largestType = DynamicTypeSize.accessibility1

    var body: some View {
        let enabled = workspace.cue.canHear
        VStack(spacing: Self.blockGap) {
            Group {
                BrainBlock(brain: brain, settings: settings)
                if enabled { CueRecall { go { workspace.cue.showsMemory = true } } }
            }
            .padding(.horizontal, Spacing.panel)
            VStack(spacing: 0) {
                if enabled { ScheduleLine { go { workspace.cue.showsSchedules = true } } }
                LibraryLine { go(openLibrary) }
                CueHostLine(model: settings) { go(openSettings) }
                #if os(macOS)
                RunLine { go { workspace.cue.showsRun.toggle() } }
                #endif
            }
            .padding(.horizontal, Spacing.panel - Spacing.inset)
        }
        .padding(.top, Spacing.group).padding(.bottom, Spacing.block)
        .dynamicTypeSize(...Self.largestType)
        .cueSettings(settings)
    }

    /// 点面板里的一项：先收起，再去那里。
    private func go(_ action: () -> Void) {
        close()
        action()
    }

    /// 技能与规则：手机推入那一页，Mac 换到主区。
    private func openLibrary() {
        #if os(macOS)
        workspace.show(.library)
        #else
        workspace.push(.library)
        #endif
    }

    /// 设置：手机推入设置页，Mac 开设置窗口的通用页（Cue 那一组在最上面）。
    private func openSettings() {
        #if os(macOS)
        SettingsPane.open(.general)
        #else
        workspace.push(.settings)
        #endif
    }

    /// 三块之间：组与组之间，取 4 点格上松的那一档。
    private static let blockGap: CGFloat = 24
}

/// 大脑那一排，启用前后同一块、同样高：
/// - 启用了：胶囊（可换 Agent、模型、思考强度）；
/// - 停用了（还记着那台 Mac）：同一排淡下去、不可点，看得到停用前用的是什么；
/// - 还没选过在哪台运行：没有可写的大脑（只会是"默认模型"的空胶囊），这一块换成一颗"选在哪台 Mac 上运行"，点开就地弹出 Mac 列表直接选（`CueHostPick`）。
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

    /// 停用时那一排的浓淡：看得清是什么，又读得出点不了。
    private static let dimmed = 0.4
}

/// "刚记下"：它最近记下的两条（没忘掉、不是定时的，新的在前，读 `CueStore.recentCueMemory`），
/// 右上"全部 N 条"（一条没有时只留箭头）；整块一个按钮，点了打开"Cue 记得什么"。
/// 一条只露正文前两行与记下多久（钉住的带图钉）；两条总占两条的位（没有的那条留空），空、少、满面板一样高。
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
            VStack(alignment: .leading, spacing: Spacing.group) {
                HStack(spacing: Spacing.glyph) {
                    Text("刚记下").font(Typography.label).foregroundStyle(palette.ink3)
                    Spacer(minLength: Spacing.item)
                    if let count = recent?.count, count > 0 {
                        Text("全部 \(count) 条").font(Typography.meta).monospacedDigit().foregroundStyle(palette.ink3)
                    }
                    Chevron(.forward).foregroundStyle(palette.ink3)
                }
                ForEach(0..<Self.shown, id: \.self) { index in
                    RecallLine(line: lines.indices.contains(index) ? lines[index] : nil)
                }
            }
            .overlay {
                if recent != nil, lines.isEmpty {
                    Text("还没记住什么").font(Typography.secondary).foregroundStyle(palette.ink3)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle())
        .observing(services.store, into: $recent, onError: workspace.fail) { try $0.recentCueMemory(limit: Self.shown) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Dotted(
            [String(localized: "刚记下")] + lines.map(\.text) + [String(localized: "全部 \(recent?.count ?? 0) 条")]).spoken)
        .accessibilityAddTraits(.isButton)
    }
}

/// "刚记下"的一条：正文至多两行（总占两行的位），行尾记下多久，钉住的在前面带图钉。
private struct RecallLine: View {
    let line: CueMemoryLine?
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.item) {
            Text(verbatim: line?.text ?? " ")
                .font(Typography.body).foregroundStyle(palette.ink).multilineTextAlignment(.leading)
                .lineLimit(2, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let line {
                HStack(spacing: Spacing.hair) {
                    if line.pinned { Image(.pin).font(Glyph.mark) }
                    Text(line.createdAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                }
                .font(Typography.meta).monospacedDigit().foregroundStyle(palette.ink3).fixedSize()
            }
        }
    }
}

/// 定时那一行：左边名字，行尾写下一次几点（没有定时时只有名字与箭头），点了打开定时（`CueSchedulePage`）。
private struct ScheduleLine: View {
    let open: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @State private var schedules: [CueMemoryLine]?

    var body: some View {
        let summary = schedules?.first?.remindAt.map { String(localized: "下一次 \(ScheduleText.moment($0))") }
        Button(action: open) {
            LinkRow(title: Text("定时"), value: summary.map { Text(verbatim: $0) }) { Image(.schedule) }
        }
        .buttonStyle(.row)
        .observing(services.store, into: $schedules, onError: workspace.fail) { try $0.cueScheduleLines() }
    }
}

/// 技能与规则那一行：左边名字，行尾写几个技能（有该整理的前面一颗墨点，同 Mac 侧栏那颗），点了推入技能与规则。还没有哪台 Mac 报过时只有名字与箭头。
private struct LibraryLine: View {
    let open: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let library = workspace.library
        let tidy = library?.tidies.isEmpty == false
        Button(action: open) {
            LinkRow(
                title: Text("技能与规则"), value: library.map { Text("\($0.skills.count) 个技能") }, alert: tidy ? palette.ink : nil
            ) { Image(.skill) }
        }
        .buttonStyle(.row)
        .accessibilityValue(tidy ? String(localized: "有该整理的") : "")
    }
}

/// 面板最底下一行：左边点了推入设置页（Cue 的名字、开关与在哪台 Mac 上运行在它最上面一组），右边是 Cue 的开关（`CueSwitch`，同设置里那一个）。
/// 左边一句说的是点进去是什么（`Lead`）：开着时是它在哪台 Mac 上运行，关着、还没选过时是"Cue 的设置"。原因只在真有问题时顶替这一句：
/// 开关没能写成（胭脂；还没选过 Mac 时开关不在，没写成的原因写在选 Mac 那一块下面）、它起不来（胭脂）、它那台 Mac 没开；
/// 说不准的（状态未确认）与平常的（已停用：开关已经说了）不写。
/// 名片上没有可数的时它不在的那一句已写在名字下面（`CueNow.quietLine`），同一屏不写两遍，这一句回到"Cue 的设置"。
/// 还没选过在哪台运行时开关占着位置、看不见：那时的下一步是上面的选 Mac（`CueHostPick`）；还没和 iCloud 对过、手机上还没有哪台 Mac 时开关停用。
private struct CueHostLine: View {
    let model: CueSettingsModel
    let open: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    /// 左边那一句。
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

/// 还没选在哪台运行时面板里唯一的下一步：一颗"选在哪台 Mac 上运行"（次按钮，与下面两个去处分开），点开是各入口同一份的 Mac 列表
/// （`CueHostMenu`），选一台就在那台启用、面板留着，启用了这一块换成大脑。启用中转圈，没写成的原因写在下面；
/// 还没和 iCloud 对过时只写在等什么，还没有哪台 Mac 写下过自己时写先去 Mac 上打开、同步不通时写同步那一行的标题（`CueSettings.noHost`）。
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

#if os(macOS)
/// "运行情况"那一行（给开发者看）：只在 Cue 于这台 Mac 值班时有（经过只在值班的管理器里），点了开合 Cue 页右边的运行情况（`CueRunPanel`）。
private struct RunLine: View {
    let toggle: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        if services.cue.keeper != nil {
            Button(action: toggle) {
                LinkRow(title: Text("运行情况"), chevron: false) {
                    Image(.session)
                } trailing: {
                    if workspace.cue.showsRun { Image(.checked).foregroundStyle(palette.ink3) }
                }
            }
            .buttonStyle(.row)
            .accessibilityAddTraits(workspace.cue.showsRun ? .isSelected : [])
        }
    }
}
#endif
