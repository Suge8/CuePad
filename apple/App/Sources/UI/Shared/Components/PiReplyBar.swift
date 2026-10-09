import CueStore
import CueSync
import SwiftUI

/// 会话页的回复框（iOS 与 Mac 同一份）：共用的 `Composer`，去处是这个 Pi 会话（＋ 选卡片与图片；有内容时右下角出现圆形发送钮，⌘↩ 同发送钮）。
/// Pi 空闲时直接发；正忙时点发送钮是等它做完再说，长按选马上说；Mac 上开在终端里的还可只放进输入框（按住选）。可用的说法见 `MacDelivery.reply`。
/// 等你确认时按问题类型：文字型问题它就是作答框（只收文字）；选择、确认型收成一行"先在上面作答"，
/// 这里答不了的写明要去哪回答——都不发自由文本（Pi 不答完题不会去看，消息会一直挂着）。
/// Agent 自己在跑一轮时（`MacDelivery.canStop`）空着的回复框右边是"停止"——这时最可能想做的就是叫停（同 ChatGPT、Claude）；
/// 写了字就还是发送（想补充或改方向时停止反而打断），停止仍在按住发送钮的菜单里。停止发出后到这一轮歇下前转圈"正在停止"，
/// 进度只读投送请求（`MacDelivery.stopping`，页面传进来）。
/// 同步到不了 Mac 时不能发，聚焦后写明原因。两端都写一条投送请求给会话所在的 Mac（本机的由本机执行器送达），
/// 发出后清空，请求马上贴到对话末尾。Mac 上打开即聚焦、发出后焦点留着接着写；手机发出后收起键盘。
struct PiReplyBar: View {
    let session: PiSessionState
    /// 模型与思考强度的显示值（在线会话聚焦时放在工具排"＋"的右边）。
    let config: PiConfigShown?
    /// 在看历史：收成短胶囊。
    let compact: Bool
    /// 停止请求已发出、这一轮还没歇下（`MacDelivery.stopping`）。
    let stopping: Bool
    /// 发出之后（会话页回到最新）。
    let sent: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var sending = false
    @State private var sentCount = 0
    @FocusState private var focused: Bool

    /// 回复框的草稿（每个会话一份，`AppSettings.replyDraft`）只在回复框里读写：会话页不经手它，
    /// 打字时只有回复框（与列表里那一行）重算，会话页、对话都不动。
    private var draft: ComposerDraft {
        get { services.settings.replyDraft(for: session.id) }
        nonmutating set { services.settings.setReplyDraft(newValue, for: session.id) }
    }

    /// 工具排（模型与思考强度）只给在线会话：已结束的不为换模型去唤醒 Pi。没有工具时聚焦也不展开成两层。
    private var hasTools: Bool { config != nil && session.state != .known(.ended) && !session.models.isEmpty }

    private var reply: PiReply { MacDelivery.reply(to: session, hasImages: draft.hasImages) }

    /// 发消息时可用的方式：第一个是点发送的方式，其余在长按菜单里。
    private var modes: [DeliveryMode] {
        if case .message(let modes) = reply { modes } else { [] }
    }

    private var answering: PiQuestion? {
        if case .answer(let question) = reply { question } else { nil }
    }

    private var accepts: ComposerKinds { answering == nil ? [.images, .cards] : [] }
    private var reachable: Bool { services.reachesPiHost }
    private var hasDraft: Bool { !draft.isEmpty(accepting: accepts) }
    private var canSend: Bool { hasDraft && reachable && !sending }
    private var canStop: Bool { MacDelivery.canStop(session) }
    /// 输入框里是一条已知的斜杠命令时要发出的整行（`PiSlash.line`）。
    private var commandLine: String? { answering == nil ? PiSlash.line(of: draft, in: session.commands) : nil }

    /// 单行时是胶囊：高 = 字行 + 上下各 14，发送钮 36 居中。
    private static let radius: CGFloat = 25

    var body: some View {
        switch reply {
        case .answerAbove: notice("先在上面作答", systemImage: "arrow.up")
        case .unanswerable: notice(Self.unanswerable, systemImage: "desktopcomputer")
        case .restartPi: notice("旧版扩展的会话发不了，在终端里执行 /reload 后再发", systemImage: "arrow.clockwise")
        case .message, .answer:
            Composer(
                draft: services.settings.replyDraftBinding(for: session.id), prompt: compact ? "回复 \(session.title)" : placeholder, label: "回复", focus: $focused, accepts: accepts,
                cardsFrom: session.projectID, compact: compact, showsSend: canStop, expandsOnFocus: hasTools,
                commands: answering == nil ? session.commands : [], submit: submit,
                header: {
                    if !reachable { SyncHint(status: services.syncStatus).padding(.horizontal, 18).padding(.top, 12) }
                    if focused, let failure = config?.failure {
                        Text("没换成：\(failure)").font(.caption).foregroundStyle(palette.failure).lineLimit(2)
                            .padding(.horizontal, 18).padding(.top, 12)
                    }
                },
                tools: {
                    if hasTools, let config { PiConfigControls(session: session, shown: config) }
                },
                send: { sendControl }
            )
            .sensoryFeedback(.success, trigger: sentCount)
            #if os(macOS)
            .onAppear { focused = true }
            #endif
        }
    }

    #if os(iOS)
    private static let unanswerable = "这个问题要在 Mac 上回答"
    private static let hold = "长按"
    #else
    private static let unanswerable = "这个问题要在终端里的 Agent 那边回答"
    private static let hold = "按住"
    #endif

    /// ⌘↩：同点发送钮（忙时是默认的那种说法）。
    private func submit() {
        if answering != nil { answer() } else if let mode = modes.first { send(mode) }
    }

