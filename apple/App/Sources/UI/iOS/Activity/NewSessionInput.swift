#if os(iOS)
import CueStore
import SwiftUI

/// 新会话：只有一个浮在键盘上方的输入框，写的就是给 Pi 的第一句话；头部一颗落点胶囊"新会话 · 项目名"，点开换在哪开
/// （只列项目，默认 Agent 页正筛着的项目，没筛时是最近活跃的；项目绑在几台 Mac 上时菜单里写上 Mac 名）。工具排里选用哪个 Agent、模型与思考强度
/// （`PiConfigControls.init(choice:)`，与 Mac 的新会话表单、Cue 同一排）：Agent 只列那台 Mac 上能用的（`MacAgents`），默认上次选的（`MacAgents.preferred`，选了就记作下次的默认）；
/// 模型与思考强度默认跟着这家的默认，换了 Agent 或 Mac 回到默认。一家都不能用时头部写那台为什么（`whyNone`）、开不了。发送钮就是开始：
/// 发出后头部写进度（送达中 → Mac 在开），Mac 开好、带着这次标识的会话同步过来时自动收起并进入它；没能打开时头部写原因，可以再发。
/// 新会话的目录只由项目绑定的文件夹推出；选中还没绑文件夹的项目时头部引导就地绑（弹候选，请 Mac 绑），绑好才能开。
/// 没有项目时不出这个输入框，先新建项目（`Navigation.startNewSession`）。
struct NewSessionInput: View {
    let start: Navigation.NewSession
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette
    @State private var choice: ProjectFolders.LaunchPlace.ID?
    @State private var draft = ComposerDraft()
    @State private var launched: SessionLaunch?
    @State private var progress: LaunchProgress?
    /// 选中的项目绑着的那台 Mac 上能用的几家；还没读到为 nil。
    @State private var agents: MacAgents?
    /// 这次指定的模型与思考强度（nil 是这家的默认）。
    @State private var model: PiModelKey?
    @State private var thinking: PiThinkingLevel?
    @State private var sending = false
    @FocusState private var focused: Bool

    /// 只列项目，按所有项目选择器的同一个顺序（`ProjectCatalog.projects`，最近活跃的在前）。
    private var places: [ProjectFolders.LaunchPlace] {
        ProjectFolders.launchPlaces(projects: workspace.catalog?.projects ?? [], bindings: workspace.catalog?.bindings ?? [], host: nil)
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
        guard chosen?.binding != nil, let agents, let agent else { return nil }
        return AgentModelChoice(agents: agents.agents, agent: agent, model: model, thinking: thinking)
    }
    private var canStart: Bool { chosen?.binding != nil && agent != nil && services.reachesPiHost && !inFlight }

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
        .observing(services.store, id: chosen?.binding?.hostID, into: $agents, onError: workspace.fail) {
            [host = chosen?.binding?.hostID] store in
            guard let host else { return MacAgents(hostID: "", agents: [], modifiedAt: .distantPast) }
            return try store.macAgents(on: host)
        }
        // 换了 Mac：模型清单是另一份，回到默认
        .onChange(of: chosen?.binding?.hostID) { model = nil }
        .onChange(of: progress?.claimed?.id) { _, session in
            guard let session else { return }
            navigation.newSession = nil
            navigation.openSession(session, store: services.store)
        }
    }

    /// 头部：落点胶囊；进度或原因在它下面单独一行（放在右边会挤成两行、和胶囊对不齐）。Agent 与模型在工具排里。
    private var header: some View {
        HStack(spacing: 8) {
            MenuButton(sections: [ChoiceMenu.Section(choices: places.map { place in
                ChoiceMenu.Choice(
                    title: Dotted(place.project.name, place.detail ?? (place.binding == nil ? "还没有文件夹" : nil)).visible,
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

    /// 发出后的进度，上一次没能打开的原因，送不到 Mac 的原因，或项目还没有文件夹时的引导。
    @ViewBuilder private var status: some View {
        if let place = chosen, place.binding == nil, phase == .idle {
            // 项目还没有文件夹：写明，同名文件夹一键绑，或自己选（请 Mac 绑，进度与没绑成的原因就在这里）
            VStack(alignment: .leading, spacing: 0) {
                Text("「\(place.project.name)」还没有文件夹").foregroundStyle(palette.ink3)
                ProjectFolderGuide(project: place.project, guide: workspace.folderGuide, style: .line)
            }
        } else {
            switch phase {
            case .failed(let failure): Text(failure.text(sync: services.syncStatus)).foregroundStyle(palette.failure)
            case .opening, .claimed: Text("Mac 正在开 Agent 会话…").foregroundStyle(palette.ink3)
            case .sending(let transit):
                HStack(spacing: 6) { Spinner(.mini); Text(transit.label) }.font(Typography.meta.weight(.medium)).foregroundStyle(palette.ink2)
            case .idle:
                // 那台一家都不能用时先说它：同步通了也开不了
                if let binding = chosen?.binding, let agents, agents.agents.isEmpty {
                    Text("\(binding.macName)：\(agents.whyNone)").foregroundStyle(palette.ink3)
                } else if !services.reachesPiHost {
                    SyncHint(status: services.syncStatus, consequence: "发不到 Mac")
                }
            }
        }
    }

    private func launch() {
        guard let place = chosen, let binding = place.binding, let agent, let brain, canStart else { return }
        let draft = draft
        sending = true
        workspace.attempt {
            defer { sending = false }
            launched = try await start.launch(
                in: place.project, binding: binding, draft: draft, agent: agent, model: brain.model, thinking: brain.shownThinking, services: services)
        }
    }
}
#endif
