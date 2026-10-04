import CueStore
import CueText
import SwiftUI

/// 一个 Pi 会话的近况一次读取的数据：会话记录、它所在的项目、发给它的请求（先发的在前）。
/// 会话记录没了（结束 7 天后删除）时 `session` 为 nil；`sessionID` 由调用方带上，发给它的请求照样读得到。
nonisolated struct SessionDigest: Sendable, Equatable {
    var session: PiSessionState?
    var project: Project?
    var deliveries: [DeliveryRequest]

    static func read(_ id: UUID, sessionID: String?, from store: isolated CueStore) throws -> SessionDigest {
        let session = try store.piSessionStates().first { $0.id == id }
        let ref = session?.sessionID ?? sessionID
        return SessionDigest(
            session: session,
            project: try session?.projectID.flatMap { try store.project($0) },
            deliveries: try store.deliveryRequests()
                .filter { $0.target.kind == .known(.piSession) && $0.target.ref == ref }
                .sorted { $0.createdAt < $1.createdAt })
    }
}

/// 会话近况（iOS 的会话页、Mac 侧栏的会话详情共用）：顶部是会话名、在哪、状态，出错时的原因与等你确认的问题；
/// 然后是最近一轮（你最后说的、它最后答的），最后是你发过去的请求与送达情况。回复框由各平台放在它下面。
struct PiSessionDigest: View {
    let session: PiSessionState
    let project: Project?
    let deliveries: [DeliveryRequest]
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            DigestHeader(session: session, project: project)
            RecentRound(session: session)
            if !deliveries.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    DigestLabel(text: "你发过去的")
                    VStack(spacing: 0) {
                        ForEach(Array(deliveries.enumerated()), id: \.element.id) { index, request in
                            if index > 0 { Divider().padding(.leading, 16) }
                            DeliveryRow(request: request, session: session.state == .known(.ended) ? nil : session)
                                .id(request.id)
                        }
                    }
                    .paper(radius: 16)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Motion.quick, value: deliveries.map(\.id))
        .animation(Motion.quick, value: deliveries.map(\.status))
    }
}

/// 小节标题：与项目页的分段标题同一种写法。
private struct DigestLabel: View {
    let text: String
    @Environment(\.palette) private var palette

    var body: some View {
        Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(palette.ink2)
            .padding(.horizontal, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct DigestHeader: View {
    let session: PiSessionState
    let project: Project?
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title).font(.title2.weight(.bold)).foregroundStyle(palette.ink)
                HStack(spacing: 6) {
                    PiStateDot(state: session.state, size: 6)
                    PiActivityLine(lead: [PiPlace.name(of: session, project: project), session.state.label], font: .subheadline)
                        .foregroundStyle(palette.ink2)
                    Spacer(minLength: 8)
                    PiElapsed(session: session)
                }
                .accessibilityElement(children: .combine)
                if session.state.isWorking, let detail = session.detail, !detail.isEmpty {
                    PiActivityLine(detail: detail, detailIsCode: session.detailIsCode).foregroundStyle(palette.ink3)
                }
            }
            switch session.state.known {
            case .waitingForUser:
                // 问题原文照抄（含换行与选项），是此刻最需要看的东西
                Callout(tint: palette.attention, title: "等你确认", text: session.question ?? session.detail ?? "")
            case .error:
                Callout(tint: palette.failure, title: "出错", text: session.detail ?? "Mac 没有说明原因")
            default:
                EmptyView()
            }
        }
    }
}

/// 有色调的提示块：等你确认（注意色）、出错（失败色）。
private struct Callout: View {
    let tint: Color
    let title: String
    let text: String
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(tint)
            if !text.isEmpty {
                Text(text).font(.body).foregroundStyle(palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(palette.dark ? 0.16 : 0.1), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(tint.opacity(palette.highContrast ? 0.8 : 0.3)))
        .accessibilityElement(children: .combine)
    }
}

/// 最近一轮：你最后说的、它最后答的。回答较长时先收起（约一屏内），可展开。
private struct RecentRound: View {
    let session: PiSessionState
    @Environment(\.palette) private var palette
    @State private var expanded = false

