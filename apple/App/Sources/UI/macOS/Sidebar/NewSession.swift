#if os(macOS)
import CueStore
import SwiftUI

struct NewSessionPanel: ViewModifier {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @State private var agents: MacAgents?

    func body(content: Content) -> some View {
        content
            .observing(services.store, into: $agents, onError: workspace.fail) { [host = services.hostID] in try $0.macAgents(on: host) }
            .panel(isPresented: Bindable(workspace).showsNewSession) {
                NewSessionForm(agents: agents, opened: workspace.showLaunched)
            }
            .confirmsLaunchAgain(workspace.sessionLaunching(.form))
    }
}

/// 发出后到有结果前锁住（手机的输入框不锁）；再开按上一次的结果直接重试或先确认。
struct NewSessionForm: View {
    let agents: MacAgents?
    let opened: (String) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var chosen: String?
    @State private var model: PiModelKey?
    @State private var thinking: PiThinkingLevel?
    @State private var fast = false
    @State private var prompt = ""

    private static let width: CGFloat = 340
    private static let listHeight: CGFloat = 240

    var body: some View {
        let places = ProjectFolders.launchPlaces(
            projects: workspace.catalog?.projects ?? [], bindings: workspace.catalog?.bindings ?? [], host: workspace.localHost, workMac: nil)
        let place = places.first { $0.id == chosen } ?? places.first { $0.project.id == workspace.newSessionProject ?? workspace.currentProject } ?? places.first
        let agent = agents?.preferred(services.settings.lastAgent)
        let launching = workspace.sessionLaunching(.form)
        let locked = launching.inFlight(at: services.speech)
        VStack(alignment: .leading, spacing: Spacing.group) {
            Text("新会话").font(Typography.bodyStrong).foregroundStyle(palette.ink)
            ScrollView {
                // 预热与首次打开都只建可见行；行的底向两边让出一截，留在滚动区里不被裁。
                LazyVStack(spacing: Spacing.hair) { ForEach(places) { row($0, selected: $0.id == place?.id) } }.padding(.horizontal, RowMetrics.bleed)
            }
            .frame(maxHeight: Self.listHeight).fixedSize(horizontal: false, vertical: true)
            TextField(String(localized: "开场的话（可不填）"), text: $prompt, palette: palette, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(2...5)
                .onSubmit { if let place, let agents, let agent { start(place, choice(agents, agent)) } }
                .padding(.horizontal, Spacing.item).padding(.vertical, Spacing.item)
                .paper(cornerRadius: Radius.block)
                .accessibilityLabel("开场的话")
            if let agents, let agent {
                PiConfigControls(choice: choice(agents, agent)) {
                    services.settings.lastAgent = $0
                    model = nil
                } chooseModel: { model = $0 } chooseThinking: { thinking = $0 } chooseFast: { fast = $0 }
            }
            HStack(spacing: Spacing.item) {
                if locked {
                    Spinner(.small)
                    Text(launching.phase(at: services.speech) == .opening ? LocalizedStringKey("等 Agent 连上…") : LocalizedStringKey("正在开…"))
                        .font(Typography.meta).foregroundStyle(palette.ink3)
                } else if let outcome = launching.outcome(at: services.speech) {
                    Text(verbatim: outcome.text).font(Typography.meta).foregroundStyle(outcome.failed ? palette.failure : palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let agents, agents.agents.isEmpty {
                    Text(agents.whyNone).font(Typography.meta).foregroundStyle(palette.ink3).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("在后台开，不占终端").font(Typography.meta).foregroundStyle(palette.ink3)
                }
                Spacer()
                // ↩ 开始（浮层开着时 ⌘ 组合键只交给主菜单，⌘↩ 到不了这里），换行用 ⌥↩
                Button("开始") { if let place, let agents, let agent { start(place, choice(agents, agent)) } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(place == nil || agent == nil)
            }
            .controlSize(.small)
        }
        .disabled(locked)
        .padding(Spacing.block)
        .frame(width: Self.width)
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
        workspace.submitSession(in: place, draft: ComposerDraft(text: prompt), choice: choice) { [opened] in
            opened($0.sessionID)
        }
    }
}
#endif
