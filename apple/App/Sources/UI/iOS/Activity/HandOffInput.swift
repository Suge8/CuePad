#if os(iOS)
import CueStore
import SwiftUI

/// 发给 Agent：浮在键盘上方的输入框（与随手记、新会话同一种），任务的正文已经带在里面，可以补一句；头部一颗胶囊选交给哪个会话。
/// 默认交到哪与 Mac 的发给 Agent、Cue 的开工同一份规则（`CueStore.handOffPlan`）：叶子绑着会话就是那个会话（已结束的也列上，Mac 收到后唤醒它），没绑而上一步的会话
/// 还开着就接着用它，否则是新会话；选"新会话…"就不接着用（同 Cue 的 fresh）。
/// 发出即收起，任务那一行随即出现那个会话的状态；开新会话时先是"正在开会话"，开好后同样关联。
struct HandOffInput: View {
    let outbox: Outbox
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    /// 选中的在线会话的模型显示值与可换的模型、命令。
    @State private var digest: SessionDigest?
    @State private var choice: UUID?
    @State private var planned: Planned?
    @FocusState private var focused: Bool

    /// 交到哪的规则读出的：决定本身（不是从任务来的为 nil）、决定交给的会话的会话行（默认目标；没有为 nil，即新会话），
    /// 与选"新会话…"时的决定（`handOffPlan(fresh:)`，与 Cue 开工带 fresh 同一条规则），以及开新会话时任务的第一句（`CueStore.opening`）。
    /// 还没有哪台 Mac 写下过自己时没有决定（`noMac`）：这是新用户的常态、不是出错，原因叠在输入框上方（`composerNotice`），同新会话的输入框。
    nonisolated private struct Planned: Equatable, Sendable {
        var plan: HandOffPlan?
        var bound: PiSessionListItem?
        var fresh: HandOffPlan?
        var opening: String?
        var noMac = false
    }

    /// 能交给的会话：在线的（Mac 的发送目标共用同一份规则），叶子绑着的会话已结束时它排最前。
    private var sessions: [PiSessionListItem] {
        let live = HandOffTargets.sessions(services.liveSessions.live, project: outbox.project, at: services.speech)
        guard let bound = planned?.bound, !live.contains(where: { $0.state.sessionID == bound.state.sessionID }) else { return live }
        return [bound] + live
    }
    private var chosen: PiSessionListItem? {
        let all = sessions
        if let choice { return all.first { $0.state.id == choice } }
        return planned?.bound.flatMap { bound in all.first { $0.state.sessionID == bound.state.sessionID } }
    }
    private var canSend: Bool { services.reachesPiHost && planned.map { !$0.noMac } == true }
    private var draft: ComposerDraft { workspace.handOffDraft }

    /// 草稿在 `Workspace.handOffDraft`：发出即收起，写库失败时放回草稿、重新浮起这个输入框。
    private var box: Binding<ComposerDraft> {
        let workspace = workspace, outbox = outbox
        return Binding(get: { workspace.handOffDraft }) { draft in
            workspace.handOffDraft = draft
            if workspace.outbox == nil, !draft.isEmpty(accepting: [.images, .cards]) { workspace.outbox = outbox }
        }
    }
    /// 选中的会话在线时是它（模型与命令只给在线的换，已结束的绑定会话没有）。
    private var chosenLive: PiSessionState? {
        guard let chosen = chosen?.state else { return nil }
        return services.liveSessions.live.contains { $0.state.id == chosen.id } ? chosen : nil
    }
    /// 读到的是选中的那个的（刚换选、新的一份还没读回来时没有）。
    private var chosenDigest: SessionDigest? {
        guard let digest, let id = chosenLive?.id, digest.session?.id == id else { return nil }
        return digest
    }
    /// 选中会话的模型与思考强度的显示值（`SessionDigest.config`）。
    private var config: PiConfigShown? { chosenDigest?.config(at: services.speech) }
    private var catalog: AgentCatalog? { chosenDigest?.catalog }
    private var commands: [PiSlashCommand] { chosen?.state.usableCommands(in: catalog) ?? [] }

    /// 选中的会话能换模型时，工具排上的那几样。
    private var tools: (session: PiSessionState, models: [PiModelOption], config: PiConfigShown)? {
        guard let session = chosen?.state, let config, let models = catalog?.models, session.capabilities.contains(.model), !models.isEmpty else { return nil }
        return (session, models, config)
    }

