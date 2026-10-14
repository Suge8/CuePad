#if os(iOS)
import CueStore
import SwiftUI

/// 发给 Agent：浮在键盘上方的输入框（与随手记、新会话同一种），提示词的正文已经带在里面，可以补一句；
/// 头部一颗胶囊选交给哪个会话（菜单最上面是"新会话"，其下本项目的在前、最近要你注意的在前）。默认交到哪与 Mac 的发给 Agent、
/// Cue 的开工同一份规则（`CueStore.handOffPlan`）：叶子绑着会话就是那个会话（已结束的也列上，Mac 收到后唤醒它），没绑而上一步的会话
/// 还开着就接着用它，否则是新会话；选"新会话…"就不接着用（同 Cue 的 fresh）。
/// 发出即收起，提示词卡上随即出现那个会话的状态（发送中 → 工作中 → 有新回复；开新会话时先是"正在开会话"，开好后同样关联）。工具排里是选中会话的模型与思考强度（与会话页回复框同一组件 `PiConfigControls`）。
/// 选中会话做不到的（图片、斜杠命令、换模型，`AgentCapabilities`）不露出。
struct HandOffInput: View {
    let outbox: Outbox
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette
    @State private var draft = ComposerDraft()
    /// 在线会话各自的模型显示值与可换的模型、命令（按会话记录 id）。
    @State private var digests: [UUID: SessionDigest]?
    @State private var choice: UUID?
    @State private var planned: Planned?
    @State private var sending = false
    @FocusState private var focused: Bool

    /// 交到哪的规则读出的：决定本身（不是从提示词来的为 nil）、决定交给的会话的会话行（默认目标；没有为 nil，即新会话），
    /// 与选"新会话…"时的决定（`handOffPlan(fresh:)`，与 Cue 开工带 fresh 同一条规则）。
    nonisolated private struct Planned: Equatable, Sendable {
        var plan: HandOffPlan?
        var bound: PiSessionListItem?
        var fresh: HandOffPlan?
    }

    /// 能交给的会话：在线的（Mac 的发送目标共用同一份规则），叶子绑着的会话已结束时它排最前。
    private var sessions: [PiSessionListItem] {
        let live = HandOffTargets.sessions(services.liveSessions.live, project: outbox.project)
        guard let bound = planned?.bound, !live.contains(where: { $0.state.sessionID == bound.state.sessionID }) else { return live }
        return [bound] + live
    }
    private var chosen: PiSessionListItem? {
        let all = sessions
        if let choice { return all.first { $0.state.id == choice } }
        return planned?.bound.flatMap { bound in all.first { $0.state.sessionID == bound.state.sessionID } }
    }
    private var canSend: Bool { services.reachesPiHost && !sending && planned != nil }
    /// 选中会话的模型与思考强度的显示值（`SessionDigest.config`）。
    private var config: PiConfigShown? { chosen.flatMap { digests?[$0.state.id]?.config } }
    private var catalog: AgentCatalog? { chosen.flatMap { digests?[$0.state.id]?.catalog } }
    private var commands: [PiSlashCommand] { chosen?.state.usableCommands(in: catalog) ?? [] }

