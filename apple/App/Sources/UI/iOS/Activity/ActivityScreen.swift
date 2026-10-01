#if os(iOS)
import CueStore
import CueSync
import SwiftUI

/// 活动页一次读取的数据：Mac 同步来的 Pi 会话状态、手机发往 Mac 的请求、发送记录。
nonisolated struct ActivityData: Sendable {
    var waiting: [PiSessionState]
    var running: [PiSessionState]
    /// 空闲、出错与未知状态。
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
            idle: states.filter { $0.state != .known(.waitingForUser) && !$0.state.isWorking },
            deliveries: try store.deliveryRequests(),
            sends: Array(try store.sendRecords().prefix(sendLimit)),
            projects: Dictionary(uniqueKeysWithValues: try store.projects().map { ($0.id, $0) }))
    }
}

/// 活动：等你确认置顶，其次运行中与空闲的会话，然后是发到 Mac 的请求与发送记录。Pi 状态只读，回应在 Mac 上。
struct ActivityScreen: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette
    @State private var data: ActivityData?

    /// 通知定位到的会话标出多久。
    private static let focusDuration: Duration = .seconds(1.6)

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            if let data {
                VStack(alignment: .leading, spacing: 22) {
                    if !services.syncStatus.reachesMac { SyncBlockedNote(status: services.syncStatus) }
                    if data.isEmpty {
                        ContentUnavailableView {
                            Label("还没有活动", systemImage: "waveform.path.ecg")
                        } description: {
                            Text("在 Mac 上用 Pi 干活时，进度会显示在这里")
                        }
                        .padding(.top, 40)
                    }
                    ForEach(data.waiting) { session in
                        WaitingCard(session: session, project: session.projectID.flatMap { data.projects[$0] })
                            .focusRing(session.id == navigation.focusedSession, radius: 18)
                            .id(session.id)
                    }
                    if !data.running.isEmpty || !data.idle.isEmpty {
                        ActivitySection(title: "Pi 会话", count: data.running.count + data.idle.count) {
                            ForEach(Array((data.running + data.idle).enumerated()), id: \.element.id) { index, session in
                                if index > 0 { Divider().padding(.leading, 44) }
                                SessionRow(session: session, project: session.projectID.flatMap { data.projects[$0] })
                                    .focusRing(session.id == navigation.focusedSession, radius: 16)
                                    .id(session.id)
                            }
                        }
                    }
                    if !data.deliveries.isEmpty {
                        ActivitySection(title: "发到 Mac", count: data.deliveries.count) {
                            ForEach(Array(data.deliveries.enumerated()), id: \.element.id) { index, request in
                                if index > 0 { Divider().padding(.leading, 16) }
                                DeliveryRow(request: request, live: data.sessions.first { $0.sessionID == request.target.ref })
                            }
                        }
                    }
                    if !data.sends.isEmpty {
                        ActivitySection(title: "发送记录", count: nil) {
                            ForEach(Array(data.sends.enumerated()), id: \.element.id) { index, record in
                                if index > 0 { Divider().padding(.leading, 16) }
                                SendRecordRow(record: record, live: data.sessions.first { $0.sessionID == record.targetRef })
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .animation(Motion.quick, value: ActivityShape(data))
            }
        }
        .task(id: FocusKey(session: navigation.focusedSession, loaded: data != nil)) {
            guard let id = navigation.focusedSession, data != nil else { return }
            withAnimation(Motion.quick) { proxy.scrollTo(id, anchor: .top) }
            try? await Task.sleep(for: Self.focusDuration)
            withAnimation(Motion.quick) { navigation.focusedSession = nil }
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

private struct FocusKey: Equatable {
    var session: UUID?
    var loaded: Bool
}

extension View {
    /// 通知定位到的会话：一圈强调色描边，片刻后消失。
    fileprivate func focusRing(_ on: Bool, radius: CGFloat) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.tint, lineWidth: 2)
                .opacity(on ? 1 : 0)
                .allowsHitTesting(false)
        }
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
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: title, count: count)
            VStack(spacing: 0) { content }.paper(radius: 16)
        }
    }
}

/// 等你确认：橙色提示卡，写明问题、等了多久、需要在 Mac 上回应。
private struct WaitingCard: View {
    let session: PiSessionState
    let project: Project?
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PiDot(state: session.state)
                Text("\(session.title) 等你确认").font(.headline).foregroundStyle(palette.ink)
                Spacer(minLength: 8)
                PiElapsed(session: session)
            }
            if let detail = session.detail, !detail.isEmpty {
                Text(detail).font(.body).foregroundStyle(palette.ink).fixedSize(horizontal: false, vertical: true)
            }
            Text([project?.name, "去 Mac 上回应"].compactMap { $0 }.joined(separator: " · "))
                .font(.footnote).foregroundStyle(palette.ink3)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.attention.opacity(palette.dark ? 0.16 : 0.1), in: .rect(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(palette.attention.opacity(palette.highContrast ? 0.8 : 0.35)))
        .accessibilityElement(children: .combine)
    }
}