    var body: some View {
        Composer(
            draft: box, prompt: "补一句（可不填）", label: "发给 Agent", focus: $focused,
            accepts: chosen?.state.composerKinds ?? [.images, .cards], cardsFrom: outbox.project, keeps: outbox.card, tooled: tools != nil,
            commands: commands,
            header: { header.padding(.horizontal, 12).padding(.top, 10) },
            tools: {
                if let tools { SessionConfigControls(session: tools.session, models: tools.models, shown: tools.config) }
            },
            send: {
                Button(action: send) { SendGlyph(canSend ? .ready : .idle) }
                    .buttonStyle(PressStyle(.button)).disabled(!canSend)
                    .accessibilityLabel(chosen.map { String(localized: "交给 \($0.state.title)") } ?? String(localized: "开新会话交给它"))
            })
        .composerNotice(planned?.noMac == true || !services.reachesPiHost || config?.failure != nil) {
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
                plan: plan, bound: try store.piSessions(sessionIDs: [id])[id], fresh: try store.handOffPlan(card, host: nil, fresh: true), opening: opening)
        }
        // 改模型、思考强度的请求与目录记录不在会话列表那一页里：只读选中的那个（会话变了就带着新的会话状态重读）
        .observing(services.store, id: chosenLive, into: $digest, onError: workspace.fail) { [session = chosenLive] store in
            guard let session else { return SessionDigest(session: nil, project: nil, deliveries: []) }
            return SessionDigest(
                session: session, project: nil, deliveries: try store.deliveryRequests(toSession: session.sessionID),
                catalog: try session.catalogID.flatMap { try store.agentCatalog($0) })
        }
    }

    /// 头部：交给谁的胶囊（菜单里是在线会话与"新会话"）；送不到 Mac 时的原因叠在输入框上方（`composerNotice`）。
    private var header: some View {
        HStack(spacing: 8) {
            // 新会话放最上面：会话多了也不用往下翻
            MenuButton(sections: [
                ChoiceMenu.Section(choices: [ChoiceMenu.Choice(title: "新会话…", image: .icon(.add), choose: newSession)]),
                ChoiceMenu.Section(choices: sessions.map { item in
                    ChoiceMenu.Choice(title: .verbatim(title(item).visible), checked: item.state.id == chosen?.state.id) { choice = item.state.id }
                }),
            ], accessibilityLabel: chosen.map { "交给 \($0.state.title)，点开换会话" } ?? "交给新会话") {
                DestinationChip(title: Text(chosen.map { "交给 \($0.state.title)" } ?? "交给 新会话")) {
                    if let chosen { PiStateDot(shown: workspace.shown(chosen), size: 7) }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func title(_ item: PiSessionListItem) -> Dotted {
        HandOffTargets.title(item, project: workspace.catalog?.project(item.state.projectID), shown: workspace.shown(item))
    }

    private func send() {
        guard canSend else { return }
        guard let session = chosen?.state else {
            guard choice == nil else { return newSession() }
            return Self.startDefault(draft, card: outbox.card, plan: planned?.plan, opening: planned?.opening, workspace: workspace)
        }
        let kinds = session.composerKinds, files = services.store.files
        let saying = Dotted(String(localized: "已交给 \(session.title)"))
        let written = if let line = PiSlash.line(of: draft.accepting(kinds), in: commands) {
            workspace.speak(to: .session(session, mode: .command, card: outbox.card), from: box, saying: saying) { _ in line }
        } else {
            workspace.speak(to: .session(session, mode: .send, card: outbox.card), from: box, saying: saying) { try $0.accepting(kinds).stored(in: files) }
        }
        // 图片存不进图片库时什么都没发：浮框留着、草稿原样，只看到报错
        guard written != nil else { return }
        focused = false
        workspace.outbox = nil
    }

    /// 默认目标是新会话时点发送，按交到哪的决定：换成新会话的输入框，项目、由哪台 Mac 开、会话名都取自决定。要在别的项目开，从菜单选"新会话…"。
    /// 开新会话时任务带的是 `opening`（子任务带着顶层任务作背景）；交给已有会话的只是这一步自己的。
    static func startDefault(
        _ draft: ComposerDraft, card: UUID?, plan: HandOffPlan?, opening: String?, workspace: Workspace
    ) {
        workspace.handOffToNewSession(draft.retelling(card, as: opening), card: card, plan: plan)
    }

    /// 开新会话交给它：换成新会话的输入框，正文与补的话带过去。
    private func newSession() {
        workspace.handOffToNewSession(draft.retelling(outbox.card, as: planned?.opening), card: outbox.card, plan: planned?.fresh)
    }
}
#endif
