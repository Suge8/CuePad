#if os(iOS)
import CueStore
import SwiftUI

/// 新会话：一个浮在键盘上方的输入框，写的就是给 Pi 的第一句话；头部落点胶囊选在哪开（只列项目，默认 Agent 页正筛着的项目，没筛时是最近活跃的；项目绑在几台 Mac 上时写上 Mac 名）。
/// 工具排与 Mac 的新会话表单、Cue 同一排（`PiConfigControls.init(choice:)`）：Agent 只列那台 Mac 上能用的（`MacAgents`），默认上次选的（`MacAgents.preferred`，选了就记作下次的默认）；
/// 模型与思考强度默认跟着这家的默认，换了 Agent 或 Mac 回到默认。一家都不能用时头部写那台为什么（`whyNone`）、开不了。
/// 发送钮就是开始：Mac 开好、带着这次标识的会话同步过来时自动收起并进入它；没能打开时头部写原因，可以再发。
/// 新会话的目录只由项目绑定的文件夹推出；还没绑的项目也直接开：发给 Cue 运行的那台 Mac（没启用 Cue 时按名字排第一台，`CueStore.workMac`），
/// 它开工时建好工作区并绑定。
struct NewSessionInput: View {
    /// 打开时带的（`Workspace.newSession`）：`project` 是先选中的项目（Agent 页筛着的）。
    struct Start: Identifiable {
        let id = UUID()
        var project: UUID?
        /// 已经发出的那一次：输入框打开时接着看它的进度（界面上的入口都不带，只有截图用的调试画面摆出发出后的样子）。
        var launched: SessionLaunch?
        /// 从"发给 Agent"选了新会话：任务的正文与补的话带过来作开场。
        var draft: ComposerDraft?
        /// 为哪件任务开的（发给 Agent 时定下）：开好后关联它。
        var card: UUID?
        /// 显示的目标名：为任务开的是它的标题（`CueStore.handOffPlan`，与会话名同一条规则）；nil 时以项目名称呼。
        var name: String?
        /// 默认由哪台 Mac 开（`CueStore.handOffPlan` 定下的）；nil 是按项目的第一处绑定。
        var host: String?

        /// 默认在哪开：先选中的项目（有 `host` 时是它在那台 Mac 上的绑定），没有就是第一处。
        func place(among places: [ProjectFolders.LaunchPlace]) -> ProjectFolders.LaunchPlace? {
            project.flatMap { project in
                let own = places.filter { $0.project.id == project }
                return own.first { host != nil && $0.host == host } ?? own.first
            } ?? places.first
        }

        /// 在 `host` 那台 Mac、项目的文件夹（没绑的那台先建工作区）用 `agent`（与 `model`、`thinking`，nil 是默认）开新会话，`draft` 作开场：
        /// 开好后关联 `card`（会话名按它定，`CueStore.requestLaunch`；没有就是带上的第一张）。
        func launch(
            in project: Project, on host: String, draft: ComposerDraft, agent: AgentKind, model: PiModelKey?, thinking: PiThinkingLevel?,
            services: AppServices
        ) async throws -> SessionLaunch {
            try await services.launchSession(
                in: project.id, prompt: try draft.stored(in: services.store.files).nonEmpty, title: name ?? project.name, on: host,
                card: card ?? draft.attachments.first?.card, agent: agent, model: model, thinking: thinking)
        }
    }

    let start: Start
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var choice: ProjectFolders.LaunchPlace.ID?
    @State private var draft = ComposerDraft()
    @State private var launched: SessionLaunch?
    @State private var progress: LaunchProgress?
    /// 由哪台 Mac 开（`LaunchPlace.host`）、那台上能用的几家；还没读到为 nil。
    @State private var agents: MacAgents?
    /// 这次指定的模型与思考强度（nil 是这家的默认）。
    @State private var model: PiModelKey?
    @State private var thinking: PiThinkingLevel?
    @State private var sending = false
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
    private var phase: LaunchProgress.Phase { progress?.phase(at: services.speech) ?? .idle }
    /// 发出且还没失败：输入框锁住，等它开好。
    private var inFlight: Bool {
        if case .failed = phase { return sending }
        return sending || launched != nil
    }
    private var agent: AgentKind? { agents?.preferred(services.settings.lastAgent) }
    private var brain: AgentModelChoice? {
        guard chosen?.host != nil, let agents, let agent else { return nil }
        return AgentModelChoice(agents: agents.agents, agent: agent, model: model, thinking: thinking)
    }
    private var canStart: Bool { chosen?.host != nil && agent != nil && services.reachesPiHost && !inFlight }

