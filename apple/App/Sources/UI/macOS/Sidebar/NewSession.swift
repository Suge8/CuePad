#if os(macOS)
import CueStore
import SwiftUI

/// 新会话的表单挂在进展页上（`ProgressPage`，⌥⌘N 与工具栏的"新会话"经 `Workspace.showsNewSession` 打开；窗口内浮层，同其他弹层）：
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
    @State private var prompt = ""
    @State private var stage = Stage.idle

    private enum Stage: Equatable {
        case idle
        case opening
        /// Pi 已启动，等它连上（连上后表单关掉、打开新会话）。
        case connecting
        case failed(String)
    }

    private static let width: CGFloat = 340
    private static let listHeight: CGFloat = 240

    var body: some View {
        let places = ProjectFolders.launchPlaces(
            projects: workspace.catalog?.projects ?? [], bindings: workspace.catalog?.bindings ?? [], host: workspace.localHost, workMac: nil)
        let place = places.first { $0.id == chosen } ?? places.first { $0.project.id == workspace.currentProject } ?? places.first
        let agent = agents?.preferred(services.settings.lastAgent)
        VStack(alignment: .leading, spacing: 12) {
            Text("新会话").font(Typography.bodyStrong).foregroundStyle(palette.ink)
            ScrollView {
                // 行的底向两边让出一截，留在滚动区里不被裁
                VStack(spacing: 2) { ForEach(places) { row($0, selected: $0.id == place?.id) } }.padding(.horizontal, RowMetrics.bleed)
            }
            .frame(maxHeight: Self.listHeight).fixedSize(horizontal: false, vertical: true)
            TextField(String(localized: "开场的话（可不填）"), text: $prompt, palette: palette, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(2...5)
                .onSubmit { if let place, let agents, let agent, stage != .opening { start(place, choice(agents, agent)) } }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .paper(cornerRadius: Radius.block)
                .accessibilityLabel("开场的话")
            if let agents, let agent {
                PiConfigControls(choice: choice(agents, agent)) {
                    services.settings.lastAgent = $0
                    model = nil
                } chooseModel: { model = $0 } chooseThinking: { thinking = $0 }
                .disabled(stage == .opening)
            }
            HStack(spacing: 8) {
                switch stage {
                case .idle:
                    if let agents, agents.agents.isEmpty {
                        Text(agents.whyNone).font(Typography.meta).foregroundStyle(palette.ink3).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("在后台开，不占终端").font(Typography.meta).foregroundStyle(palette.ink3)
                    }
                case .opening:
                    Spinner(.small)
                    Text("正在开…").font(Typography.meta).foregroundStyle(palette.ink3)
                case .connecting:
                    Spinner(.small)
                    Text("等 Agent 连上…").font(Typography.meta).foregroundStyle(palette.ink3)
                case .failed(let reason):
                    Text(reason).font(Typography.meta).foregroundStyle(palette.failure).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                // ↩ 开始（浮层开着时 ⌘ 组合键只交给主菜单，⌘↩ 到不了这里），换行用 ⌥↩
                Button("开始") { if let place, let agents, let agent { start(place, choice(agents, agent)) } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(place == nil || agent == nil || stage == .opening)
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: Self.width)
        .background(palette.desk)
    }

    private func row(_ place: ProjectFolders.LaunchPlace, selected: Bool) -> some View {
        Button { chosen = place.id } label: {
            HStack(spacing: 8) {
                ProjectGlyph(project: place.project, size: 13)
                Text(place.project.shownName).foregroundStyle(palette.ink).lineLimit(1)
                Spacer(minLength: 4)
                // 对勾一直占着位置、只随选中显隐：换选中时名字不跟着让位
                Image(.checked).foregroundStyle(palette.ink2).opacity(selected ? 1 : 0).accessibilityHidden(true)
            }
            .padding(.vertical, 5)
            .contentShape(.rect)
        }
        .buttonStyle(RowStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func choice(_ agents: MacAgents, _ agent: AgentKind) -> AgentModelChoice {
        AgentModelChoice(agents: agents.agents, agent: agent, model: model, thinking: thinking)
    }

    private func start(_ place: ProjectFolders.LaunchPlace, _ choice: AgentModelChoice) {
        guard let agent = choice.agent else { return }
        stage = .opening
        let words = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let id = try await workspace.startSession(
                    in: place.project.id, prompt: words.isEmpty ? nil : words, title: place.project.shownName, agent: agent,
                    model: choice.model, thinking: choice.shownThinking
                ) { stage = .connecting }
                stage = .idle
                opened(id)
            } catch {
                stage = .failed(error.localizedDescription)
            }
        }
    }
}
#endif