    /// 收起时回答显示的行数；超过这么多行（或字数）才给"展开"。
    private static let collapsedLines = 8
    private static let collapsedCharacters = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DigestLabel(text: "最近一轮")
            VStack(alignment: .leading, spacing: 14) {
                if session.lastPrompt == nil && session.lastReply == nil {
                    Text("还没有近况。Pi 回答之后，这里会显示你最后问的和它最后答的。")
                        .font(.subheadline).foregroundStyle(palette.ink3)
                }
                if let prompt = session.lastPrompt {
                    turn("你说", prompt)
                }
                if let reply = session.lastReply {
                    let long = reply.count > Self.collapsedCharacters
                        || reply.split(separator: "\n", omittingEmptySubsequences: false).count > Self.collapsedLines
                    VStack(alignment: .leading, spacing: 6) {
                        turn("Pi 答", reply, lineLimit: long && !expanded ? Self.collapsedLines : nil)
                        if long {
                            Button(expanded ? "收起" : "展开全文") { withAnimation(Motion.quick) { expanded.toggle() } }
                                .font(.subheadline.weight(.medium))
                                .frame(minHeight: 44)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paper(radius: 16)
        }
    }

    private func turn(_ who: String, _ text: String, lineLimit: Int? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(who).font(.caption.weight(.semibold)).foregroundStyle(palette.ink3)
            Text(text).font(.body).foregroundStyle(palette.ink)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 发给会话的一条请求（会话页与活动页共用，送达情况只在这里写）：内容、方式、送达中 / 已送达多久 / 没能送达与原因。
/// 失败时可以重发（会话还在时）或移除。
struct DeliveryRow: View {
    let request: DeliveryRequest
    /// 还能发给它的会话；nil 时不给重发。
    let session: PiSessionState?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                let title = CardText(request.content).title
                Text(title.isEmpty ? "图片" : title).font(.body).foregroundStyle(palette.ink).lineLimit(2)
                Spacer(minLength: 8)
                DeliveryStatusLabel(request: request)
            }
            Text("\(DateLabel.short(request.createdAt)) · \(request.mode.label)")
                .font(.footnote).foregroundStyle(palette.ink3).lineLimit(1)
            if request.status == .known(.failed) {
                if let reason = request.resultDetail { Text(reason).font(.footnote).foregroundStyle(palette.failure) }
                HStack(spacing: 10) {
                    if session != nil { Button("重发", systemImage: "arrow.clockwise", action: retry) }
                    Button("移除", systemImage: "xmark", role: .destructive, action: remove)
                }
                .font(.subheadline.weight(.medium))
                .buttonStyle(.bordered)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .transition(.opacity)
        .contextMenu {
            if session != nil { Button("再发一次", systemImage: "paperplane", action: retry) }
            Button("移除", systemImage: "xmark", role: .destructive, action: remove)
        }
    }

    /// 同样的内容与方式再发一次；新请求写成后移除这条失败的。
    private func retry() {
        guard let session else { return }
        let old = request
        workspace.attempt {
            _ = try await workspace.services.requestMacDelivery(
                old.content, to: session, mode: old.mode.known ?? .followUp, card: old.cardID, task: old.taskID)
            try await workspace.services.store.deleteDelivery(old.id)
        }
    }

    private func remove() {
        let id = request.id
        workspace.perform { try await $0.deleteDelivery(id) }
    }
}

/// 请求的送达情况：送达中（等 Mac 接手与正在发送都算）、已送达（往返多久）、没能送达。
struct DeliveryStatusLabel: View {
    let request: DeliveryRequest
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            switch request.status {
            case .known(.pending), .known(.executing):
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("送达中") }.foregroundStyle(palette.ink2)
            case .known(.succeeded):
                Label(request.roundTrip.map { "已送达 · \(Self.text($0))" } ?? "已送达", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(palette.ink2)
            case .known(.failed): Label("没能送达", systemImage: "exclamationmark.triangle.fill").foregroundStyle(palette.failure)
            case .unknown: Label("未知状态", systemImage: "questionmark.circle").foregroundStyle(palette.ink2)
            }
        }
        .font(.footnote.weight(.medium))
        .id(request.status)
        .transition(.opacity)
        .animation(Motion.quick, value: request.status)
    }

    /// 往返时间："3 秒"、"2 分"。
    static func text(_ duration: Duration) -> String {
        let seconds = Int(duration.components.seconds)
        return seconds < 60 ? "\(max(seconds, 1)) 秒" : "\(seconds / 60) 分"
    }
}

/// 会话计时，读法见 `PiClock`："已运行 0:42"、"已等 1:07"、"5 分钟前"。
struct PiElapsed: View {
    let clock: PiClock
    var font: Font = .footnote
    @Environment(\.palette) private var palette

    init(session: PiSessionState, font: Font = .footnote) {
        self.init(state: session.state, stateSince: session.stateSince, busySince: session.busySince, font: font)
    }

    init(state: Open<PiWorkState>, stateSince: Date, busySince: Date?, font: Font = .footnote) {
        clock = PiClock.reading(state, stateSince: stateSince, busySince: busySince)
        self.font = font
    }

    var body: some View {
        switch clock {
        case .waiting(let since):
            Text("已等 \(Text(since, style: .timer))").font(font.monospacedDigit()).foregroundStyle(palette.attention)
        case .running(let since):
            Text("已运行 \(Text(since, style: .timer))").font(font.monospacedDigit()).foregroundStyle(palette.ink3)
        case .ago(let date):
            Text(date, format: .relative(presentation: .named)).font(font).foregroundStyle(palette.ink3)
        }
    }
}
