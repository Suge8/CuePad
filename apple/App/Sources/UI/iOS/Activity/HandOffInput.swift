#if os(iOS)
import CueStore
import SwiftUI

/// 交给 Agent：浮在键盘上方的输入框（与随手记、新会话同一种），灵感或任务的正文已经带在里面，可以补一句；
/// 头部一颗胶囊选交给哪个会话（菜单最上面是"新会话"，其下本项目的在前、最近要你注意的在前）。发出即收起，
/// 灵感或任务的行上随即出现那个会话的状态点（发送中 → 工作中 → 有新回复；开新会话时先是"正在开会话"，开好后同样关联）。
/// 没有在线会话时发送就是开新会话。工具排里是选中会话的模型与思考强度（与会话页回复框同一组件 `PiConfigControls`）。
struct HandOffInput: View {
    let outbox: Navigation.Outbox
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette
    @State private var draft = ComposerDraft()
    @State private var live: Live?
    @State private var choice: UUID?
    @State private var sending = false
    @FocusState private var focused: Bool

    /// 在线会话（本项目的在前、最近要你注意的在前）与各自模型与思考强度的显示值（`SessionDigest.config`）。
    private struct Live: Sendable {
        var sessions: [PiSessionListItem]
        var configs: [UUID: PiConfigShown]
    }

    private var sessions: [PiSessionListItem]? { live?.sessions }
    private var chosen: PiSessionListItem? { sessions?.first { $0.state.id == choice } ?? sessions?.first }
    private var canSend: Bool { services.reachesPiHost && !sending && sessions != nil }
    private var config: PiConfigShown? { chosen.flatMap { live?.configs[$0.state.id] } }

    var body: some View {
        Composer(
            draft: $draft, prompt: "补一句（可不填）", label: "交给 Agent", focus: $focused,
            accepts: [.images, .cards], cardsFrom: outbox.project, pinnedOpen: true,
            header: {
                header.padding(.horizontal, 12).padding(.top, 10)
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
                Button(action: send) { SendGlyph(enabled: canSend) }
                    .buttonStyle(.plain).disabled(!canSend)
                    .accessibilityLabel(chosen.map { "交给 \($0.state.title)" } ?? "开新会话交给它")
            })
        .floatingInputLocked(sending)
        .onAppear {
            draft.attachment = outbox
            focused = true
        }
        .observing(services.store, [.piSessionStates, .deliveryRequests], into: $live, onError: workspace.fail) { [project = outbox.project] store in
            let sessions = try store.piSessionPage(.live).items.sorted {
                ($0.state.projectID == project && project != nil ? 1 : 0, $0.state.state.urgency)
                    > ($1.state.projectID == project && project != nil ? 1 : 0, $1.state.state.urgency)
            }
            var configs: [UUID: PiConfigShown] = [:]
            for item in sessions {
                let deliveries = try store.deliveryRequests(toSession: item.state.sessionID)
                configs[item.state.id] = SessionDigest(session: item.state, project: nil, deliveries: deliveries).config
            }
            return Live(sessions: sessions, configs: configs)
        }
    }

    /// 头部：交给谁的胶囊（菜单里是在线会话与"新会话"），右边送不到 Mac 时的原因。
    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                // 新会话放最上面：会话多了也不用往下翻
                Button("新会话…", systemImage: "plus", action: newSession)
                Divider()
                ForEach(sessions ?? []) { item in
                    Button { choice = item.state.id } label: {
                        Label(title(item), systemImage: item.state.id == chosen?.state.id ? "checkmark" : "")
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if let chosen { PiStateDot(shown: services.settings.shown(chosen), size: 7) }
                    Text(chosen.map { "交给 \($0.state.title)" } ?? "交给 新会话").lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(palette.ink3)
                }
                .font(.subheadline.weight(.medium)).foregroundStyle(palette.ink)
                .padding(.horizontal, 12).frame(height: 32)
                .background(palette.fill, in: .capsule)
            }
            .accessibilityLabel(chosen.map { "交给 \($0.state.title)，点开换会话" } ?? "交给新会话")
            Spacer(minLength: 4)
            if !services.reachesPiHost { SyncHint(status: services.syncStatus).font(.caption).lineLimit(2) }
        }
    }

    private func title(_ item: PiSessionListItem) -> String {
        let place = PiPlace.name(of: item.state, project: workspace.catalog?.project(item.state.projectID))
        return [item.state.title, place, services.settings.shown(item).label].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func send() {
        guard canSend else { return }
        guard let session = chosen?.state else { return newSession() }
        let sent = draft, mode = MacDelivery.modes(for: session, hasImages: sent.hasImages).first ?? .send
        sending = true
        workspace.attempt {
            defer { sending = false }
            _ = try await services.requestMacDelivery(sent, to: session, mode: mode)
            focused = false
            navigation.outbox = nil
            workspace.say("已交给 \(session.title)")
        }
    }

    /// 开新会话交给它：换成新会话的输入框，正文与补的话带过去。
    private func newSession() {
        navigation.handOffToNewSession(draft)
    }
}
#endif
