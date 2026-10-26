#if os(iOS)
import CueStore
import SwiftUI

/// Cue 名牌长出的面板（`CueHeader`）：只放 Cue 自己的、会天天变的（Mac 上这些分在 Cue 页输入框、记忆弹层与设置里）。名牌长成的名片之下沿中轴排三块：
/// 它的大脑（Agent、模型与思考强度，`CueConfigControls`）；它刚记下的两条（`CueRecall`，整块点进记忆）；
/// 底下两行：它在用的技能与说明（`LibraryLine`，点了推入技能与说明），它在哪台 Mac 上运行、点了进设置。
/// 上下文用了几成不在这里：换新是自动的、多在歇过一小时后，看了也没有可做的，只留在 Mac 的"运行情况"（`CueContextLine`）。
/// 在做的会话不在这里：进行中的在进展页的会话段（左滑就到），点进会话只有那一条路，返回落点与行的长相都只有一种。
/// 面板定高：空、一条、记满都一样高（两条各占两行的位），启用前后大脑那一块按启用了的样子占位（`BrainBlock`）。
/// 面板里不放滚动区（docs/ui.md 布局约束）。
struct CueNowPanel: View {
    let brain: AgentModelChoice?
    let close: () -> Void
    @Environment(Workspace.self) private var workspace

    /// 面板的字号上限：再大胶囊那一排连模型名都要截掉（iPhone 17 上辅助字号第二档就成了"Opus…"）。
    private static let largestType = DynamicTypeSize.accessibility1

    var body: some View {
        VStack(spacing: 22) {
            BrainBlock(brain: brain)
            CueRecall { go { workspace.cue.showsMemory = true } }
            VStack(spacing: 6) {
                LibraryLine { go { workspace.push(.library) } }
                CueHostLine { go { workspace.push(.settings) } }
            }
        }
        .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 18)
        .dynamicTypeSize(...Self.largestType)
    }

    /// 点面板里的一项：先收起，再去那里。
    private func go(_ action: () -> Void) {
        close()
        action()
    }
}

/// 大脑那一排，启用前后同一块、同样高：
/// - 启用了：胶囊（可换 Agent、模型、思考强度）；
/// - 停用了（还记着那台 Mac）：同一排淡下去、不可点，看得到停用前用的是什么；
/// - 还没选过在哪台运行：没有可写的大脑（只会是"默认模型"的空胶囊），这一块换成一颗"选在哪台 Mac 上运行"，点开就地弹出 Mac 列表直接选（`CueHostPick`）。
/// 高度总由启用了的那一排定（看不见时也排着），换态时面板不变高。
private struct BrainBlock: View {
    let brain: AgentModelChoice?
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let cue = workspace.cue
        let chosen = cue.hostID != nil
        CueConfigControls(choice: brain, alignment: .center)
            .opacity(chosen ? (cue.canHear ? 1 : Self.dimmed) : 0)
            .disabled(!cue.canHear)
            .accessibilityHidden(!chosen)
            .overlay {
                if !chosen { CueHostPick() }
            }
    }

    /// 停用时那一排的浓淡：看得清是什么，又读得出点不了。
    private static let dimmed = 0.4
}

/// "刚记下"：它最近记下的两条（没忘掉的，新的在前，读 `CueStore.recentCueMemory`），右上"全部 N 条"（一条没有时只留箭头）；整块一个按钮，点了打开"Cue 记得什么"。
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
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Text("刚记下").font(Typography.label).foregroundStyle(palette.ink3)
                    Spacer(minLength: 8)
                    if let count = recent?.count, count > 0 {
                        Text("全部 \(count) 条").font(Typography.meta).monospacedDigit().foregroundStyle(palette.ink3)
                    }
                    Image(.forward).font(.caption2.weight(.semibold)).foregroundStyle(palette.ink3)
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
        .accessibilityLabel(Dotted([String(localized: "刚记下")] + lines.map(\.text) + [String(localized: "全部 \(recent?.count ?? 0) 条")]).spoken)
        .accessibilityAddTraits(.isButton)
    }
}

/// "刚记下"的一条：正文至多两行（总占两行的位），行尾记下多久，钉住的在前面带图钉。
private struct RecallLine: View {
    let line: CueMemoryLine?
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: line?.text ?? " ")
                .font(Typography.body).foregroundStyle(palette.ink).multilineTextAlignment(.leading)
                .lineLimit(2, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let line {
                HStack(spacing: 3) {
                    if line.pinned { Image(.pin).font(.caption2) }
                    Text(line.createdAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                }
                .font(Typography.meta).monospacedDigit().foregroundStyle(palette.ink3).fixedSize()
            }
        }
    }
}

