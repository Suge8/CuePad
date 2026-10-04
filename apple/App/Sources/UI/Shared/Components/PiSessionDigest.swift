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

/// 会话近况（iOS 的会话页、Mac 侧栏的会话详情共用）：状态块（名字、状态、在哪、进度；等你确认的问题最醒目，
/// 出错写原因），然后是最近一轮——你说的一行（弱化）与 Pi 答的全文（较长时折起）。已结束的整页更淡但可读。
/// 发过去的请求（`DeliveryStack`）与回复框由各平台放在它下面。
struct PiSessionDigest: View {
    let session: PiSessionState
    let project: Project?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StatusBlock(session: session, project: project)
            RecentRound(session: session)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(session.state == .known(.ended) ? 0.75 : 1)
    }
}

/// 状态块：状态是第一视觉变量（状态标 + 带色的状态词），名字与时长其次，在哪与进度再次。
private struct StatusBlock: View {
    let session: PiSessionState
    let project: Project?
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.title).font(.title2.weight(.bold)).foregroundStyle(palette.ink).lineLimit(2)
                    Spacer(minLength: 8)
                    PiElapsed(session: session)
                }
                HStack(spacing: 6) {
                    PiStateDot(state: session.state, size: 8)
                    Text(session.state.label).font(.subheadline.weight(.semibold)).foregroundStyle(session.state.tint(palette))
                    if let place = PiPlace.name(of: session, project: project) {
                        Text("· \(place)").font(.subheadline).foregroundStyle(palette.ink3).lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
                if session.state.isWorking, let action = PiProgress.line(of: session) {
                    Text(action).font(session.detailIsCode ? .subheadline.monospaced() : .subheadline).foregroundStyle(palette.ink2).lineLimit(2)
                }
            }
            switch session.state.known {
            case .waitingForUser:
                // 问题原文照抄（含换行与选项），是这一页最醒目的东西
                Callout(tint: palette.attention, title: "等你确认", text: session.question ?? session.detail ?? "", prominent: true)
            case .error:
                Callout(tint: palette.failure, title: "出错", text: session.detail ?? "Mac 没有说明原因", prominent: false)
            default:
                EmptyView()
            }
        }
    }
}

/// 有色调的提示块：等你确认（注意色，正文放大）、出错（失败色）。
private struct Callout: View {
    let tint: Color
    let title: String
    let text: String
    let prominent: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(tint)
            if !text.isEmpty {
                Text(text).font(prominent ? .title3.weight(.medium) : .body).foregroundStyle(palette.ink)
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

/// 最近一轮：上面一行弱化的"你说"（点开看全句），下面 Pi 答的全文；回答较长时先折起，可展开。
private struct RecentRound: View {
    let session: PiSessionState
    @Environment(\.palette) private var palette
    @State private var replyExpanded = false
    @State private var promptExpanded = false

    /// 收起时回答显示的行数；超过这么多行（或字数）才给"展开"。
    private static let collapsedLines = 8
    private static let collapsedCharacters = 320

    var body: some View {
        if session.lastPrompt == nil && session.lastReply == nil {
            Text("还没有近况。Pi 回答之后，这里会显示它最后答的。")
                .font(.subheadline).foregroundStyle(palette.ink3)
                .padding(.horizontal, 4)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                if let prompt = session.lastPrompt {
                    Button { withAnimation(Motion.quick) { promptExpanded.toggle() } } label: {
                        Text("你说：\(prompt)").font(.footnote).foregroundStyle(palette.ink3)
                            .lineLimit(promptExpanded ? nil : 1)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(promptExpanded ? "收起" : "展开全句")
                }
                if let reply = session.lastReply {
                    let long = reply.count > Self.collapsedCharacters
                        || reply.split(separator: "\n", omittingEmptySubsequences: false).count > Self.collapsedLines
                    VStack(alignment: .leading, spacing: 6) {
                        Text(reply).font(.body).foregroundStyle(palette.ink)
                            .lineLimit(long && !replyExpanded ? Self.collapsedLines : nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if long {
                            Button(replyExpanded ? "收起" : "展开全文") { withAnimation(Motion.quick) { replyExpanded.toggle() } }
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
}

/// 发过去的请求，贴在回复框上方：默认只有最新一条，更早的折成"更早 N 条"，点开在它上方列出。
struct DeliveryStack: View {
    let deliveries: [DeliveryRequest]
    /// 还能发给它的会话；nil 时不给重发。
    let session: PiSessionState?
    @Environment(\.palette) private var palette
    @State private var showsEarlier = false

    private static let earlierMaxHeight: CGFloat = 220

    var body: some View {
        if let latest = deliveries.last {
            let earlier = deliveries.dropLast()
            VStack(alignment: .leading, spacing: 0) {
                if !earlier.isEmpty {
                    Button(showsEarlier ? "收起更早的" : "更早 \(earlier.count) 条") { withAnimation(Motion.quick) { showsEarlier.toggle() } }
                        .font(.footnote.weight(.medium)).foregroundStyle(palette.ink3)
                        .padding(.horizontal, 16).frame(minHeight: 36)
                    if showsEarlier {
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(earlier) { request in
                                    DeliveryRow(request: request, session: session)
                                    Divider().padding(.leading, 16)
                                }
                            }
                        }
                        .frame(maxHeight: Self.earlierMaxHeight)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                    }
                }
                DeliveryRow(request: latest, session: session)
            }
            .paper(radius: 16)
            .animation(Motion.quick, value: deliveries.map(\.id))
        }
    }
}

/// 发给会话的一条请求（会话页里贴在回复框上方的那几条，送达情况只在这里写）：内容、方式、送达中 / 已送达多久 / 没能送达与原因。
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
