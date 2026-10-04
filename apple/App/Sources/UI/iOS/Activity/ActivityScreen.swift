#if os(iOS)
import CueStore
import CueSync
import SwiftUI

/// 活动页一次读取的数据：Mac 同步来的 Pi 会话状态、手机发往 Mac 的请求、发送记录。
nonisolated struct ActivityData: Sendable {
    var waiting: [PiSessionState]
    var running: [PiSessionState]
    /// 空闲、出错与未知状态，已结束的排在最后。
    var idle: [PiSessionState]
    var deliveries: [DeliveryRequest]
    var sends: [SendRecord]
    var projects: [UUID: Project]

    nonisolated static let sendLimit = 20

    /// 标签角标：只计等你确认。
    var badge: Int { waiting.count }
    var sessions: [PiSessionState] { waiting + running + idle }
    var isEmpty: Bool { sessions.isEmpty && deliveries.isEmpty && sends.isEmpty }

    static func read(from store: isolated CueStore) throws -> ActivityData {
        let states = try store.piSessionStates()
        return ActivityData(
            waiting: states.filter { $0.state == .known(.waitingForUser) },
            running: states.filter(\.state.isWorking),
            idle: states.filter { $0.state != .known(.waitingForUser) && !$0.state.isWorking && $0.state != .known(.ended) }
                + states.filter { $0.state == .known(.ended) },
            deliveries: try store.deliveryRequests(),
            sends: Array(try store.sendRecords().prefix(sendLimit)),
            projects: Dictionary(uniqueKeysWithValues: try store.projects().map { ($0.id, $0) }))
    }
}

/// 活动：等你确认的会话在最前，其次运行中、空闲与出错、已结束（最淡）的会话；点开看近况并回复。
/// 下面是会话已经不在列表里的请求，与发送记录。
struct ActivityScreen: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var data: ActivityData?

    var body: some View {
        ScrollView {
            if let data {
                VStack(alignment: .leading, spacing: 22) {
                    if !services.syncStatus.reachesMac { SyncBlockedNote(status: services.syncStatus) }
                    if data.isEmpty {
                        ContentUnavailableView {
                            Label("还没有活动", systemImage: "waveform.path.ecg")
                        } description: {
                            Text("在 Mac 上用 Pi 干活时，会话会出现在这里，点开能看近况、直接回复")
                        }
                        .padding(.top, 40)
                    }
                    if !data.waiting.isEmpty {
                        ActivitySection(title: "等你确认", count: data.waiting.count, tint: palette.attention) {
                            rows(data.waiting, data)
                        }
                    }
                    if !data.running.isEmpty || !data.idle.isEmpty {
                        ActivitySection(title: "Pi 会话", count: data.running.count + data.idle.count) {
                            rows(data.running + data.idle, data)
                        }
                    }
                    let orphans = data.deliveries.filter { request in !data.sessions.contains { $0.sessionID == request.target.ref } }
                    if !orphans.isEmpty {
                        ActivitySection(title: "发到 Mac", count: orphans.count) {
                            ForEach(Array(orphans.enumerated()), id: \.element.id) { index, request in
                                if index > 0 { Divider().padding(.leading, 16) }
                                DeliveryRow(request: request, session: nil)
                            }
                        }
                    }
                    if !data.sends.isEmpty {
                        ActivitySection(title: "发送记录", count: nil) {
                            ForEach(Array(data.sends.enumerated()), id: \.element.id) { index, record in
                                if index > 0 { Divider().padding(.leading, 16) }
                                SendRecordRow(record: record, live: data.sessions.first { $0.sessionID == record.targetRef && $0.state != .known(.ended) })
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .animation(Motion.quick, value: ActivityShape(data))
            }
        }
        .background(palette.desk)
        .bottomEdgeFade()
        .navigationTitle("活动")
        .refreshable { await services.syncNow() }
        .observing(services.store, [.piSessionStates, .deliveryRequests, .sendRecords, .projects], into: $data, onError: workspace.fail) {
            try ActivityData.read(from: $0)
        }
    }

    @ViewBuilder private func rows(_ sessions: [PiSessionState], _ data: ActivityData) -> some View {
        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
            if index > 0 { Divider().padding(.leading, 16) }
            SessionRow(session: session, project: session.projectID.flatMap { data.projects[$0] })
        }
    }
}

/// 活动页里会引起重排的部分：会话、请求、记录的增删与状态变化（计时不算）。
private struct ActivityShape: Equatable {
    var sessions: [PiSessionState.ID]
    var states: [Open<PiWorkState>]
    var deliveries: [DeliveryRequest.ID]
    var statuses: [Open<DeliveryStatus>]
    var sends: [SendRecord.ID]

    init(_ data: ActivityData) {
        sessions = data.sessions.map(\.id)
        states = data.sessions.map(\.state)
        deliveries = data.deliveries.map(\.id)
        statuses = data.deliveries.map(\.status)
        sends = data.sends.map(\.id)
    }
}

nonisolated extension SyncStatus {
    /// 此刻同步能把请求送到 Mac、把 Mac 上的 Pi 状态带回来：已连上或正在连接。
    /// 其余状态（没开 iCloud、不可用、暂停、出错、空间不足）都到不了，界面写明原因。
    var reachesMac: Bool {
        switch self {
        case .starting, .idle, .syncing: true
        default: false
        }
    }
}

/// 同步到不了 Mac 时的说明：哪里不通、去哪处理（与设置页同一套文案）。
struct SyncBlockedNote: View {
    let status: SyncStatus
    @Environment(\.palette) private var palette

    var body: some View {
        let summary = SyncSummary(status)
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(summary.title)，看不到 Mac 上的 Pi，也发不到 Mac").font(.footnote.weight(.medium)).foregroundStyle(palette.ink)
                if let detail = summary.detail { Text(detail).font(.footnote).foregroundStyle(palette.ink2) }
            }
        } icon: {
            Image(systemName: summary.symbol).foregroundStyle(summary.color(palette))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .paper(radius: 14)
    }
}

private struct ActivitySection<Content: View>: View {
    let title: String
    let count: Int?
    var tint: Color?
    @ViewBuilder let content: Content
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: title, count: count)
            VStack(spacing: 0) { content }
                .paper(radius: 16)
                .overlay {
                    if let tint {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(tint.opacity(palette.highContrast ? 0.8 : 0.35)).allowsHitTesting(false)
                    }
                }
        }
    }
}

