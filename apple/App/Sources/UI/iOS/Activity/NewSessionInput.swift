#if os(iOS)
import CueStore
import SwiftUI

/// 新会话：一个浮在键盘上方的输入框，写的就是给 Pi 的第一句话；头部落点胶囊选在哪开（只列项目，默认 Agent 页正筛着的项目，没筛时是最近活跃的；项目绑在几台 Mac 上时写上 Mac 名）。
/// 工具排与 Mac 的新会话表单、Cue 同一排（`PiConfigControls.init(choice:)`）：Agent 只列那台 Mac 上能用的（`MacAgents`），默认上次选的（`MacAgents.preferred`，选了就记作下次的默认）；
/// 模型与思考强度默认跟着这家的默认，换了 Agent 或 Mac 回到默认。一家都不能用时输入框上方写那台为什么（`whyNone`）、开不了。
/// 发送钮就是开始：Mac 开好、带着这次标识的会话同步过来时自动收起并进入它（输入框关了就不进，`SessionLaunching` 照样等）；等待时仍可编辑或关闭；
/// 明确失败可安全重试，未知或查不到结果时再开须确认重复风险。
/// 新会话的目录只由项目绑定的文件夹推出；还没绑的项目也直接开：发给 Cue 运行的那台 Mac（没启用 Cue 时按名字排第一台，`CueStore.workMac`），
/// 它开工时建好工作区并绑定。
struct NewSessionInput: View {
    let start: SessionStart
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var choice: ProjectFolders.LaunchPlace.ID?
    @State private var draft = ComposerDraft()
    /// 由哪台 Mac 开（`LaunchPlace.host`）、那台上能用的几家；还没读到为 nil。
    @State private var agents: MacAgents?
    /// 这次指定的模型与思考强度（nil 是这家的默认）。
    @State private var model: PiModelKey?
    @State private var thinking: PiThinkingLevel?
    @State private var fast = false
    @FocusState private var focused: Bool

    /// 只列项目，按所有项目选择器的同一个顺序（`ProjectCatalog.projects`，最近活跃的在前）。
    private var places: [ProjectFolders.LaunchPlace] {
        ProjectFolders.launchPlaces(
            projects: workspace.catalog?.projects ?? [], bindings: workspace.catalog?.bindings ?? [], host: nil, workMac: workspace.catalog?.workMac?.hostID)
    }
    private var chosen: ProjectFolders.LaunchPlace? {
        let places = places
        return places.first { $0.id == choice } ?? start.place(among: places)
    }
    private var launching: SessionLaunching { workspace.sessionLaunching(start.launchKey) }
    private var phase: LaunchProgress.Phase { launching.phase(at: services.speech) }
    private var agent: AgentKind? { agents?.preferred(services.settings.lastAgent) }
    private var brain: AgentModelChoice? {
        guard chosen?.host != nil, let agents, let agent else { return nil }
        return AgentModelChoice(agents: agents.agents, agent: agent, model: model, thinking: thinking, fast: fast)
    }
    private var canStart: Bool { chosen?.host != nil && agent != nil && launching.canSubmit(at: services.speech) }

    var body: some View {
        Composer(
            draft: $draft, prompt: "第一句话（可不填）", label: "新会话的第一句话", focus: $focused,
            cardsFrom: chosen?.project.id, submitsEmpty: true,
            tooled: brain != nil,
            header: { header.padding(.horizontal, Spacing.group).padding(.top, Spacing.item) },
            tools: {
                if let brain {
                    PiConfigControls(choice: brain) { agent in
                        services.settings.lastAgent = agent
                        model = nil
                    } chooseModel: { model = $0 } chooseThinking: { thinking = $0 } chooseFast: { fast = $0 }
                    .disabled(launching.sending)
                }
            },
            send: {
                Button(action: launch) { SendGlyph(canStart ? .ready : .idle) }
                    .buttonStyle(PressStyle(.button)).disabled(!canStart).accessibilityLabel("开始")
            })
        .composerNotice(status != nil) { if let status { statusLine(status).font(Typography.caption) } }
        .confirmsLaunchAgain(launching)
        .onAppear {
            workspace.resume(start, opened: workspace.entering(start))
            if let seed = start.draft, draft.isEmpty(accepting: [.files, .cards]) { draft = seed }
            focused = true
        }
        .observing(services.store, id: chosen?.host, into: $agents, onError: workspace.fail) {
            [host = chosen?.host] store in
            guard let host else { return MacAgents(hostID: "", agents: [], modifiedAt: .distantPast) }
            return try store.macAgents(on: host)
        }
        // 换了 Mac：模型清单是另一份，回到默认
        .onChange(of: chosen?.host) { model = nil }
    }

    /// 头部：落点胶囊；进度或原因叠在输入框上方（`status`）。Agent 与模型在工具排里。
    private var header: some View {
        HStack(spacing: Spacing.item) {
            MenuButton(sections: [ChoiceMenu.Section(choices: places.map { place in
                ChoiceMenu.Choice(
                    title: .verbatim(Dotted(place.project.shownName, place.detail).visible),
                    checked: place.id == chosen?.id) { choice = place.id }
            })], accessibilityLabel: chosen.map { "在哪开：\($0.project.shownName)" } ?? "在哪开：没选") {
                DestinationChip(title: Text(Dotted(String(localized: "新会话"), chosen?.project.shownName ?? String(localized: "选在哪开")))) {
                    if let project = chosen?.project { ProjectGlyph(project: project, size: 13) }
                }
            }
            .disabled(launching.sending)
            Spacer(minLength: 0)
        }
    }

    /// 输入框上方叠着的那一行（`composerNotice`）：发出后的进度，上一次没能打开的原因，或开不了的原因；都没有为 nil。
    private enum Status {
        case noMac, phase(LaunchProgress.Phase), noAgents(MacAgents)
    }

    private var status: Status? {
        if chosen != nil, chosen?.host == nil { return .noMac }
        if phase != .idle { return .phase(phase) }
        // 那台一家都不能用时先说它：同步通了也开不了
        if let agents, agents.agents.isEmpty { return .noAgents(agents) }
        return nil
    }

    @ViewBuilder private func statusLine(_ status: Status) -> some View {
        switch status {
        case .noMac: MacInputNotice(noMac: true)
        case .noAgents(let agents): Text("\(agents.shownName)：\(agents.whyNone)").foregroundStyle(palette.ink3)
        case .phase(.failed(let failure)): Text(failure.text).foregroundStyle(palette.failure)
        case .phase(.unconfirmed(let reason)): Text(verbatim: reason).foregroundStyle(palette.ink3)
        case .phase(.missing): Text("上一次开会话的结果已经查不到了").foregroundStyle(palette.ink3)
        case .phase(.sending(let transit)):
            HStack(spacing: Spacing.glyph) { Spinner(.mini); Text(transit.label) }.font(Typography.meta.weight(.medium)).foregroundStyle(palette.ink2)
        case .phase: Text("Mac 正在开 Agent 会话…").foregroundStyle(palette.ink3)
        }
    }

    private func launch() {
        workspace.submitSession(start, in: chosen, draft: draft, choice: brain, opened: workspace.entering(start))
    }
}
#endif
