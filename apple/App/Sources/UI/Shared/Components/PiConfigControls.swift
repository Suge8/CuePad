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
            ChoiceMenu.Choice(title: kind.name, image: .brand(kind.mark), checked: kind == current) { choose(kind) }
        })]
    }
}


/// 模型菜单的一组：一家提供方与它能选的模型（组名是提供方的名字，这家有订阅额度时带用量，`PiModelLabel.title`，到了重置时刻随即更新）；
/// 选了做什么由调用方给。
struct PiModelGroup: Identifiable {
    let id: String
    let provider: PiProvider
    let items: [Item]

    /// 一项：一个模型。名字与标志都按模型定（`BrandMark.model`），这里一处；不指定模型时用的那项（新会话与 Cue）在名字下注"默认"。
    struct Item: Identifiable {
        let id: String
        let model: PiModelOption
        var isDefault = false
        let checked: Bool
        let choose: () -> Void

        var name: String { model.displayName }
        var note: String? { isDefault ? "默认" : nil }
        var mark: BrandMark? { BrandMark.model(model) }
    }
}

extension [PiModelGroup] {
    /// 模型菜单的内容，两端同一份：组名写提供方与它的额度用量（`PiModelLabel.title`，到了 `now` 按已重置算）。
    func menu(quotas: [AccountQuota], at now: Date) -> [ChoiceMenu.Section] {
        map { group in
            ChoiceMenu.Section(
                title: PiModelLabel.title(group.provider, quotas: quotas, at: now), image: group.provider.mark.map(ChoiceMenu.Glyph.brand),
                choices: group.items.map { item in
                    ChoiceMenu.Choice(
                        title: item.name, subtitle: item.note, image: item.mark.map(ChoiceMenu.Glyph.brand), checked: item.checked, choose: item.choose)
                })
        }
    }
}

extension PiModelOption {
    /// 有显示名用显示名，没有用 id。
    var displayName: String { name.isEmpty ? key.id : name }
}


/// 输入框工具排里的模型与思考强度（会话页回复框 `SessionConfigControls`；新会话与 Cue（`init(choice:)`）在最左再放一枚 Agent 胶囊 `PiAgentCapsule`）：模型胶囊（模型的标志 + 模型短名；
/// 有订阅额度的提供方，标志外一圈细环是卡着的那个窗口还剩多少。点开是分好组的菜单，当前打勾），右边思考强度胶囊（"思考"的标 + 一组竖格：格数是可选的档位，一格比一格高，
/// 当前档以下填满，关着时格全空、一道斜线；点在哪格或横着拖就调到哪档，每过一档轻触一下；按下就在上方浮出档位名，
/// 松手后停一会儿再淡出，点"思考"的标只看现在是哪档；最高档填色有一道流光），再往右是调用方给的（会话页的上下文用量）。
/// 只管显示与选择：可选什么、当前值、送达中（填色轻轻呼吸）、选了之后做什么都由调用方给；没换成的原因由调用方写在输入框头部。减弱动态效果时没有流光与呼吸。
struct PiConfigControls<Trailing: View>: View {
    /// 最左的 Agent 胶囊；会话的 Agent 换不了，不给。
    var agent: PiAgentPick?
    let groups: [PiModelGroup]
    let shown: PiConfigShown
    /// 胶囊上没有当前模型时写的。
    let unnamed: String
    /// 思考强度可选的档；空时不放思考强度。
    let levels: [PiThinkingLevel]
    let chooseThinking: (PiThinkingLevel) -> Void
    /// 键盘请弹出的菜单（只有 Mac 有这个入口）：弹出后清掉。
    let opening: Binding<PiConfigPick?>
    let trailing: Trailing
    @Environment(AppServices.self) var services
    /// 这一排拿到的宽度：模型胶囊最宽是它的一半（`PiModelLabel.capsuleWidth`）。
    @State private var available: CGFloat = 0
    #if os(macOS)
    /// 键盘弹出的菜单贴着哪枚胶囊。
    @State var anchors = [PiConfigPick.model: PopUpAnchor(), .thinking: PopUpAnchor()]
    #endif

    init(
        agent: PiAgentPick? = nil, groups: [PiModelGroup], shown: PiConfigShown, unnamed: String = "模型", levels: [PiThinkingLevel],
        opening: Binding<PiConfigPick?> = .constant(nil), chooseThinking: @escaping (PiThinkingLevel) -> Void,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.agent = agent
        self.groups = groups
        self.shown = shown
        self.unnamed = unnamed
        self.levels = levels
        self.opening = opening
        self.chooseThinking = chooseThinking
        self.trailing = trailing()
    }

    var body: some View {
        // 放得下时思考强度写"思考 中"，窄处（手机）只写档名"中"：三枚胶囊都不截断
        ViewThatFits(in: .horizontal) {
            row(wordy: true)
            row(wordy: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
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

    private func row(wordy: Bool) -> some View {
        HStack(spacing: 6) {
            if let agent { PiAgentCapsule(pick: agent) }
            modelCapsule
            if let meter = PiThinkingMeter(levels: levels, current: shown.thinking) {
                PiThinkingDial(meter: meter, pending: shown.pending, wordy: wordy, choose: chooseThinking)
                    #if os(macOS)
                    .popUpAnchor(anchors[.thinking])
                    #endif
            }
            trailing
        }
        .fixedSize()
    }

    private var modelCapsule: some View {
        #if os(macOS)
        PiModelCapsule(groups: groups, current: shown.model, unnamed: unnamed, pending: shown.pending,
                       maxWidth: PiModelLabel.capsuleWidth(available: available), quotas: services.accountQuotas.items) { open(.model) }
            .popUpAnchor(anchors[.model])
        #else
        PiModelCapsule(groups: groups, current: shown.model, unnamed: unnamed, pending: shown.pending,
                       maxWidth: PiModelLabel.capsuleWidth(available: available), quotas: services.accountQuotas.items)
        #endif
    }
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
        PiConfigControls(groups: groups, shown: shown, levels: shown.model?.thinkingLevels ?? [], opening: opening) {
            configure(PiConfig(thinking: $0))
        } trailing: {
            if let meter = shown.context.flatMap(PiContextMeter.init) { PiContextGauge(session: session, meter: meter) }
        }
    }

    private var groups: [PiModelGroup] {
        PiModelLabel.groups(models).map { group in
            PiModelGroup(id: group.provider.id, provider: group.provider, items: group.models.map { model in
                PiModelGroup.Item(id: "\(model.key.provider)/\(model.key.id)", model: model, checked: shown.model?.key == model.key) {
                    configure(PiConfig(model: model.key))
                }
            })
        }
    }

    private func configure(_ config: PiConfig) {
        workspace.attempt { _ = try await services.configure(config, for: session) }
    }
}
