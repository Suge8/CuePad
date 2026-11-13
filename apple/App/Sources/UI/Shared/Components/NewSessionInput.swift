import CueStore
import SwiftUI

/// 开新会话只有这一个输入框（两端同一份）：看板的"＋"、会话列表空着时那一颗、Mac 菜单，以及手机把任务交给新会话时。
/// 手机浮在键盘上（`FloatingInput`），Mac 浮在窗口中间的遮罩上（`NewSessionPanel`，不套浮层的纸）。
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
    private var brain: AgentModelChoice? { agents.flatMap { services.settings.launchChoice(on: $0, in: chosen?.project.id) } }
    private var canStart: Bool {
        chosen?.host != nil && brain != nil && launching.canSubmit(at: services.speech) && !launching.inFlight(at: services.speech)
    }

    var body: some View {
        composer.composerNotice(status != nil) { if let status { LaunchStatusLine(status: status) } }
            #if os(macOS)
            .frame(width: 480)
            #endif
    }

    private var composer: some View {
        Composer(
            draft: $draft, prompt: nil, label: "新会话的第一句话", focus: $focused,
            cardsFrom: chosen?.project.id,
            tooled: brain != nil, shortcuts: [.send: launch],
            header: { header.padding(.horizontal, Spacing.group).padding(.top, Spacing.item) },
            tools: { if let agents { LaunchControls(mac: agents, project: chosen?.project.id) } },
            send: {
                Button(action: launch) { SendGlyph(canStart ? .ready : .idle) }
                    .buttonStyle(PressStyle(.button)).disabled(!canStart).accessibilityLabel("开始")
            })
        // 请求在路上时整个停用：这时改的字、换的去处都进不了已发出的那一次，认领到了输入框一收就丢了
        .disabled(launching.inFlight(at: services.speech))
        .confirmsLaunchAgain(launching)
        .onAppear {
            workspace.resume(start.launchKey, opened: Workspace.entering(start))
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
            Spacer(minLength: 0)
        }
    }

    private var status: LaunchStatus? {
        LaunchStatus(noMac: chosen != nil && chosen?.host == nil, phase: phase, agents: agents)
    }

    private func launch() {
        workspace.submitSession(start, in: chosen, draft: draft, choice: brain, opened: Workspace.entering(start))
    }
}

/// 开新会话的输入框上方那一行：开不了的原因，或发出后的进度与结果。新会话的输入框与手机交给新会话的输入框同一份。
enum LaunchStatus {
    case noMac, phase(LaunchProgress.Phase), noAgents(MacAgents)

    init?(noMac: Bool, phase: LaunchProgress.Phase, agents: MacAgents?) {
        if noMac { self = .noMac } else if phase != .idle { self = .phase(phase) }
        // 那台一家都不能用：同步通了也开不了，所以要写原因
        else if let agents, agents.agents.isEmpty { self = .noAgents(agents) } else { return nil }
    }
}

struct LaunchStatusLine: View {
    let status: LaunchStatus
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
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
        .font(Typography.caption)
    }
}
