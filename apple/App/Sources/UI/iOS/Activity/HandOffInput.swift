#if os(iOS)
import CueStore
import SwiftUI

struct HandOffInput: View {
    let outbox: Outbox
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var digest: SessionDigest?
    @State private var choice: UUID?
    /// 点了"新会话"：任务绑着会话也另开一个。
    @State private var fresh = false
    @State private var planned: Planned?
    @State private var launchAgents: MacAgents?
    @FocusState private var focused: Bool

    /// 还没有哪台 Mac 写下过自己时没有决定（`noMac`）：新用户的常态、不是出错，原因叠在输入框上方。
    nonisolated private struct Planned: Equatable, Sendable {
        var plan: HandOffPlan?
        var bound: SessionListItem?
        var fresh: HandOffPlan?
        var opening: String?
        var noMac = false
    }

    private var sessions: [SessionListItem] {
        let live = HandOffTargets.sessions(services.liveSessions.live, project: outbox.project, at: services.speech)
        guard let bound = planned?.bound, !live.contains(where: { $0.state.sessionID == bound.state.sessionID }) else { return live }
        return [bound] + live
    }
    private var chosen: SessionListItem? {
        guard !fresh else { return nil }
        let all = sessions
        if let choice { return all.first { $0.state.id == choice } }
        return planned?.bound.flatMap { bound in all.first { $0.state.sessionID == bound.state.sessionID } }
    }
    private var canSend: Bool { planned.map { !$0.noMac } == true }
    private var draft: ComposerDraft { workspace.handOffDraft }

    /// 草稿在 `Workspace.handOffDraft`：发出即收起，写库失败时放回草稿、重新浮起这个输入框。
    private var box: Binding<ComposerDraft> {
        let workspace = workspace, outbox = outbox
        return Binding(get: { workspace.handOffDraft }) { draft in
            workspace.handOffDraft = draft
            if workspace.outbox == nil, !draft.isEmpty(accepting: [.files, .cards]) { workspace.outbox = outbox }
        }
    }
    private var chosenLive: SessionState? {
        guard let chosen = chosen?.state else { return nil }
        return services.liveSessions.live.contains { $0.state.id == chosen.id } ? chosen : nil
    }
    private var chosenDigest: SessionDigest? {
        guard let digest, let id = chosenLive?.id, digest.session?.id == id else { return nil }
        return digest
    }
    private var config: ConfigShown? { chosenDigest?.config(at: services.speech) }
    private var catalog: AgentCatalog? { chosenDigest?.catalog }
    private var commands: [SlashCommand] { chosen?.state.usableCommands(in: catalog) ?? [] }

    private var tools: (session: SessionState, models: [ModelOption], config: ConfigShown)? {
        guard let session = chosen?.state, let config, let models = catalog?.models, !models.isEmpty else { return nil }
        return (session, models, config)
    }
    private var launchPlan: HandOffPlan? { chosen != nil ? nil : fresh ? planned?.fresh : planned?.plan }
    private var launchSpot: (project: UUID, host: String)? {
        guard case .launch(let project, let host) = launchPlan?.destination else { return nil }
        return (project, host)
    }
    private var launchHost: String? { launchSpot?.host }
    /// 交给新会话时的那一排：用哪家、哪个模型在这里就选，发出即开。
    private var launchTools: MacAgents? {
        launchAgents.flatMap { services.settings.launchChoice(on: $0, in: launchSpot?.project) == nil ? nil : $0 }
    }