/// 一个会话：名字与在当前状态里待了多久、在哪 · 状态、一行近况（等你确认时是问题，否则是你最后说的）。
/// 已结束的整行更淡。点开看近况、回复。
private struct SessionRow: View {
    let session: PiSessionState
    let project: Project?
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette

    private var preview: String? {
        let text = session.question?.displayText ?? session.lastPrompt ?? (session.state.isWorking ? session.detail : nil)
        return text?.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    var body: some View {
        let ended = session.state == .known(.ended)
        Button { navigation.push(.session(session.id)) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.title).font(.headline).foregroundStyle(palette.ink).lineLimit(1)
                    Spacer(minLength: 8)
                    PiElapsed(session: session)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(palette.ink3)
                        .accessibilityHidden(true)
                }
                HStack(spacing: 6) {
                    PiStateDot(state: session.state, size: 6)
                    PiActivityLine(lead: [PiPlace.name(of: session, project: project), session.state.label], font: .subheadline)
                        .foregroundStyle(session.state == .known(.waitingForUser) ? palette.attention : palette.ink2)
                }
                if let preview {
                    Text(preview).font(.subheadline).foregroundStyle(palette.ink3).lineLimit(1)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(ended ? 0.6 : 1)
            .contentShape(.rect)
        }
        .buttonStyle(RowPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("看近况、回复")
    }
}

/// 一条发送记录：内容、时间与目标；会话仍在时可以再发一次，否则复制。
private struct SendRecordRow: View {
    let record: SendRecord
    let live: PiSessionState?
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(CardText(record.content).title.nonEmpty ?? "图片").font(.body).foregroundStyle(palette.ink).lineLimit(1)
                Text("\(DateLabel.short(record.sentAt)) → \(record.targetName) · \(record.targetKind.label)")
                    .font(.footnote).foregroundStyle(palette.ink3).lineLimit(1)
            }
            Spacer(minLength: 8)
            if live != nil {
                rowButton("重发", "paperplane", action: resend)
            } else {
                rowButton("复制", "doc.on.doc", action: copy)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .contextMenu {
            Button("复制", systemImage: "doc.on.doc") { copy() }
            if live != nil { Button("重发", systemImage: "paperplane") { resend() } }
            ShareLink(item: record.content) { Label("分享", systemImage: "square.and.arrow.up") }
        }
    }

    private func rowButton(_ label: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(label, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .foregroundStyle(palette.ink2)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
            .buttonStyle(.borderless)
    }

    private func resend() {
        guard let live else { return }
        navigation.openSession(live.id, draft: Navigation.Outbox(content: record.content, card: record.cardID, task: record.taskID))
    }

    private func copy() {
        let content = record.content, card = record.cardID, task = record.taskID
        workspace.attempt {
            try await services.send(content, to: .clipboard, card: card, task: task)
            workspace.say("已复制")
        }
    }
}

nonisolated extension SendTargetKind {
    var label: String {
        switch self {
        case .piSession: "Pi"
        case .app: "应用"
        case .clipboard: "剪贴板"
        }
    }
}

nonisolated extension Open<SendTargetKind> {
    var label: String { known?.label ?? "其他" }
}
#endif
