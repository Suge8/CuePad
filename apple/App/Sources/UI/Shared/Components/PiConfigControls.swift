import CueStore
import SwiftUI


/// Mac 的 ⌘⇧M、⌘⇧E（`ReplyShortcut`）请弹出的那个菜单。
enum PiConfigPick { case model, thinking }


/// Agent 胶囊的内容（新会话与 Cue，`PiConfigControls.init(choice:)`）：能选的几家与当前那家；只有一家且就是它时胶囊只写它、不能点。
struct PiAgentPick {
    let kinds: [AgentKind]
    let current: AgentKind
    let choose: (AgentKind) -> Void

    var choosable: Bool { kinds.count > 1 || !kinds.contains(current) }

    var menu: [ChoiceMenu.Section] {
        [ChoiceMenu.Section(title: "Agent", choices: kinds.map { kind in
            ChoiceMenu.Choice(title: .verbatim(kind.name), image: .brand(kind.mark), checked: kind == current) { choose(kind) }
        })]
    }
}


/// 模型菜单，两端同一份：可选的模型按提供方分组（`PiModelLabel.groups`），组名写提供方与它的额度用量（`PiModelLabel.title`，过重置时间无新观测显示过期）；
/// 每项的名字与标志按模型定（`BrandMark.model`），不指定模型时用的那项（`defaultModel`，新会话与 Cue）在名字下注"默认"，当前打勾。选了做什么由调用方给。
struct PiModelMenu {
    let models: [PiModelOption]
    var defaultModel: PiModelKey?
    let current: PiModelKey?
    let choose: (PiModelOption) -> Void

    func sections(quotas: [AccountQuota], at now: Date) -> [ChoiceMenu.Section] {
        PiModelLabel.groups(models).map { group in
            ChoiceMenu.Section(
                title: .verbatim(group.models.first?.account?.source != nil ? group.provider.name : group.models.first.map { PiModelLabel.title($0, quotas: quotas, at: now) } ?? group.provider.name), image: group.provider.mark.map(ChoiceMenu.Glyph.brand),
                choices: group.models.map { model in
                    ChoiceMenu.Choice(
                        title: .verbatim(model.displayName), subtitle: model.account?.source != nil ? .verbatim(PiModelLabel.title(model, quotas: quotas, at: now)) : model.key == defaultModel ? "默认" : nil, image: BrandMark.model(model).map(ChoiceMenu.Glyph.brand),
                        checked: model.key == current) { choose(model) }
                })
        }
    }
}


extension PiModelMenu {
    /// 一个会话的模型菜单（回复框的模型胶囊与出错块的"换个模型"同一份）：选了就换这个会话的模型。
    static func session(_ session: PiSessionState, models: [PiModelOption], current: PiModelKey?, in workspace: Workspace) -> PiModelMenu {
        PiModelMenu(models: models, current: current) { model in
            workspace.attempt { _ = try await workspace.services.configure(PiConfig(model: model.key), for: session) }
        }
    }
}


/// 输入框工具排里的模型与思考强度（会话页回复框 `SessionConfigControls`；新会话与 Cue（`init(choice:)`）在最左再放一枚 Agent 胶囊 `PiAgentCapsule`）：模型胶囊（模型的标志 + 模型短名；
/// 有订阅额度的提供方，标志外一圈细环是卡着的那个窗口还剩多少。点开是分好组的菜单，当前打勾），右边思考强度胶囊（"思考"的标 + 一组竖格：格数是可选的档位，一格比一格高，
/// 当前档以下填满，关着时格全空、一道斜线；手机点一下循环到模型支持的下一档，Mac 点在哪格或横着拖就调到哪档；
/// Mac 按下就在上方浮出档位名，松手后停一会儿再淡出，点“思考”的标只看现在是哪档；最高档填色有一道流光），再往右是调用方给的（会话页的上下文用量）。
/// 只管显示与选择：可选什么、当前值、送达中（填色轻轻呼吸）、选了之后做什么都由调用方给；没换成的原因由 `MacInputNotice` 叠在输入框上方。减弱动态效果时没有流光与呼吸。
struct PiConfigControls<Trailing: View>: View {
    /// 最左的 Agent 胶囊；会话的 Agent 换不了，不给。
    var agent: PiAgentPick?
    let models: PiModelMenu
    let shown: PiConfigShown
    /// 胶囊上没有当前模型时写的。
    let unnamed: LocalizedStringResource
    /// 思考强度可选的档；空时不放思考强度。
    let levels: [PiThinkingLevel]
    let chooseThinking: (PiThinkingLevel) -> Void
    let chooseFast: (Bool) -> Void
    /// 键盘请弹出的菜单（只有 Mac 有这个入口）：弹出后清掉。
    let opening: Binding<PiConfigPick?>
    let trailing: Trailing
    /// 这一排在给的宽里靠哪边（Cue 面板里居中）。
    var alignment = Alignment.leading
    @Environment(AppServices.self) var services
    #if os(macOS)
    /// 键盘弹出的菜单贴着哪枚胶囊。
    @State var anchors = [PiConfigPick.model: PopUpAnchor(), .thinking: PopUpAnchor()]
    #endif

