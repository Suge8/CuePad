import CueStore
import CueSync
import SwiftUI

/// 会话页的回复框（iOS 与 Mac 同一份）：共用的 `Composer`，去处是这个 Pi 会话（＋ 选卡片与图片）。
/// 右下角只有一颗主按钮，此刻是哪种只看 `MacDelivery.button`：空着而 Agent 自己在跑一轮是停止；写了字是发送——
/// Pi 空闲时直接发，正忙时点按（⌘↩）等它做完再说、长按（⌘⇧↩）马上说，停止也在长按菜单里；文字型问题是作答。
/// 等你确认时按问题类型：文字型问题它就是作答框（只收文字）；选择、确认型收成一行"先在上面作答"，
/// 这里答不了的写明要去哪回答——都不发自由文本（Pi 不答完题不会去看，消息会一直挂着）。
/// 停止发出后到这一轮歇下前转圈"正在停止"，进度只读投送请求（`MacDelivery.stopping`，页面传进来）。
/// 排队的话（`PiChat.queued`）在它那块玻璃的上部（`PiQueueStack`），手机上聚焦时收成一行。键盘：`ReplyShortcut`（⌘↩、⌘⇧↩、⌘⇧M 模型、⌘⇧E 思考强度、空着按 ↑ 调回上一句）。
/// 同步到不了 Mac 时不能发，聚焦后写明原因。两端都写一条投送请求给会话所在的 Mac（本机的由本机执行器送达），
/// 发出后清空，请求马上贴到对话末尾。形态（`form`）：Mac 一直是两层（上面文字区，下面 ＋、模型与思考强度、发送），失焦也不收；
/// 手机空着没聚焦时一行，在线会话聚焦就展开（已结束的没有工具排，打了字再长），在看历史时收成短胶囊（停止钮在时不收）。
/// Mac 上打开即聚焦、发出后焦点留着接着写；手机发出后收起键盘。
struct PiReplyBar: View {
    let session: PiSessionState
    /// 模型与思考强度的显示值（在线会话放在工具排"＋"的右边）。
    let config: PiConfigShown?
    /// 在看历史：收成短胶囊（只有手机这样）。
    var compact = false
    /// 停止请求已发出、这一轮还没歇下（`MacDelivery.stopping`）。
    let stopping: Bool
    /// 最近一条斜杠命令的进度（`MacDelivery.commandProgress`，页面传进来）：在路上与没成功时在回复框上方短暂显示一行，成功就消失。
    var commandProgress: MacDelivery.CommandProgress?
    /// 排队的话（`PiChat.queued`，页面传进来）。
    var queued: [DeliveryRequest] = []
    /// 空着按 ↑ 调回的那一句（`PiChat.lastSaid`）。
    var recall: String?
    /// 发出之后（会话页回到最新）。
    let sent: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.pageActive) private var active
    @State private var sending = false
    @State private var sentCount = 0
    @FocusState private var focused: Bool
    /// ⌘⇧M、⌘⇧E 请模型或思考强度弹出菜单（Mac）。
    @State private var opening: PiConfigPick?

    /// 回复框的草稿（每个会话一份，`AppSettings.replyDraft`）只在回复框里读写：会话页不经手它，
    /// 打字时只有回复框（与列表里那一行）重算，会话页、对话都不动。
    private var draft: ComposerDraft {
        get { services.settings.replyDraft(for: session.id) }
        nonmutating set { services.settings.setReplyDraft(newValue, for: session.id) }
    }

    /// 工具排（模型与思考强度）只给在线会话：已结束的不为换模型去唤醒 Pi。
    private var hasTools: Bool { config != nil && session.state != .known(.ended) && !session.models.isEmpty }

    private var form: ComposerForm {
        #if os(macOS)
        .open
        #else
        compact && !canStop ? .capsule(opensOnFocus: hasTools) : .line(opensOnFocus: hasTools)
        #endif
    }

    private var reply: PiReply { MacDelivery.reply(to: session) }

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
    private var button: PiReplyButton? { MacDelivery.button(for: session, hasDraft: hasDraft, command: commandLine != nil) }

    /// 与输入框同一个圆角（贴在它上方的问题卡、收成一行的说明用）。
    static let radius = ComposerMetrics.radius

    var body: some View {
        switch reply {
        case .answerAbove: notice("先在上面作答", systemImage: "arrow.up")
        case .unanswerable: notice(Self.unanswerable, systemImage: "desktopcomputer")
        // 怎么接上在顶上的玻璃标题里（点它看说明，`PiShown.explanation`），这里不重复
        case .restartPi: notice("这个会话现在发不了", systemImage: "nosign")
        case .message, .answer:
            VStack(alignment: .leading, spacing: 6) {
                if let commandProgress { progressLine(commandProgress) }
                composer
            }
            .animation(Motion.quick, value: queued.map(\.id))
        }
    }

    private var composer: some View {
            Composer(
                draft: services.settings.replyDraftBinding(for: session.id), prompt: compact ? replyPrompt : placeholder, label: "回复", focus: $focused, accepts: accepts,
                cardsFrom: session.projectID, form: form, submitsEmpty: canStop, keepsHeader: !queued.isEmpty,
                commands: answering == nil ? session.commands : [], shortcuts: shortcuts, recall: recall,
                header: {
                    if !compact, !queued.isEmpty { PiQueueStack(requests: queued, folded: Self.foldsQueue && focused) }
                    if !reachable { SyncHint(status: services.syncStatus).padding(.horizontal, 18).padding(.top, 12) }
                    if form == .open || focused, let failure = config?.failure {
                        Text("没换成：\(failure)").font(Typography.caption).foregroundStyle(palette.failure).lineLimit(2)
                            .padding(.horizontal, 18).padding(.top, 12)
                    }
                },
                tools: {
                    if hasTools, let config { PiConfigControls(session: session, shown: config, opening: $opening) }
                },
                send: { sendControl }
            )
            .sensoryFeedback(.success, trigger: sentCount)
            #if os(macOS)
            .onAppear { focused = active }
            #endif
    }

    /// 命令的进度行：不是你说的话，不进对话；在路上转圈，没成功写原因。
    private func progressLine(_ progress: MacDelivery.CommandProgress) -> some View {
        HStack(spacing: 6) {
            if case .running = progress { Spinner(.mini) }
            Text(progress.text).lineLimit(2)
        }
        .font(Typography.meta).foregroundStyle(progress.failed ? palette.failure : palette.ink3)
        .padding(.horizontal, 18)
        .transition(.opacity)
    }

    #if os(iOS)
    /// 聚焦时排队的话收成一行：键盘已占了半屏，对话不能再被挤走（Mac 不收）。
    private static let foldsQueue = true
    private static let unanswerable = "这个问题要在 Mac 上回答"
    private static let hold = "长按"
    /// 钮上方那一句：怎么用另一种说法。
    private static let holdChip = "长按可"
    #else
    private static let foldsQueue = false
    private static let unanswerable = "这个问题要在终端里的 Agent 那边回答"
    private static let hold = "按住或 \(ReplyShortcut.sendHeld.symbols) "
    /// Mac 的浮签只写快捷键：与"按住"并写会长到盖住输入的字
    private static let holdChip = "\(ReplyShortcut.sendHeld.symbols) "
    #endif

    /// 键盘快捷键（`ReplyShortcut`）此刻做什么：⌘↩ 同点按主按钮、⌘⇧↩ 同长按；⌘⇧M、⌘⇧E 在有工具排时打开模型、思考强度菜单（按键只在文字区聚焦时到这里）。
    private var shortcuts: [ReplyShortcut: () -> Void] {
        var map: [ReplyShortcut: () -> Void] = [:]
        switch button {
        case .answer: map[.send] = answer
        case .send(let tap, let hold):
            map[.send] = { send(tap) }
            map[.sendHeld] = { send(hold, held: tap != hold) }
        case .stop, nil: break
        }
        #if os(macOS)
        if hasTools {
            map[.model] = { opening = .model }
            map[.thinking] = { opening = .thinking }
        }
        #endif
        return map
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
            .font(Typography.secondary).foregroundStyle(palette.ink2)
            .padding(.horizontal, 18).frame(maxWidth: .infinity, minHeight: 2 * Self.radius, alignment: .leading)
            .glass(in: .rect(cornerRadius: Self.radius, style: .continuous))
    }

    @ViewBuilder private var sendControl: some View {
        switch button {
        case .stop:
            Button(action: stop) { StopGlyph(stopping: stopping) }
                .buttonStyle(.plain)
                .disabled(stopping || !reachable)
                .accessibilityLabel(stopping ? "正在停止" : DeliveryMode.stop.label)
        case .answer:
            Button(action: answer) { SubmitGlyph(.send, enabled: canSend) }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("回答")
        case .send(let tap, let hold) where hold != tap:
            holdMenu(tap: tap, hold: hold)
        case .send(let tap, _):
            Button { send(tap) } label: { SubmitGlyph(.send, enabled: canSend) }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("发送")
        case nil:
            EmptyView()
        }
    }

    /// Agent 在跑时的发送钮：点按 `tap`（等它做完再说），长按出菜单选 `hold`（马上说）或停止。
    private func holdMenu(tap: DeliveryMode, hold: DeliveryMode) -> some View {
        Menu {
            Button { send(hold, held: true) } label: {
                Label(hold.label, systemImage: Self.symbol(hold))
                if let explanation = hold.explanation { Text(explanation) }
            }
            if canStop, !stopping {
                Divider()
                Button(DeliveryMode.stop.label, systemImage: "stop.circle", role: .destructive, action: stop)
            }
        } label: {
            SubmitGlyph(.send, enabled: canSend)
        } primaryAction: {
            send(tap)
        }
        .menuStyle(.button).menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(!canSend)
        // 按住的菜单看不见：有字可发时在钮上方浮一句"长按可马上说"，用过一次（菜单或 ⌘⇧↩）就不再出（`holdSendLearned`）。
        // 浮层不占排版，出现时不挤动文字
        .overlay(alignment: .bottomTrailing) {
            // 斜杠命令不是说的话，"马上说"用不上：输入以 / 开头时不出
            if canSend, !services.settings.holdSendLearned, !draft.text.hasPrefix("/") {
                Text(Self.holdChip + hold.label).font(.caption2.weight(.medium)).foregroundStyle(palette.ink2)
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
        .accessibilityLabel(tap.label)
        .accessibilityHint([tap.explanation, "\(Self.hold)可以\(hold.label)"].compactMap { $0 }.joined(separator: "；"))
    }

    /// 按住发送钮出来的其余说法的图标。
    private static func symbol(_ mode: DeliveryMode) -> String {
        switch mode {
        case .steer: "bolt"
        default: "paperplane"
        }
    }

    /// 占位只说这里写什么；忙时点发送与长按各是什么由发送钮自己说（读屏标签与长按菜单）。
    private var placeholder: String {
        if answering != nil { return "回答上面的问题" }
        if !draft.attachments.isEmpty || !draft.images.isEmpty { return "补一句（可不填）" }
        return replyPrompt
    }

    /// 回给这个会话的那句占位：已结束的会话也能接着说——发出后它所在的 Mac 先在后台把它唤醒再送达，占位写明这一步，
    /// 不让人以为发给了一个没人接的会话。
    private var replyPrompt: String {
        session.state == .known(.ended) ? "唤醒 \(session.title) 接着说" : "回复 \(session.title)"
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

    /// 斜杠命令走投送方式 `command`（由 Pi 展开执行），不分马上说还是等它做完再说（`MacDelivery.button`）。
    /// `held`：用的是长按那一种（菜单或 ⌘⇧↩），之后不再提示。
    private func send(_ mode: DeliveryMode, held: Bool = false) {
        if held { services.settings.holdSendLearned = true }
        let outgoing = draft, line = commandLine
        guard canSend else { return }
        sending = true
        workspace.attempt {
            defer { sending = false }
            if mode == .command, let line {
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
        Label { Text(Dotted(summary.title, consequence)) } icon: { Image(systemName: summary.symbol) }
            .font(Typography.meta).foregroundStyle(palette.ink3)
            .lineLimit(2)
    }
}

extension AppSettings {
    /// 回复框绑定的草稿（`replyDraft`，离开会话再回来还在）。
    func replyDraftBinding(for session: UUID) -> Binding<ComposerDraft> {
        Binding(get: { self.replyDraft(for: session) }, set: { self.setReplyDraft($0, for: session) })
    }
}
