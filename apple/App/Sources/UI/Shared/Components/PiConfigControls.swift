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


/// 模型菜单，两端同一份：可选的模型按提供方分组（`PiModelLabel.groups`），组名写提供方与它的额度用量（`PiModelLabel.title`，到了 `now` 按已重置算）；
/// 每项的名字与标志按模型定（`BrandMark.model`），不指定模型时用的那项（`defaultModel`，新会话与 Cue）在名字下注"默认"，当前打勾。选了做什么由调用方给。
struct PiModelMenu {
    let models: [PiModelOption]
    var defaultModel: PiModelKey?
    let current: PiModelKey?
    let choose: (PiModelOption) -> Void

    func sections(quotas: [AccountQuota], at now: Date) -> [ChoiceMenu.Section] {
        PiModelLabel.groups(models).map { group in
            ChoiceMenu.Section(
                title: .verbatim(PiModelLabel.title(group.provider, quotas: quotas, at: now)), image: group.provider.mark.map(ChoiceMenu.Glyph.brand),
                choices: group.models.map { model in
                    ChoiceMenu.Choice(
                        title: .verbatim(model.displayName), subtitle: model.key == defaultModel ? "默认" : nil, image: BrandMark.model(model).map(ChoiceMenu.Glyph.brand),
                        checked: model.key == current) { choose(model) }
                })
        }
    }
}


/// 输入框工具排里的模型与思考强度（会话页回复框 `SessionConfigControls`；新会话与 Cue（`init(choice:)`）在最左再放一枚 Agent 胶囊 `PiAgentCapsule`）：模型胶囊（模型的标志 + 模型短名；
/// 有订阅额度的提供方，标志外一圈细环是卡着的那个窗口还剩多少。点开是分好组的菜单，当前打勾），右边思考强度胶囊（"思考"的标 + 一组竖格：格数是可选的档位，一格比一格高，
/// 当前档以下填满，关着时格全空、一道斜线；点在哪格或横着拖就调到哪档，每过一档轻触一下；按下就在上方浮出档位名，
/// 松手后停一会儿再淡出，点"思考"的标只看现在是哪档；最高档填色有一道流光），再往右是调用方给的（会话页的上下文用量）。
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
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.agent = agent
        self.models = models
        self.shown = shown
        self.unnamed = unnamed
        self.levels = levels
        self.opening = opening
        self.chooseThinking = chooseThinking
        self.trailing = trailing()
    }

    func aligned(_ alignment: Alignment) -> Self {
        var aligned = self
        aligned.alignment = alignment
        return aligned
    }

    var body: some View {
        ConfigRow {
            if let agent { PiAgentCapsule(pick: agent) }
            modelCapsule
            if let meter = PiThinkingMeter(levels: levels, current: shown.thinking) {
                PiThinkingDial(meter: meter, pending: shown.pending, choose: chooseThinking)
                    #if os(macOS)
                    .popUpAnchor(anchors[.thinking])
                    #endif
                    .layoutValue(key: ConfigGive.self, value: .wording)
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

/// 工具排：胶囊按内容宽从左排成一行，竖直居中，整排不超出给的宽（超出的话输入框跟着撑宽、伸出屏幕两边）。
/// 一行放不下时按 `Give` 的次序一步步让，够了就停；让完还放不下（字号大、模型名长）就折到下一行，胶囊都按内容宽、不截字：
/// 模型名是这一排要读的字，截成"…"就认不出用的是哪个模型。只有一枚自己就比整排宽时才截它。
private struct ConfigRow: Layout {
    /// 让的次序：先去掉思考强度前的"思考"二字（`PiThinkingDial`），再收紧间距，再把"上下文"收成圆环（`PiContextGauge`）。
    enum Give: CaseIterable { case wording, spacing, context }

    private static let spacing: CGFloat = 6
    private static let tightSpacing: CGFloat = 2

    private struct Arrangement {
        var widths: [CGFloat]
        var spacing: CGFloat
        /// 每行从第几枚起；一行时只有 0。
        var breaks = [0]
        var width: CGFloat { widths.reduce(0, +) + spacing * CGFloat(max(widths.count - 1, 0)) }

        func lines(_ count: Int) -> [Range<Int>] {
            zip(breaks, breaks.dropFirst() + [count]).map { $0..<$1 }
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let row = arrange(in: proposal.width, subviews)
        let lines = row.lines(subviews.count).map { line(row, $0, subviews) }
        return CGSize(width: lines.map(\.width).max() ?? 0, height: lines.map(\.height).reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let row = arrange(in: proposal.width, subviews)
        var y = bounds.minY
        for range in row.lines(subviews.count) {
            let height = line(row, range, subviews).height
            var x = bounds.minX
            for index in range {
                subviews[index].place(at: CGPoint(x: x, y: y + height / 2), anchor: .leading, proposal: ProposedViewSize(width: row.widths[index], height: height))
                x += row.widths[index] + row.spacing
            }
            y += height
        }
    }

    private func line(_ row: Arrangement, _ range: Range<Int>, _ subviews: Subviews) -> CGSize {
        let width = range.map { row.widths[$0] }.reduce(0, +) + row.spacing * CGFloat(max(range.count - 1, 0))
        let height = range.map { subviews[$0].sizeThatFits(ProposedViewSize(width: row.widths[$0], height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    private func arrange(in available: CGFloat?, _ subviews: Subviews) -> Arrangement {
        var row = Arrangement(widths: subviews.map { $0.sizeThatFits(.unspecified).width }, spacing: Self.spacing)
        guard let available else { return row }
        for give in Give.allCases where row.width > available {
            switch give {
            case .spacing:
                row.spacing = Self.tightSpacing
            case .wording, .context:
                for index in subviews.indices where subviews[index][ConfigGive.self] == give {
                    row.widths[index] = width(of: subviews[index], in: 0)
                }
            }
        }
        guard row.width > available else { return row }
        var x: CGFloat = 0
        for index in subviews.indices {
            if row.widths[index] > available { row.widths[index] = width(of: subviews[index], in: available) }
            if index > 0, x + row.spacing + row.widths[index] > available {
                row.breaks.append(index)
                x = row.widths[index]
            } else {
                x += (index > 0 ? row.spacing : 0) + row.widths[index]
            }
        }
        return row
    }

    /// 给 `room` 宽时实际占的宽：截断后的字可能比给的窄，收成的短写法可能比给的宽。
    private func width(of subview: LayoutSubview, in room: CGFloat) -> CGFloat {
        subview.sizeThatFits(ProposedViewSize(width: room, height: nil)).width
    }
}

/// 工具排里这一枚放不下时怎么让（`ConfigRow.Give`）；没标的按内容宽不让。
nonisolated private struct ConfigGive: LayoutValueKey {
    static let defaultValue: ConfigRow.Give? = nil
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
        PiConfigControls(models: menu, shown: shown, levels: shown.model?.thinkingLevels ?? [], opening: opening) {
            configure(PiConfig(thinking: $0))
        } trailing: {
            if let meter = shown.context.flatMap(PiContextMeter.init) {
                PiContextGauge(session: session, meter: meter).layoutValue(key: ConfigGive.self, value: .context)
            }
        }
    }

    private var menu: PiModelMenu {
        PiModelMenu(models: models, current: shown.model?.key) { configure(PiConfig(model: $0.key)) }
    }

    private func configure(_ config: PiConfig) {
        workspace.attempt { _ = try await services.configure(config, for: session) }
    }
}
