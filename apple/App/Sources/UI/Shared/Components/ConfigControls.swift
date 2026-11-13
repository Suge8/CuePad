import CueStore
import SwiftUI


enum ConfigPick { case model, thinking }


struct AgentPick {
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


struct ModelMenu {
    let models: [ModelOption]
    var defaultModel: ModelKey?
    let current: ModelKey?
    let choose: (ModelOption) -> Void

    func sections(quotas: [AccountQuota], at now: Date) -> [ChoiceMenu.Section] {
        ModelLabel.groups(models).map { group in
            ChoiceMenu.Section(
                title: .verbatim(group.models.first?.account?.source != nil ? group.provider.name : group.models.first.map { ModelLabel.title($0, quotas: quotas, at: now) } ?? group.provider.name), image: group.provider.mark.map(ChoiceMenu.Glyph.brand),
                choices: group.models.map { model in
                    ChoiceMenu.Choice(
                        title: .verbatim(model.displayName), subtitle: model.account?.source != nil ? .verbatim(ModelLabel.title(model, quotas: quotas, at: now)) : model.key == defaultModel ? "默认" : nil, image: BrandMark.model(model).map(ChoiceMenu.Glyph.brand),
                        checked: model.key == current) { choose(model) }
                })
        }
    }
}


extension ModelMenu {
    static func session(_ session: SessionState, models: [ModelOption], current: ModelKey?, in workspace: Workspace) -> ModelMenu {
        ModelMenu(models: models, current: current) { model in
            workspace.attempt { _ = try await workspace.services.configure(SessionConfig(model: model.key), for: session) }
        }
    }
}


/// 只管显示与选择：可选什么、当前值、送达中（填色轻轻呼吸）、选了之后做什么都由调用方给；没换成的原因由 `MacInputNotice` 叠在输入框上方。
struct ConfigControls<Trailing: View>: View {
    var agent: AgentPick?
    let models: ModelMenu
    let shown: ConfigShown
    let unnamed: LocalizedStringResource
    let levels: [ThinkingLevel]
    let chooseThinking: (ThinkingLevel) -> Void
    let chooseFast: (Bool) -> Void
    /// 弹出后清掉。
    let opening: Binding<ConfigPick?>
    let trailing: Trailing
    var alignment = Alignment.leading
    @Environment(AppServices.self) var services
    #if os(macOS)
    @State var anchors = [ConfigPick.model: PopUpAnchor(), .thinking: PopUpAnchor()]
    #endif

