#if os(macOS)
import CueStore
import SwiftUI

/// 新会话的表单挂在主窗口上（`WindowPanels`，⌥⌘N 与看板推进中列头的 ＋ 经 `Workspace.newSession(in:)` 打开；窗口内浮层，同其他弹层）：
/// 开好后关掉表单、在内容区打开新会话的整页。这台 Mac 上一家 Agent 都不能用（`MacAgents`）时表单里写为什么（`whyNone`）。
struct NewSessionPanel: ViewModifier {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @State private var agents: MacAgents?

    func body(content: Content) -> some View {
        content
            .observing(services.store, into: $agents, onError: workspace.fail) { [host = services.hostID] in try $0.macAgents(on: host) }
            .panel(isPresented: Bindable(workspace).showsNewSession) {
                NewSessionForm(agents: agents) { id in
                    workspace.showsNewSession = false
                    workspace.show(.session(id))
                }
            }
    }
}

/// 新会话开在哪、用哪个 Agent 与模型：只列项目（项目目录的顺序）；目录只由项目绑定推出，没绑文件夹的项目开工时这台 Mac 建好工作区（`MacExecutor`）。
/// 开场的话下面一排选 Agent、模型与思考强度（`PiConfigControls.init(choice:)`，与手机的新会话、Cue 同一排）：Agent 只列这台 Mac 上能用的（`agents`，由 + 读来），
/// 默认上次选的（`MacAgents.preferred`，选了就记作下次的默认，同手机）；模型与思考强度默认跟着这家的默认，换了 Agent 回到默认。一家都不能用时写为什么（`whyNone`）、开不了。
struct NewSessionForm: View {
    /// 这台 Mac 上的 Agent；还没读到为 nil。
    let agents: MacAgents?
    let opened: (String) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var chosen: String?
    /// 这次指定的模型与思考强度（nil 是这家的默认）。
    @State private var model: PiModelKey?
    @State private var thinking: PiThinkingLevel?
    @State private var fast = false
    @State private var prompt = ""
    @State private var opening = SessionOpening()

    private static let width: CGFloat = 340
    private static let listHeight: CGFloat = 240

    var body: some View {
        let places = ProjectFolders.launchPlaces(
            projects: workspace.catalog?.projects ?? [], bindings: workspace.catalog?.bindings ?? [], host: workspace.localHost, workMac: nil)
        let place = places.first { $0.id == chosen } ?? places.first { $0.project.id == workspace.newSessionProject ?? workspace.currentProject } ?? places.first
        let agent = agents?.preferred(services.settings.lastAgent)
        VStack(alignment: .leading, spacing: Spacing.group) {
            Text("新会话").font(Typography.bodyStrong).foregroundStyle(palette.ink)
            ScrollView {
                // 预热与首次打开都只建可见行；行的底向两边让出一截，留在滚动区里不被裁。
                LazyVStack(spacing: Spacing.hair) { ForEach(places) { row($0, selected: $0.id == place?.id) } }.padding(.horizontal, RowMetrics.bleed)
            }
            .frame(maxHeight: Self.listHeight).fixedSize(horizontal: false, vertical: true)
            TextField(String(localized: "开场的话（可不填）"), text: $prompt, palette: palette, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(2...5)
                .onSubmit { if let place, let agents, let agent, !opening.launching { start(place, choice(agents, agent)) } }
                .padding(.horizontal, Spacing.item).padding(.vertical, Spacing.item)
                .paper(cornerRadius: Radius.block)
                .accessibilityLabel("开场的话")
            if let agents, let agent {
                PiConfigControls(choice: choice(agents, agent)) {
                    services.settings.lastAgent = $0
                    model = nil
                } chooseModel: { model = $0 } chooseThinking: { thinking = $0 } chooseFast: { fast = $0 }
                .disabled(opening.launching)
            }
            HStack(spacing: Spacing.item) {
                switch opening.stage {
                case .idle:
                    if let agents, agents.agents.isEmpty {
                        Text(agents.whyNone).font(Typography.meta).foregroundStyle(palette.ink3).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("在后台开，不占终端").font(Typography.meta).foregroundStyle(palette.ink3)
                    }
                case .launching(let progress): progressLine(progress)
                case .failed(let reason):
                    Text(reason).font(Typography.meta).foregroundStyle(palette.failure).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                // ↩ 开始（浮层开着时 ⌘ 组合键只交给主菜单，⌘↩ 到不了这里），换行用 ⌥↩
                Button("开始") { if let place, let agents, let agent { start(place, choice(agents, agent)) } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(place == nil || agent == nil || opening.launching)
            }
            .controlSize(.small)
        }
        .padding(Spacing.block)
        .frame(width: Self.width)
    }

    @ViewBuilder private func progressLine(_ progress: LaunchProgress?) -> some View {
        switch progress?.phase(at: services.speech) {
        case .unconfirmed(let reason):
            Text(verbatim: reason).font(Typography.meta).foregroundStyle(palette.ink3)
        default:
            Spinner(.small)
            Text(progress?.phase(at: services.speech) == .opening ? LocalizedStringKey("等 Agent 连上…") : LocalizedStringKey("正在开…"))
                .font(Typography.meta).foregroundStyle(palette.ink3)
        }
    }

    private func row(_ place: ProjectFolders.LaunchPlace, selected: Bool) -> some View {
        Button { chosen = place.id } label: {
            HStack(spacing: Spacing.item) {
                ProjectGlyph(project: place.project, size: 13)
                Text(place.project.shownName).foregroundStyle(palette.ink).lineLimit(1)
                Spacer(minLength: 4)
                // 对勾一直占着位置、只随选中显隐：换选中时名字不跟着让位
                Image(.checked).foregroundStyle(palette.ink2).opacity(selected ? 1 : 0).accessibilityHidden(true)
            }
            .padding(.vertical, Spacing.tight)
            .contentShape(.rect)
        }
        .buttonStyle(RowStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func choice(_ agents: MacAgents, _ agent: AgentKind) -> AgentModelChoice {
        AgentModelChoice(agents: agents.agents, agent: agent, model: model, thinking: thinking, fast: fast)
    }

    private func start(_ place: ProjectFolders.LaunchPlace, _ choice: AgentModelChoice) {
        workspace.submitSession(in: place, prompt: prompt, choice: choice, opening: opening, opened: opened)
    }
}
#endif