/// 技能与说明那一行：左边名字，行尾写几个技能（有要整理的写几件要整理），点了推入技能与说明。还没有哪台 Mac 报过时只有名字与箭头。
private struct LibraryLine: View {
    let open: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let library = workspace.library
        let summary = library.map { library in
            library.tidies.isEmpty ? String(localized: "\(library.skills.count) 个技能") : String(localized: "\(library.tidies.count) 件要整理")
        }
        Button(action: open) {
            HStack(spacing: 8) {
                Image(.skill).foregroundStyle(palette.ink3)
                Text("技能与说明").foregroundStyle(palette.ink2).lineLimit(1)
                Spacer(minLength: 8)
                if let summary {
                    Text(verbatim: summary).monospacedDigit().foregroundStyle(library?.tidies.isEmpty == false ? palette.ink : palette.ink3)
                }
                Image(.forward).font(.caption2.weight(.semibold)).foregroundStyle(palette.ink3)
            }
            .font(Typography.secondary)
            .frame(minHeight: 28)
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Dotted(String(localized: "技能与说明"), summary).spoken)
        .accessibilityAddTraits(.isButton)
    }
}

/// 面板最底下一行，点了推入设置页（Cue 的名字与在哪台 Mac 上运行在它最上面一组），左边一句、行尾"设置"：
/// 在线时写它在哪台 Mac 上运行；不在时写为什么（同名牌，`CuePresence.line`：已停用、还没启用、某台没开），
/// 但名片上没有可数的时那一句已写在名字下面（`CueNow.quietLine`），同一屏不写两遍，这一行只剩去设置的路。
private struct CueHostLine: View {
    let open: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let place = place
        Button(action: open) {
            HStack(spacing: 8) {
                Image(place == nil ? .settings : .mac).foregroundStyle(palette.ink3)
                if let place {
                    Text(place).foregroundStyle(palette.ink2).lineLimit(1)
                    Spacer(minLength: 8)
                    Text("设置").foregroundStyle(palette.ink3)
                } else {
                    Text("设置").foregroundStyle(palette.ink2)
                    Spacer(minLength: 8)
                }
                Image(.forward).font(.caption2.weight(.semibold)).foregroundStyle(palette.ink3)
            }
            .font(Typography.secondary)
            .frame(minHeight: 28)
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Dotted(place, String(localized: "设置")).spoken)
        .accessibilityAddTraits(.isButton)
    }

    private var place: String? {
        let cue = workspace.cue
        let host = cue.hostName ?? MacAgents.unnamed
        guard let away = cue.presence.line(host: host, ranBefore: cue.hostID != nil) else { return String(localized: "在「\(host)」上运行") }
        return cue.now.ledger.isEmpty ? nil : away
    }
}

/// 还没选在哪台运行时面板里唯一的下一步：一颗"选在哪台 Mac 上运行"（选中那一档的靛青，与下面两个去处分开），点开是各入口同一份的 Mac 列表
/// （`CueHostMenu`），选一台就在那台启用、面板留着，启用了这一块换成大脑。启用中转圈，没写成的原因写在下面；
/// 还没和 iCloud 对过时只写在等什么，还没有哪台 Mac 写下过自己时写先去 Mac 上打开、同步不通时写同步那一行的标题（`CueSettings.noHost`）。
private struct CueHostPick: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var model = CueSettingsModel()

    private static var title: String { String(localized: "选在哪台 Mac 上运行") }

    var body: some View {
        let settings = model.settings ?? .empty
        let hosts = settings.hosts(here: nil)
        VStack(spacing: 6) {
            if let waiting = settings.gate(services).waitingReason {
                HStack(spacing: 8) {
                    Spinner(.small)
                    Text(waiting)
                }
                .font(Typography.secondary).foregroundStyle(palette.ink3)
            } else if hosts.isEmpty {
                Text(CueSettings.noHost(services)).font(Typography.secondary).foregroundStyle(palette.ink3)
            } else {
                HStack(spacing: 8) {
                    CueHostMenu(hosts: hosts, use: .enable { model.choose($0, services) }, accessibilityLabel: Self.title) {
                        Label(Self.title, icon: .mac)
                            .labelStyle(.titleAndIcon)
                            .modifier(ControlSurface(kind: .highlight))
                    }
                    if model.enabling != nil { Spinner(.small) }
                }
                .disabled(model.enabling != nil)
            }
            if let failure = model.failure {
                Text(failure).font(Typography.meta).foregroundStyle(palette.failure).multilineTextAlignment(.center).lineLimit(2)
            }
        }
        .cueSettings(model)
    }
}
#endif