/// 一个会话：状态点、名称、所属项目、状态与细节、进入当前状态多久。点一下进所属项目。
private struct SessionRow: View {
    let session: PiSessionState
    let project: Project?
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette

    var body: some View {
        Button {
            if let project { navigation.show(project: project.id, workspace: workspace) }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.title).font(.headline).foregroundStyle(palette.ink).lineLimit(1)
                    Spacer(minLength: 8)
                    PiElapsed(session: session)
                }
                HStack(spacing: 6) {
                    PiDot(state: session.state, size: 6)
                    PiActivityLine(text: PiActivityLine.join(project?.name, session.state.label), font: .subheadline)
                        .foregroundStyle(palette.ink2)
                }
                if let detail = session.detail, !detail.isEmpty {
                    Text(detail).font(.footnote.monospaced()).foregroundStyle(palette.ink3).lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(RowPressStyle())
        .disabled(project == nil)
        .accessibilityElement(children: .combine)
        .accessibilityHint(project == nil ? "" : "打开项目 \(project?.name ?? "")")
    }
}

/// 会话在当前状态里待了多久："已运行 0:42"（干活中）或"已等 1:07"（等你确认）；空闲不显示。
struct PiElapsed: View {
    let session: PiSessionState
    @Environment(\.palette) private var palette

    var body: some View {
        switch session.state.known {
        case .waitingForUser:
            Text("已等 \(Text(session.stateSince, style: .timer))").font(.footnote.monospacedDigit()).foregroundStyle(palette.attention)
        case .thinking, .outputting, .tool:
            Text("已运行 \(Text(session.stateSince, style: .timer))").font(.footnote.monospacedDigit()).foregroundStyle(palette.ink3)
        default:
            EmptyView()
        }
    }
}

/// 一条发到 Mac 的请求：等 Mac 接手 → 正在发送 → 已送达 / 失败（原因、重试）。
private struct DeliveryRow: View {
    let request: DeliveryRequest
    let live: PiSessionState?
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(CardText(request.content).title.nonEmpty ?? "图片").font(.body).foregroundStyle(palette.ink).lineLimit(1)
                Spacer(minLength: 8)
                DeliveryStatusLabel(status: request.status)
            }
            Text("\(DateLabel.short(request.createdAt)) → \(request.target.name) · \(request.mode.label)")
                .font(.footnote).foregroundStyle(palette.ink3).lineLimit(1)
            if request.status == .known(.failed) {
                if let reason = request.resultDetail { Text(reason).font(.footnote).foregroundStyle(palette.failure) }
                HStack(spacing: 10) {
                    if live != nil {
                        Button("重试", systemImage: "arrow.clockwise") { retry() }
                    }
                    Button("移除", systemImage: "xmark", role: .destructive) { remove() }
                }
                .font(.subheadline.weight(.medium))
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .contextMenu {
            if live != nil { Button("再发一次", systemImage: "paperplane") { retry() } }
            Button("移除", systemImage: "xmark", role: .destructive) { remove() }
        }
    }

    private func retry() {
        navigation.outbox = Navigation.Outbox(
            content: request.content, card: request.cardID, task: request.taskID, session: request.target.ref, project: nil)
    }

    private func remove() {
        let id = request.id
        workspace.perform { try await $0.deleteDelivery(id) }
    }
}

struct DeliveryStatusLabel: View {
    let status: Open<DeliveryStatus>
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            switch status {
            case .known(.pending): Label("等 Mac 接手", systemImage: "clock").foregroundStyle(palette.ink2)
            case .known(.executing):
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("正在发送") }.foregroundStyle(palette.ink2)
            case .known(.succeeded): Label("已送达", systemImage: "checkmark.circle.fill").foregroundStyle(palette.ink2)
            case .known(.failed): Label("失败", systemImage: "exclamationmark.triangle.fill").foregroundStyle(palette.failure)
            case .unknown: Label("未知状态", systemImage: "questionmark.circle").foregroundStyle(palette.ink2)
            }
        }
        .font(.footnote.weight(.medium))
        .id(status)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
        .animation(Motion.quick, value: status)
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
        navigation.outbox = Navigation.Outbox(
            content: record.content, card: record.cardID, task: record.taskID, session: record.targetRef, project: nil)
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