    init(
        agent: PiAgentPick? = nil, models: PiModelMenu, shown: PiConfigShown, unnamed: LocalizedStringResource = "模型", levels: [PiThinkingLevel],
        opening: Binding<PiConfigPick?> = .constant(nil), chooseThinking: @escaping (PiThinkingLevel) -> Void,
        chooseFast: @escaping (Bool) -> Void = { _ in },
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.agent = agent
        self.models = models
        self.shown = shown
        self.unnamed = unnamed
        self.levels = levels
        self.opening = opening
        self.chooseThinking = chooseThinking
        self.chooseFast = chooseFast
        self.trailing = trailing()
    }

    func aligned(_ alignment: Alignment) -> Self {
        var aligned = self
        aligned.alignment = alignment
        return aligned
    }

    var body: some View {
        ConfigRow {
            if let agent { PiAgentCapsule(pick: agent).layoutValue(key: ConfigGive.self, value: [.agent]) }
            modelCapsule.layoutValue(key: ConfigGive.self, value: [.model])
            if let model = shown.model, let url = model.account?.usageURL(provider: model.key.provider) {
                Link("管理用量", destination: url).font(Typography.meta).buttonStyle(PressStyle())
            }
            if let meter = PiThinkingMeter(levels: levels, current: shown.thinking) {
                PiThinkingDial(meter: meter, pending: shown.pending, choose: chooseThinking)
                    #if os(macOS)
                    .popUpAnchor(anchors[.thinking])
                    #endif
                    .layoutValue(key: ConfigGive.self, value: [.wording, .secondary])
            }
            if shown.model?.supportsFast == true {
                PiFastCapsule(fast: shown.fast, choose: chooseFast).layoutValue(key: ConfigGive.self, value: [.secondary])
            }
            trailing
        }
        .frame(maxWidth: .infinity, alignment: alignment)
        #if os(macOS)
        .onChange(of: opening.wrappedValue) { _, pick in
            guard let pick else { return }
            opening.wrappedValue = nil
            open(pick)
        }
        .task {
            guard DebugHooks.preset.modelMenu, (try? await Task.sleep(for: .seconds(1.5))) != nil else { return }
            open(.model)
        }
        #endif
    }

    private var modelCapsule: some View {
        #if os(macOS)
        PiModelCapsule(models: models, current: shown.model, unnamed: unnamed, pending: shown.pending,
                       quotas: services.accountQuotas.items) { open(.model) }
            .popUpAnchor(anchors[.model])
        #else
        PiModelCapsule(models: models, current: shown.model, unnamed: unnamed, pending: shown.pending,
                       quotas: services.accountQuotas.items)
        #endif
    }
}

/// 工具排：胶囊按内容宽从左排成一行，竖直居中，两端都只有一行、永不折行，整排不超出给的宽（超出的话输入框跟着撑宽、伸出屏幕两边）。
/// 放不下时按 `Give` 的次序一步步让，够了就停，每一步把标了它的胶囊换成下一档短写法（胶囊里的 `ViewThatFits`，按"比现在窄一点"去量）：
/// 1. `wording`：思考强度去掉"思考"二字（`PiThinkingDial`）；
/// 2. `spacing`：胶囊之间收紧；
/// 3. `context`："上下文"三个字收成圆环（`PiContextGauge`）；
/// 4. `agent`：Agent 胶囊只留产品标志（`PiAgentCapsule`）；
/// 5. `secondary`：次要的再收一档——思考强度只剩竖格、上下文只剩圆环（百分比留在读屏与点开的气泡里）、加速只写"加速"（开着靠选中底）；
/// 6. `model`：剩下的宽都给模型，放不下全名就只留标志（没有标志的模型名字截断）；完整名称悬停、读屏、菜单里看。
/// 先收字、留标志与操作；不把胶囊收进"⋯"：排版定不了菜单里该有哪几项（`Layout` 不能藏起子视图，藏不掉的照样被读屏读到、点到），一律收短、留在原地。
/// 六步收完仍放不下（最大的辅助字号）就伸出输入框的右边、被裁掉，不折行、不撑宽输入框。
private struct ConfigRow: Layout {
    enum Give: CaseIterable { case wording, spacing, context, agent, secondary, model }