    /// 发出后焦点去哪，两端只在这里分：手机收起键盘看对话；Mac 焦点留在回复框接着写。
    private func didSend() {
        #if os(iOS)
        focused = false
        #endif
        sentCount += 1
        sent()
    }

    /// 等你确认、不能发自由文本时收成的一行。
    private func notice(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline).foregroundStyle(palette.ink2)
            .padding(.horizontal, 18).frame(maxWidth: .infinity, minHeight: 2 * Self.radius, alignment: .leading)
            .glass(in: .rect(cornerRadius: Self.radius, style: .continuous))
    }

    @ViewBuilder private var sendControl: some View {
        if canStop, !hasDraft {
            Button(action: stop) { StopGlyph(stopping: stopping) }
                .buttonStyle(.plain)
                .disabled(stopping || !reachable)
                .accessibilityLabel(stopping ? "正在停止" : DeliveryMode.stop.label)
        } else if answering != nil {
            Button(action: answer) { SubmitGlyph(.send, enabled: canSend) }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("回答")
        } else if let first = modes.first, modes.count > 1, commandLine == nil {
            let others = modes.dropFirst()
            Menu {
                ForEach(Array(others), id: \.self) { mode in
                    Button { send(mode) } label: {
                        Label(mode.label, systemImage: Self.symbol(mode))
                        if let explanation = mode.explanation { Text(explanation) }
                    }
                }
                if canStop, !stopping {
                    Divider()
                    Button(DeliveryMode.stop.label, systemImage: "stop.circle", role: .destructive, action: stop)
                }
            } label: {
                SubmitGlyph(.send, enabled: canSend)
            } primaryAction: {
                send(first)
            }
            .menuStyle(.button).menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(!canSend)
            // 按住的菜单看不见：有字可发时在钮上方浮一句"长按可马上说"，用过一次菜单就不再出（`holdSendLearned`）。
            // 浮层不占排版，出现时不挤动文字
            .overlay(alignment: .bottomTrailing) {
                if canSend, !services.settings.holdSendLearned, let other = others.first {
                    Text("\(Self.hold)可\(other.label)").font(.caption2.weight(.medium)).foregroundStyle(palette.ink2)
                        .padding(.horizontal, 8).frame(height: 22)
                        .glass(in: .capsule)
                        .fixedSize()
                        .offset(y: -48)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .animation(Motion.quick, value: canSend)
            .accessibilityLabel(first.label)
            .accessibilityHint(([first.explanation] + others.map { "\(Self.hold)可以\($0.label)" }).compactMap { $0 }.joined(separator: "；"))
        } else {
            Button { if let mode = modes.first { send(mode) } } label: { SubmitGlyph(.send, enabled: canSend) }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("发送")
        }
    }

    /// 按住发送钮出来的其余说法的图标。
    private static func symbol(_ mode: DeliveryMode) -> String {
        switch mode {
        case .steer: "bolt"
        case .paste: "text.cursor"
        default: "paperplane"
        }
    }

    /// 占位只说这里写什么；忙时点发送与长按各是什么由发送钮自己说（读屏标签与长按菜单）。
    private var placeholder: String {
        if answering != nil { return "回答上面的问题" }
        if !draft.attachments.isEmpty || !draft.images.isEmpty { return "补一句（可不填）" }
        return "回复 \(session.title)"
    }

    private func answer() {
        let value = PiAnswerValue.text(draft.text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard canSend else { return }
        sending = true
        workspace.attempt {
            defer { sending = false }
            _ = try await services.answer(value, to: session)
            draft.text = ""
            didSend()
        }
    }

    /// 停止这一轮：写一条停止请求，等 Mac 受理；没受理（不在线、出错）时提示原因。受理之后转圈到这一轮歇下（看状态）。
    private func stop() {
        let session = session
        workspace.attempt {
            let request = try await services.stop(session)
            if let failure = try await services.outcome(of: request.id).failure { throw SendError.notDelivered(failure) }
        }
    }

    /// 斜杠命令走投送方式 `command`（由 Pi 展开执行），不分马上说还是等它做完再说。
    private func send(_ mode: DeliveryMode) {
        if mode != modes.first { services.settings.holdSendLearned = true }
        let outgoing = draft, line = commandLine
        guard canSend else { return }
        sending = true
        workspace.attempt {
            defer { sending = false }
            if let line {
                _ = try await services.requestMacDelivery(line, to: session, mode: .command, card: outgoing.attachments.first?.card)
            } else {
                _ = try await services.requestMacDelivery(outgoing, to: session, mode: mode)
            }
            draft = ComposerDraft()
            didSend()
        }
    }
}

/// 同步到不了 Mac 时的一句提示（Agent 页同步图标点开、会话回复框上、新会话）：哪里不通；详情与处理在设置里。
struct SyncHint: View {
    let status: SyncStatus
    /// 这对眼前的事意味着什么：浮起的输入框里只关心发不发得出去。
    var consequence = "看到的可能不是最新，也发不到 Mac"
    @Environment(\.palette) private var palette

    var body: some View {
        let summary = SyncSummary(status)
        Label("\(summary.title) · \(consequence)", systemImage: summary.symbol)
            .font(.footnote).foregroundStyle(palette.ink3)
            .lineLimit(2)
    }
}

extension AppSettings {
    /// 回复框绑定的草稿（`replyDraft`，离开会话再回来还在）。
    func replyDraftBinding(for session: UUID) -> Binding<ComposerDraft> {
        Binding(get: { self.replyDraft(for: session) }, set: { self.setReplyDraft($0, for: session) })
    }
}