    init(
        agent: AgentPick? = nil, models: ModelMenu, shown: ConfigShown, unnamed: LocalizedStringResource = "模型", levels: [ThinkingLevel],
        opening: Binding<ConfigPick?> = .constant(nil), chooseThinking: @escaping (ThinkingLevel) -> Void,
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

    /// 工具排的字号上限（同 Cue 面板的做法）：按最坏的一排定——最窄的 iPhone（375 宽）、英文，模型、"管理用量"、思考强度、加速、上下文全在，
    /// 收完六步（`ConfigRow`）仍一颗不少、不压发送钮的那一档，实测 xxLarge；再大一档 xxxLarge 时英文的上下文压到发送钮下面。
    /// 泛型类型里放不了静态存储属性。
    static var largestType: DynamicTypeSize { .xxLarge }

    func aligned(_ alignment: Alignment) -> Self {
        var aligned = self
        aligned.alignment = alignment
        return aligned
    }

    var body: some View {
        ConfigRow {
            if let agent { AgentCapsule(pick: agent).layoutValue(key: ConfigGive.self, value: [.agent]) }
            modelCapsule.layoutValue(key: ConfigGive.self, value: [.model])
            if let model = shown.model, let url = model.account?.usageURL(provider: model.key.provider) {
                Link(destination: url) {
                    ViewThatFits(in: .horizontal) {
                        Text("管理用量")
                        Text("用量")
                    }
                }
                .font(Typography.meta).buttonStyle(PressStyle())
                .accessibilityLabel("管理用量")
                .layoutValue(key: ConfigGive.self, value: [.secondary])
            }
            if let meter = ThinkingMeter(levels: levels, current: shown.thinking) {
                ThinkingDial(meter: meter, pending: shown.pending, choose: chooseThinking)
                    #if os(macOS)
                    .popUpAnchor(anchors[.thinking])
                    #endif
                    .layoutValue(key: ConfigGive.self, value: [.wording, .secondary])
            }
            if shown.model?.supportsFast == true {
                FastCapsule(fast: shown.fast, choose: chooseFast).layoutValue(key: ConfigGive.self, value: [.secondary])
            }
            trailing
        }
        // 字号到这一档为止（输入的正文与上下文气泡照常放大，气泡按窗口的字号画，`PanelHost.typeSize`）：再大最窄的手机上收完六步也放不下
        .dynamicTypeSize(...Self.largestType)
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
        ModelCapsule(models: models, current: shown.model, unnamed: unnamed, pending: shown.pending,
                       quotas: services.accountQuotas.items) { open(.model) }
            .popUpAnchor(anchors[.model])
        #else
        ModelCapsule(models: models, current: shown.model, unnamed: unnamed, pending: shown.pending,
                       quotas: services.accountQuotas.items)
        #endif
    }
}

/// 放不下时按 `Give` 的次序一步步让，够了就停，每一步把标了它的胶囊换成下一档短写法（胶囊里的 `ViewThatFits`，按"比现在窄一点"去量）。
/// 先收字、留标志与操作；不把胶囊收进"⋯"：排版定不了菜单里该有哪几项（`Layout` 不能藏起子视图，藏不掉的照样被读屏读到、点到），一律收短、留在原地。
/// 所有压缩档用尽仍放不下时才折行；新增的尾部动作不能伸到发送钮下面，也不裁掉操作。
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
        let frames = frames(row, in: proposal.width, subviews)
        return CGSize(width: min(row.width, proposal.width ?? row.width), height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let row = arrange(in: bounds.width, subviews)
        let frames = frames(row, in: bounds.width, subviews)
        for index in subviews.indices {
            let frame = frames[index]
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.midY), anchor: .leading,
                                 proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(_ row: Arrangement, in available: CGFloat?, _ subviews: Subviews) -> [CGRect] {
        let height = height(row, subviews)
        var x: CGFloat = 0, y: CGFloat = 0
        return row.widths.map { width in
            if x > 0, let available, x + width > available {
                x = 0
                y += height + Self.tightSpacing
            }
            let frame = CGRect(x: x, y: y, width: width, height: height)
            x += width + row.spacing
            return frame
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

    private func width(of subview: LayoutSubview, in room: CGFloat) -> CGFloat {
        subview.sizeThatFits(ProposedViewSize(width: room, height: nil)).width
    }
}

nonisolated private struct ConfigGive: LayoutValueKey {
    static let defaultValue: Set<ConfigRow.Give> = []
}


/// 已结束的会话也能换（Mac 在后台唤醒它再换），放不放由调用方决定。
struct SessionConfigControls: View {
    let session: SessionState
    let models: [ModelOption]
    let shown: ConfigShown
    var cold: ColdCache?
    var opening: Binding<ConfigPick?> = .constant(nil)
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    var body: some View {
        ConfigControls(models: menu, shown: shown, levels: shown.model?.thinkingLevels ?? [], opening: opening, chooseThinking: {
            configure(SessionConfig(thinking: $0))
        }, chooseFast: {
            configure(SessionConfig(fast: $0))
        }) {
            if let meter = shown.context.flatMap(ContextMeter.init) {
                ContextGauge(session: session, meter: meter).layoutValue(key: ConfigGive.self, value: [.context, .secondary])
            }
            if let cold { ColdNote(cold: cold).layoutValue(key: ConfigGive.self, value: [.wording]).transition(.opacity) }
        }
    }

    private var menu: ModelMenu { .session(session, models: models, current: shown.model?.key, in: workspace) }

    private func configure(_ config: SessionConfig) {
        workspace.attempt { _ = try await services.configure(config, for: session) }
    }
}

/// 缓存冷了、这一句要重读多少上下文：排在回复框的工具那一排里、挨着上下文的用量，放不下只剩"已冷"，整句在悬停里。
/// 不另浮一张条在对话上：那是这一句的代价，属于要发出它的回复框。
struct ColdCache: Equatable {
    let context: Int
    let estimated: Bool
}

private struct ColdNote: View {
    let cold: ColdCache
    @Environment(\.palette) private var palette

    var body: some View {
        let tokens = CueContext.tokens(cold.context)
        ViewThatFits(in: .horizontal) {
            (cold.estimated ? Text("缓存可能已冷，重读约 \(tokens)") : Text("缓存已冷，重读约 \(tokens)")).fixedSize()
            Text("已冷").fixedSize()
        }
        .font(Typography.caption).monospacedDigit().foregroundStyle(palette.ink3)
        .padding(.leading, Spacing.tight)
        .help(cold.estimated ? Text("缓存可能已冷，这一句可能重读约 \(tokens)") : Text("缓存已冷，这一句会重读约 \(tokens)"))
    }
}

extension EnvironmentValues {
    @Entry var singleLineConfig = false
}