    private static let spacing: CGFloat = 6
    private static let tightSpacing: CGFloat = 2

    private struct Arrangement {
        var widths: [CGFloat]
        var spacing: CGFloat
        var width: CGFloat { widths.reduce(0, +) + spacing * CGFloat(max(widths.count - 1, 0)) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let row = arrange(in: proposal.width, subviews)
        // 收完仍放不下时只报给的宽：多出的伸出去被输入框裁掉，输入框不跟着撑宽
        return CGSize(width: min(row.width, proposal.width ?? row.width), height: height(row, subviews))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let row = arrange(in: proposal.width, subviews)
        let height = height(row, subviews)
        var x = bounds.minX
        for index in subviews.indices {
            subviews[index].place(at: CGPoint(x: x, y: bounds.minY + height / 2), anchor: .leading, proposal: ProposedViewSize(width: row.widths[index], height: height))
            x += row.widths[index] + row.spacing
        }
    }

    private func height(_ row: Arrangement, _ subviews: Subviews) -> CGFloat {
        subviews.indices.map { subviews[$0].sizeThatFits(ProposedViewSize(width: row.widths[$0], height: nil)).height }.max() ?? 0
    }

    private func arrange(in available: CGFloat?, _ subviews: Subviews) -> Arrangement {
        var row = Arrangement(widths: subviews.map { $0.sizeThatFits(.unspecified).width }, spacing: Self.spacing)
        guard let available else { return row }
        for give in Give.allCases where row.width > available {
            switch give {
            case .spacing:
                row.spacing = Self.tightSpacing
            case .model:
                for index in subviews.indices where subviews[index][ConfigGive.self].contains(give) {
                    row.widths[index] = width(of: subviews[index], in: max(0, available - row.width + row.widths[index]))
                }
            case .wording, .context, .agent, .secondary:
                for index in subviews.indices where subviews[index][ConfigGive.self].contains(give) {
                    row.widths[index] = width(of: subviews[index], in: max(0, row.widths[index] - 1))
                }
            }
        }
        return row
    }

    /// 给 `room` 宽时实际占的宽：截断后的字可能比给的窄，收成的短写法可能比给的宽。
    private func width(of subview: LayoutSubview, in room: CGFloat) -> CGFloat {
        subview.sizeThatFits(ProposedViewSize(width: room, height: nil)).width
    }
}

/// 工具排里这一枚在哪几步让（`ConfigRow.Give`）；没标的按内容宽不让。
nonisolated private struct ConfigGive: LayoutValueKey {
    static let defaultValue: Set<ConfigRow.Give> = []
}


/// 会话页回复框（与手机上交给 Agent 的输入框）里的模型与思考强度：可选的是会话上报的模型（它的目录记录），按提供方分组（`PiModelLabel.groups`）；
/// 换了写一条配置请求给会话所在的 Mac，显示值由会话记录与配置请求推出（`SessionDigest.config`：换了之后立即显示新值、呼吸到送达，没换成回到原值）。
/// 思考强度的档是当前模型支持的；右边是上下文用量。已结束的会话也能换（Mac 在后台唤醒它再换），放不放由调用方决定。
struct SessionConfigControls: View {
    let session: PiSessionState
    /// 可以换成的模型（`AgentCatalog.models`）。
    let models: [PiModelOption]
    let shown: PiConfigShown
    var opening: Binding<PiConfigPick?> = .constant(nil)
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    var body: some View {
        PiConfigControls(models: menu, shown: shown, levels: shown.model?.thinkingLevels ?? [], opening: opening, chooseThinking: {
            configure(PiConfig(thinking: $0))
        }, chooseFast: {
            configure(PiConfig(fast: $0))
        }) {
            if let meter = shown.context.flatMap(PiContextMeter.init) {
                PiContextGauge(session: session, meter: meter).layoutValue(key: ConfigGive.self, value: [.context, .secondary])
            }
        }
    }

    private var menu: PiModelMenu { .session(session, models: models, current: shown.model?.key, in: workspace) }

    private func configure(_ config: PiConfig) {
        workspace.attempt { _ = try await services.configure(config, for: session) }
    }
}

extension EnvironmentValues {
    /// 宽屏的回复框（两端的工具排都只有一行，`ConfigRow`）：思考强度的竖格画细一点。
    @Entry var singleLineConfig = false
}
