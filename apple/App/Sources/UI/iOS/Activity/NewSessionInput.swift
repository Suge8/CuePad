#if os(iOS)
import CueStore
import SwiftUI

struct NewSessionInput: View {
    let start: SessionStart
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var choice: ProjectFolders.LaunchPlace.ID?
    @State private var draft = ComposerDraft()
    @State private var agents: MacAgents?
    @State private var model: ModelKey?
    @State private var thinking: ThinkingLevel?
    @State private var fast = false
    @FocusState private var focused: Bool

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
                    ConfigControls(choice: brain) { agent in
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
            workspace.resume(start, opened: Workspace.entering(start))
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

    private enum Status {
        case noMac, phase(LaunchProgress.Phase), noAgents(MacAgents)
    }

    private var status: Status? {
        if chosen != nil, chosen?.host == nil { return .noMac }
        if phase != .idle { return .phase(phase) }
        // 那台一家都不能用：同步通了也开不了，所以要写原因
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
        workspace.submitSession(start, in: chosen, draft: draft, choice: brain, opened: Workspace.entering(start))
    }
}
#endif