    var body: some View {
        Composer(
            draft: box, prompt: "补一句（可不填）", label: "发给 Agent", focus: $focused,
            accepts: chosen == nil ? [.files, .cards] : .reply, cardsFrom: outbox.project, keeps: outbox.card, tooled: tools != nil || launchTools != nil,
            commands: commands,
            header: { header.padding(.horizontal, Spacing.group).padding(.top, Spacing.item) },
            tools: {
                if let tools {
                    SessionConfigControls(session: tools.session, models: tools.models, shown: tools.config)
                } else if let launchTools {
                    LaunchControls(mac: launchTools, project: launchSpot?.project)
                }
            },
            send: {
                Button(action: send) { SendGlyph(canSend ? .ready : .idle) }
                    .buttonStyle(PressStyle(.button)).disabled(!canSend)
                    .accessibilityLabel(chosen.map { String(localized: "交给 \($0.state.title)") } ?? String(localized: "开新会话交给它"))
            })
        .composerNotice(planned?.noMac == true || config?.failure != nil) {
            MacInputNotice(noMac: planned?.noMac == true, failure: config?.failure)
        }
        .onAppear { focused = true }
        .observing(services.store, id: outbox.card, into: $planned, onError: workspace.fail) { [card = outbox.card] store in
            guard let card else { return Planned() }
            let plan: HandOffPlan
            do {
                plan = try store.handOffPlan(card, host: nil)
            } catch CueStoreError.noMac {
                return Planned(noMac: true)
            }
            let opening = try store.opening(of: plan.leaf, true)
            guard case .session(let id, _, _) = plan.destination else { return Planned(plan: plan, fresh: plan, opening: opening) }
            return Planned(
                plan: plan, bound: try store.sessionItems(sessionIDs: [id])[id], fresh: try store.handOffPlan(card, host: nil, fresh: true), opening: opening)
        }
        .observing(services.store, id: launchHost, into: $launchAgents, onError: workspace.fail) { [host = launchHost] store in
            guard let host else { return MacAgents(hostID: "", agents: [], modifiedAt: .distantPast) }
            return try store.macAgents(on: host)
        }
        // 改模型、思考强度的请求与目录记录不在会话列表那一页里：只读选中的那个（会话变了就带着新的会话状态重读）
        .observing(services.store, id: chosenLive, into: $digest, onError: workspace.fail) { [session = chosenLive] store in
            guard let session else { return SessionDigest(session: nil, project: nil, deliveries: []) }
            return SessionDigest(
                session: session, project: nil, deliveries: try store.deliveryRequests(toSession: session.sessionID),
                catalog: try session.catalogID.flatMap { try store.agentCatalog($0) })
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.item) {
            // 新会话放最上面：会话多了也不用往下翻
            MenuButton(sections: [
                ChoiceMenu.Section(choices: [ChoiceMenu.Choice(title: "新会话", image: .icon(.add), checked: chosen == nil) { fresh = true }]),
                ChoiceMenu.Section(choices: sessions.map { item in
                    ChoiceMenu.Choice(title: .verbatim(title(item).visible), checked: item.state.id == chosen?.state.id) {
                        choice = item.state.id
                        fresh = false
                    }
                }),
            ], accessibilityLabel: chosen.map { "交给 \($0.state.title)，点开换会话" } ?? "交给新会话") {
                DestinationChip(title: Text(chosen.map { "交给 \($0.state.title)" } ?? "交给 新会话")) {
                    if let chosen { StateDot(shown: workspace.shown(chosen), size: 7) }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func title(_ item: SessionListItem) -> Dotted {
        HandOffTargets.title(item, project: workspace.catalog?.project(item.state.projectID), shown: workspace.shown(item))
    }

    private func send() {
        guard canSend else { return }
        guard let session = chosen?.state else {
            // 选过的那个会话已经不在了：同点了"新会话"，另开一个
            let plan = fresh || choice != nil ? planned?.fresh : planned?.plan
            return workspace.startNewSession(draft, card: outbox.card, opening: planned?.opening, plan: plan)
        }
        workspace.reply(
            to: session, commands: commands, from: box, accepting: .reply, card: outbox.card, saying: Dotted(String(localized: "已交给 \(session.title)")))
        focused = false
        workspace.outbox = nil
    }
}
#endif