    var body: some View {
        Composer(
            draft: $draft, prompt: "第一句话（可不填）", label: "新会话的第一句话", focus: $focused,
            cardsFrom: chosen?.project.id, submitsEmpty: true,
            tooled: brain != nil,
            header: {
                header.padding(.horizontal, 12).padding(.top, 10)
                status.font(.caption).lineLimit(2).padding(.horizontal, 18).padding(.top, 8)
            },
            tools: {
                if let brain {
                    PiConfigControls(choice: brain) { agent in
                        services.settings.lastAgent = agent
                        model = nil
                    } chooseModel: { model = $0 } chooseThinking: { thinking = $0 }
                    .disabled(inFlight)
                }
            },
            send: {
                Button(action: launch) { SendGlyph(canStart ? .ready : .idle) }
                    .buttonStyle(PressStyle(.button)).disabled(!canStart).accessibilityLabel("开始")
            })
        .disabled(inFlight)
        // 浮在 `FloatingInput` 里（与发给 Agent 同一种）；发出后等它开好时不让收起
        .floatingInputLocked(inFlight)
        .onAppear {
            if launched == nil { launched = start.launched }
            if let seed = start.draft, draft.isEmpty(accepting: [.images, .cards]) { draft = seed }
            focused = true
        }
        .observing(services.store, id: launched, into: $progress, onError: workspace.fail) {
            [launched] store in
            guard let launched else { return LaunchProgress() }
            return try launched.progress(from: store)
        }
        .observing(services.store, id: chosen?.host, into: $agents, onError: workspace.fail) {
            [host = chosen?.host] store in
            guard let host else { return MacAgents(hostID: "", agents: [], modifiedAt: .distantPast) }
            return try store.macAgents(on: host)
        }
        // 换了 Mac：模型清单是另一份，回到默认
        .onChange(of: chosen?.host) { model = nil }
        .onChange(of: progress?.claimed?.id) { _, session in
            guard let session else { return }
            workspace.newSession = nil
            workspace.openSession(session)
        }
    }

    /// 头部：落点胶囊；进度或原因在它下面单独一行（放在右边会挤成两行、和胶囊对不齐）。Agent 与模型在工具排里。
    private var header: some View {
        HStack(spacing: 8) {
            MenuButton(sections: [ChoiceMenu.Section(choices: places.map { place in
                ChoiceMenu.Choice(
                    title: Dotted(place.project.name, place.detail).visible,
                    checked: place.id == chosen?.id) { choice = place.id }
            })], accessibilityLabel: "在哪开：\(chosen?.project.name ?? "没选")") {
                DestinationChip(title: Text(Dotted("新会话", chosen?.project.name ?? "选在哪开"))) {
                    if let project = chosen?.project { ProjectGlyph(project: project, size: 13) }
                }
            }
            .disabled(inFlight)
            Spacer(minLength: 0)
        }
    }

    /// 发出后的进度，上一次没能打开的原因，或送不到 Mac 的原因。
    @ViewBuilder private var status: some View {
        if chosen != nil, chosen?.host == nil {
            Text("还没有 Mac 打开过 CuePad：先在 Mac 上打开它").foregroundStyle(palette.ink3)
        } else {
            switch phase {
            case .failed(let failure): Text(failure.text(sync: services.syncStatus)).foregroundStyle(palette.failure)
            case .opening, .claimed: Text("Mac 正在开 Agent 会话…").foregroundStyle(palette.ink3)
            case .sending(let transit):
                HStack(spacing: 6) { Spinner(.mini); Text(transit.label) }.font(Typography.meta.weight(.medium)).foregroundStyle(palette.ink2)
            case .idle:
                // 那台一家都不能用时先说它：同步通了也开不了
                if let agents, agents.agents.isEmpty {
                    Text("\(agents.shownName)：\(agents.whyNone)").foregroundStyle(palette.ink3)
                } else if !services.reachesPiHost {
                    SyncHint(status: services.syncStatus, consequence: "发不到 Mac")
                }
            }
        }
    }

    private func launch() {
        guard let place = chosen, let host = place.host, let agent, let brain, canStart else { return }
        let draft = draft
        sending = true
        workspace.attempt {
            defer { sending = false }
            launched = try await start.launch(
                in: place.project, on: host, draft: draft, agent: agent, model: brain.model, thinking: brain.shownThinking, services: services)
        }
    }
}
#endif