    var body: some View {
        Composer(
            draft: $draft, prompt: "补一句（可不填）", label: "发给 Agent", focus: $focused,
            accepts: chosen?.state.composerKinds ?? [.images, .cards], cardsFrom: outbox.project, keeps: outbox.card,
            commands: commands,
            header: {
                header.padding(.horizontal, 12).padding(.top, 10)
                if !services.reachesPiHost {
                    SyncHint(status: services.syncStatus, consequence: "发不到 Mac").font(.caption).lineLimit(1)
                        .padding(.horizontal, 18).padding(.top, 8)
                }
                if let failure = config?.failure {
                    Text("没换成：\(failure)").font(.caption).foregroundStyle(palette.failure).lineLimit(2)
                        .padding(.horizontal, 18).padding(.top, 6)
                }
            },
            tools: {
                if let session = chosen?.state, let config, let models = catalog?.models, session.capabilities.contains(.model), !models.isEmpty {
                    PiConfigControls(session: session, models: models, shown: config)
                }
            },
            send: {
                Button(action: send) { SubmitGlyph(.send, enabled: canSend) }
                    .buttonStyle(.plain).disabled(!canSend)
                    .accessibilityLabel(chosen.map { "交给 \($0.state.title)" } ?? "开新会话交给它")
            })
        .floatingInputLocked(sending)
        .onAppear {
            draft.attachments = [outbox]
            focused = true
        }
        .observing(services.store, id: outbox.card, into: $planned, onError: workspace.fail) { [card = outbox.card] store in
            guard let card else { return Planned() }
            let plan = try store.handOffPlan(card, host: nil)
            guard case .session(let id, _, _) = plan.destination else { return Planned(plan: plan, fresh: plan) }
            return Planned(plan: plan, bound: try store.piSessions(sessionIDs: [id])[id], fresh: try store.handOffPlan(card, host: nil, fresh: true))
        }
        // 改模型、思考强度的请求与目录记录不在会话列表那一页里：按在线会话读各自的（会话变了就带着新的会话状态重读）
        .observing(services.store, id: services.liveSessions.live, into: $digests, onError: workspace.fail) { [live = services.liveSessions.live] store in
            var digests: [UUID: SessionDigest] = [:]
            for item in live {
                digests[item.state.id] = SessionDigest(
                    session: item.state, project: nil, deliveries: try store.deliveryRequests(toSession: item.state.sessionID),
                    catalog: try item.state.catalogID.flatMap { try store.agentCatalog($0) })
            }
            return digests
        }
    }

    /// 头部：交给谁的胶囊（菜单里是在线会话与"新会话"）；送不到 Mac 时的原因在它下面单独一行。
    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                // 新会话放最上面：会话多了也不用往下翻
                Button("新会话…", systemImage: "plus", action: newSession)
                Divider()
                ForEach(sessions) { item in
                    Button { choice = item.state.id } label: {
                        Label { Text(title(item)) } icon: { Image(systemName: item.state.id == chosen?.state.id ? "checkmark" : "") }
                    }
                }
            } label: {
                DestinationChip(title: Text(chosen.map { "交给 \($0.state.title)" } ?? "交给 新会话")) {
                    if let chosen { PiStateDot(shown: workspace.shown(chosen), size: 7) }
                }
            }
            .accessibilityLabel(chosen.map { "交给 \($0.state.title)，点开换会话" } ?? "交给新会话")
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
            return Self.startDefault(draft, card: outbox.card, plan: planned?.plan, workspace: workspace, navigation: navigation)
        }
        let sent = draft.accepting(session.composerKinds), mode = session.deliveryModes[0]
        let line = PiSlash.line(of: sent, in: commands)
        sending = true
        workspace.attempt {
            defer { sending = false }
            if let line {
                _ = try await services.requestMacDelivery(line, to: session, mode: .command, card: outbox.card)
            } else {
                _ = try await services.requestMacDelivery(sent, to: session, mode: mode, card: outbox.card)
            }
            focused = false
            navigation.outbox = nil
            workspace.say("已交给 \(session.title)")
        }
    }

    /// 默认目标是新会话时点发送，按交到哪的决定：未分类的开不了会话，说一句（与 Mac 上发给 Agent 同一句）、什么都不开；
    /// 其余换成新会话的输入框，项目、由哪台 Mac 开、会话名都取自决定。要在别的项目开，从菜单选"新会话…"。
    static func startDefault(_ draft: ComposerDraft, card: UUID?, plan: HandOffPlan?, workspace: Workspace, navigation: Navigation) {
        if plan?.destination == .unfiled { return workspace.say("未分类的任务没有文件夹，开不了会话", isError: true) }
        navigation.handOffToNewSession(draft, card: card, plan: plan)
    }

    /// 开新会话交给它：换成新会话的输入框，正文与补的话带过去。
    private func newSession() {
        navigation.handOffToNewSession(draft, card: outbox.card, plan: planned?.fresh)
    }
}
#endif
