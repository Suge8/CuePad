#if os(iOS)
import CueStore
import SwiftUI

/// 发给 Agent：浮在键盘上方的输入框（与随手记、新会话同一种），提示词的正文已经带在里面，可以补一句；
/// 头部一颗胶囊选交给哪个会话（菜单最上面是"新会话"，其下本项目的在前、最近要你注意的在前）。默认交到哪与 Mac 的发给 Agent、
/// Cue 的开工同一份规则（`CueStore.handOffPlan`）：叶子绑着会话就是那个会话（已结束的也列上，Mac 收到后唤醒它），没绑就是新会话。
/// 发出即收起，提示词卡上随即出现那个会话的状态（发送中 → 工作中 → 有新回复；开新会话时先是"正在开会话"，开好后同样关联）。工具排里是选中会话的模型与思考强度（与会话页回复框同一组件 `PiConfigControls`）。
struct HandOffInput: View {
    let outbox: Outbox
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette
    @State private var draft = ComposerDraft()
    @State private var configs: [UUID: PiConfigShown]?
    @State private var choice: UUID?
    @State private var planned: Planned?
    @State private var sending = false
    @FocusState private var focused: Bool

    /// 交到哪的规则读出的：默认目标是叶子绑着的会话（没绑为 nil，即新会话）；开新会话时的会话名（叶子的标题）。
    nonisolated private struct Planned: Equatable, Sendable {
        var bound: PiSessionListItem?
        var name: String?
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
    private var config: PiConfigShown? { chosen.flatMap { configs?[$0.state.id] } }

    var body: some View {
        Composer(
            draft: $draft, prompt: "补一句（可不填）", label: "发给 Agent", focus: $focused,
            accepts: [.images, .cards], cardsFrom: outbox.project, keeps: outbox.card, commands: chosen?.state.commands ?? [],
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
                if let session = chosen?.state, let config, !session.models.isEmpty {
                    PiConfigControls(session: session, shown: config)
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
            guard case .session(let id, _, _) = plan.destination else { return Planned(name: plan.name) }
            return Planned(bound: try store.piSessions(sessionIDs: [id])[id], name: plan.name)
        }
        // 改模型、思考强度的请求不在会话列表那一页里：按在线会话读各自的投送请求（会话变了就带着新的会话状态重读）
        .observing(services.store, id: services.liveSessions.live, into: $configs, onError: workspace.fail) { [live = services.liveSessions.live] store in
            var configs: [UUID: PiConfigShown] = [:]
            for item in live {
                let deliveries = try store.deliveryRequests(toSession: item.state.sessionID)
                configs[item.state.id] = SessionDigest(session: item.state, project: nil, deliveries: deliveries).config
            }
            return configs
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
                    if let chosen { PiStateDot(shown: services.settings.shown(chosen), size: 7) }
                }
            }
            .accessibilityLabel(chosen.map { "交给 \($0.state.title)，点开换会话" } ?? "交给新会话")
            Spacer(minLength: 0)
        }
    }

    private func title(_ item: PiSessionListItem) -> Dotted {
        HandOffTargets.title(item, project: workspace.catalog?.project(item.state.projectID), shown: services.settings.shown(item))
    }

    private func send() {
        guard canSend else { return }
        guard let session = chosen?.state else { return newSession() }
        let sent = draft, mode = MacDelivery.modes(for: session).first ?? .send
        let line = PiSlash.line(of: sent, in: session.commands)
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

    /// 开新会话交给它：换成新会话的输入框，正文与补的话带过去。
    private func newSession() {
        navigation.handOffToNewSession(draft, card: outbox.card, name: planned?.name)
    }
}
#endif
