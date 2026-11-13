import CueStore
import SwiftUI

/// 开新会话只有这一个输入框（两端同一份）：看板的"＋"、会话列表空着时那一颗、Mac 菜单，以及手机把任务交给新会话时。
/// 手机浮在键盘上（`FloatingInput`），Mac 在窗口中间的浮层里（`NewSessionPanel`）。
struct NewSessionInput: View {
    let start: SessionStart
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var choice: ProjectFolders.LaunchPlace.ID?
    @State private var draft = ComposerDraft()
    @State private var agents: MacAgents?
    @FocusState private var focused: Bool

    private var chosen: ProjectFolders.LaunchPlace? {
        let places = workspace.launchPlaces
        return places.first { $0.id == choice } ?? start.place(among: places)
    }
    private var launching: SessionLaunching { workspace.sessionLaunching(start.launchKey) }
    private var phase: LaunchProgress.Phase { launching.phase(at: services.speech) }
    private var brain: AgentModelChoice? { agents.flatMap(services.settings.launchChoice) }
    private var canStart: Bool { chosen?.host != nil && brain != nil && launching.canSubmit(at: services.speech) }

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: Spacing.item) {
            composer
            // 浮层按内容裁：说明排在输入框下面，不浮在上沿之外
            if let status { statusLine(status).font(Typography.meta).padding(.horizontal, Spacing.group).transition(.opacity) }
        }
        .animation(Motion.fade, value: status != nil)
        .padding(Spacing.group)
        .frame(width: Self.width)
        #else
        composer.composerNotice(status != nil) { if let status { statusLine(status).font(Typography.caption) } }
        #endif
    }

    #if os(macOS)
    private static let width: CGFloat = 480
    #endif

    private var composer: some View {
        Composer(
            draft: $draft, prompt: "第一句话（可不填）", label: "新会话的第一句话", focus: $focused,
            cardsFrom: chosen?.project.id, submitsEmpty: true,
            tooled: brain != nil, shortcuts: [.send: launch],
            header: { header.padding(.horizontal, Spacing.group).padding(.top, Spacing.item) },
            tools: { if let agents { LaunchControls(mac: agents).disabled(launching.sending) } },
            send: {
                Button(action: launch) { SendGlyph(canStart ? .ready : .idle) }
                    .buttonStyle(PressStyle(.button)).disabled(!canStart).accessibilityLabel("开始")
            })
        .confirmsLaunchAgain(launching)
        .onAppear {
            workspace.resume(start, opened: Workspace.entering(start))
            if let seed = start.draft, draft.isEmpty(accepting: [.files, .cards]) { draft = seed }
            #if os(iOS)
            focused = true
            #endif
        }
        #if os(macOS)
        .task {
            // 浮层出现的那一帧文字区还没进窗口的响应链：下一帧再接键盘
            await NextFrame.wait()
            focused = true
        }
        #endif
        .observing(services.store, id: chosen?.host, into: $agents, onError: workspace.fail) {
            [host = chosen?.host] store in
            guard let host else { return MacAgents(hostID: "", agents: [], modifiedAt: .distantPast) }
            return try store.macAgents(on: host)
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.item) {
            MenuButton(sections: [ChoiceMenu.Section(choices: workspace.launchPlaces.map { place in
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
        case .phase:
            HStack(spacing: Spacing.glyph) { Spinner(.mini); Text("Mac 正在开 Agent 会话…") }.foregroundStyle(palette.ink3)
        }
    }

    private func launch() {
        workspace.submitSession(start, in: chosen, draft: draft, choice: brain, opened: Workspace.entering(start))
    }
}
