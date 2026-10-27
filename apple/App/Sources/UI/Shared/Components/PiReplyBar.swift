import CueStore
import SwiftUI

/// 会话页的回复框（iOS 与 Mac 同一份）：共用的 `Composer`，去处是这个 Agent 会话（＋ 选卡片与图片）。
/// 这个会话做不到的不露出（`AgentCapabilities`）：图片、停止、模型与思考强度、斜杠命令、作答，规则同 `MacDelivery`。
/// 右下角只有一颗主按钮，此刻是哪种只看 `MacDelivery.button`：空着而 Agent 自己在跑一轮是停止；写了字是发送（⌘↩）——
/// Agent 在跑时发出就打断这一轮、以这句开新一轮（占位写明）；文字型问题是作答。
/// 等你确认时按问题类型：文字型问题它就是作答框（只收文字）；选择、确认型收成一行"先在上面作答"，
/// 这里答不了的写明要去哪回答——都不发自由文本（Pi 不答完题不会去看，消息会一直挂着）。
/// 发出后空着、Agent 还没接过去时钮是发送中（`PiChat.sending`，同 Cue 页输入框）；停止发出后到这一轮歇下前转圈"正在停止"，进度只读投送请求（`MacDelivery.stopping`，页面传进来）。
/// 玻璃上部是随下一句发出的批注（`ReplyNoteStack`）。键盘：`ReplyShortcut`（⌘↩、⌘⇧M 模型、⌘⇧E 思考强度、空着按 ↑ 调回上一句）。
/// 同步到不了 Mac 时照样发：写下就排着，恢复后自动发出，同对 Cue 说的话（为什么不通只在同步那一处说）；停止要当场生效，那时停用。两端都经 `Workspace.speak` 写一条投送请求给会话所在的 Mac（本机的由本机执行器送达）：
/// 按下就清空输入框，请求马上贴到对话末尾，不等上传。形态（`form`）：Mac 一直是两层（上面文字区，下面 ＋、模型与思考强度、发送），失焦也不收；
/// 手机空着没聚焦时一行，有工具排的聚焦就展开，在看历史时收成短胶囊（停止钮在时不收）。
/// Mac 上打开即聚焦、发出后焦点留着接着写；手机发出后收起键盘。
struct PiReplyBar: View {
    let session: PiSessionState
    /// 模型与思考强度的显示值（在线会话放在工具排"＋"的右边）。
    let config: PiConfigShown?
    /// 可换的模型与能用的斜杠命令（`SessionDigest.catalog`）。
    let catalog: AgentCatalog?
    /// 在看历史：收成短胶囊（只有手机这样）。
    var compact = false
    /// 停止请求已发出、这一轮还没歇下（`MacDelivery.stopping`）。
    let stopping: Bool
    /// 斜杠命令的进度（`MacDelivery.commandProgress`，页面传进来）：在路上与没成功时在回复框上方叠一行（`composerNotice`），成功、之后有新请求或对话时就收起。
    var commandProgress: MacDelivery.CommandProgress?
    /// 你的话还在路上（`PiChat.sending`，页面传进来）：空着而 Agent 没在跑时，发送钮是发送中（同 Cue 页输入框）。
    var sending = false
    /// 空着按 ↑ 调回的那一句（`PiChat.lastSaid`）。
    var recall: String?
    /// 点批注一叠里的一条：回到原文（会话页给）。
    var revealNote: (ReplyNote) -> Void = { _ in }
    /// 发出之后（会话页回到最新）。
    let sent: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.pageActive) private var active
    @State private var sentCount = 0
    /// 刚发出、页面还没读到这句：库里那条请求要下一次读库才进 `sending`，这一小段钮先当帧换成发送中，不先缩没再长出来。
    /// 读到了（在路上，或 Agent 已经接过去开始跑）就交还给页面。
    @State private var launched = false
    @FocusState private var focused: Bool
    @Environment(\.panelCovered) private var covered
    /// ⌘⇧M、⌘⇧E 请模型或思考强度弹出菜单（Mac）。
    @State private var opening: PiConfigPick?

    /// 回复框的草稿（每个会话一份，`AppSettings.replyDraft`）只在回复框里读写：会话页不经手它，
    /// 打字时只有回复框（与列表里那一行）重算，会话页、对话都不动。
    private var draft: ComposerDraft {
        get { services.settings.replyDraft(for: session.id) }
        nonmutating set { services.settings.setReplyDraft(newValue, for: session.id) }
    }

    /// 工具排（模型与思考强度）：会话报过可换的模型就有，已结束的也有——换了由 Mac 在后台唤醒它再换。
    private var hasTools: Bool {
        config != nil && session.capabilities.contains(.model) && !models.isEmpty
    }

    private var form: ComposerForm {
        #if os(macOS)
        .open
        #else
        compact && !canStop ? .capsule(opensOnFocus: hasTools) : .line(opensOnFocus: hasTools)
        #endif
    }

    private var models: [PiModelOption] { catalog?.models ?? [] }

    private var reply: PiReply { MacDelivery.reply(to: session) }

    private var answering: PiQuestion? {
        if case .answer(let question) = reply { question } else { nil }
    }

    private var accepts: ComposerKinds { answering == nil ? session.composerKinds : [] }
    /// 输入 "/" 时弹出的命令（作答时不弹）。
    private var commands: [PiSlashCommand] { answering == nil ? session.usableCommands(in: catalog) : [] }
    private var reachable: Bool { services.reachesPiHost }
    private var hasDraft: Bool { !draft.isEmpty(accepting: accepts) }
    private var canSend: Bool { hasDraft && speakBlocked == nil }
    /// 这会儿说不了的原因（`PiSessionState.speakBlocked`）：发送钮的说明写全文，占位写短的（手机一行放不下全文），发送钮不可用；作答不是说话，不受它管。
    private var speakBlocked: String? { answering == nil ? session.speakBlocked : nil }
    private var canStop: Bool { session.canStop }
    private var shownSending: Bool { !hasDraft && !canStop && (launched || sending) }
    private var glyph: SendGlyph.Phase { canSend ? .ready : shownSending ? .sending : .idle }
    /// 输入框里是一条已知的斜杠命令时要发出的整行（`PiSlash.line`）。
    private var commandLine: String? { commands.isEmpty ? nil : PiSlash.line(of: draft, in: commands) }
    private var button: PiReplyButton? { MacDelivery.button(for: session, hasDraft: hasDraft, command: commandLine != nil) }

    /// 与输入框同一个圆角（贴在它上方的问题卡、收成一行的说明用）。
    static let radius = ComposerMetrics.radius

    var body: some View {
        switch reply {
        case .answerAbove: notice("先在上面作答", icon: .above)
        case .unanswerable: notice(Self.unanswerable, icon: .mac)
        case .message, .answer:
            composer.composerNotice(commandProgress != nil || expanded && config?.failure != nil) {
                if let commandProgress { progressLine(commandProgress) }
                if expanded { MacInputNotice(failure: config?.failure) }
            }
        }
    }

    /// 输入框展开着（一直展开、聚焦，或没收成短胶囊时带着草稿与批注）：这时才写发不出去、没换成的原因（同从前排在玻璃头部时）。
    private var expanded: Bool { form == .open || focused || !form.isCapsule && !draft.isEmpty(accepting: accepts.union(.notes)) }

    private var composer: some View {
            Composer(
                draft: box, prompt: compact ? replyPrompt : placeholder, label: "回复", focus: $focused, accepts: accepts,
                cardsFrom: session.projectID, form: form, submitsEmpty: canStop, showsSendEmpty: shownSending, keepsHeader: !draft.notes.isEmpty, tooled: hasTools,
                commands: commands, shortcuts: shortcuts, recall: recall,
                header: {
                    if !draft.notes.isEmpty { ReplyNoteStack(notes: draft.notes, reveal: revealNote, remove: removeNote) }
                },
                tools: {
                    if hasTools, let config { SessionConfigControls(session: session, models: models, shown: config, opening: $opening) }
                },
                send: { sendControl }
            )
            .sensoryFeedback(.success, trigger: sentCount)
            .onChange(of: sending) { launched = false }
            .onChange(of: canStop) { launched = false }
            .task { await DebugHooks.pressSendIfAsked(session: true) { shortcuts[.send]?() } }
            #if os(macOS)
            .onAppear { focused = active && !covered }
            #endif
    }

    /// 命令的进度行：不是你说的话，不进对话；在路上转圈，没成功写原因。
    private func progressLine(_ progress: MacDelivery.CommandProgress) -> some View {
        HStack(spacing: 6) {
            if case .running = progress { Spinner(.mini) }
            Text(progress.text).lineLimit(2)
        }
        .font(Typography.meta).foregroundStyle(progress.failed ? palette.failure : palette.ink3)
    }

    #if os(iOS)
    private static let unanswerable: LocalizedStringResource = "这个问题要在 Mac 上回答"
    #else
    private static let unanswerable: LocalizedStringResource = "这个问题要在终端里的 Agent 那边回答"
    #endif

    /// 键盘快捷键（`ReplyShortcut`）此刻做什么：⌘↩ 同点按主按钮；⌘⇧M、⌘⇧E 在有工具排时打开模型、思考强度菜单（按键只在文字区聚焦时到这里）。
    private var shortcuts: [ReplyShortcut: () -> Void] {
        var map: [ReplyShortcut: () -> Void] = [:]
        switch button {
        case .answer: map[.send] = answer
        case .send(let mode): map[.send] = { send(mode) }
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
    /// `talked`：发出的是说的话（命令有自己的进度行，钮不转发送中）。
    private func didSend(talked: Bool = true) {
        launched = talked
        #if os(iOS)
        focused = false
        #endif
        sentCount += 1
        sent()
    }

    /// 等你确认、不能发自由文本时收成的一行。
    private func notice(_ text: LocalizedStringResource, icon: Icon) -> some View {
        Label(text, icon: icon)
            .font(Typography.secondary).foregroundStyle(palette.ink2)
            .padding(.horizontal, 18).frame(maxWidth: .infinity, minHeight: 2 * Self.radius, alignment: .leading)
            .glass(in: .rect(cornerRadius: Self.radius, style: .continuous))
    }

    @ViewBuilder private var sendControl: some View {
        switch button {
        case .stop:
            Button(action: stop) { SendGlyph(stopping ? .stopping : .stop) }
                .buttonStyle(PressStyle(.button))
                .disabled(stopping || !reachable)
                .accessibilityLabel(stopping ? Text("正在停止") : Text(DeliveryMode.stop.label))
        case .answer:
            Button(action: answer) { SendGlyph(glyph) }
                .buttonStyle(PressStyle(.button))
                .disabled(!canSend)
                .accessibilityLabel("回答")
        case .send(let mode):
            Button { send(mode) } label: { SendGlyph(glyph) }
                .buttonStyle(PressStyle(.button))
                .disabled(!canSend)
                .accessibilityLabel("发送")
                .accessibilityHint(sendNote)
                .help(sendNote)
        case nil:
            EmptyView()
        }
    }

    /// 发出会打断 Agent 正在跑的这一轮（`MacDelivery`）：占位与发送钮的说明写明；打断不了的写说不了的原因。
    private var interrupts: Bool { session.state.known?.isTurnRunning == true }
    private static let interruptNote = String(localized: "会打断这一轮，以这句接着做")
    private static let blockedPrompt: LocalizedStringResource = "在终端里跑着：按 Esc 或等它做完"
    private var sendNote: String { speakBlocked ?? (interrupts ? Self.interruptNote : "") }

    /// 占位只说这里写什么；Agent 在跑时写明发出会打断它，打断不了时写原因。
    private var placeholder: LocalizedStringResource {
        if let answering { return answering.kind == .known(.select) ? "或写你自己的回答" : "回答上面的问题" }
        if speakBlocked != nil { return Self.blockedPrompt }
        if !draft.attachments.isEmpty || !draft.files.isEmpty { return "补一句（可不填）" }
        return interrupts ? "插话（会打断这一轮）" : replyPrompt
    }

    /// 回给这个会话的那句占位：已结束的会话也能接着说——发出后它所在的 Mac 先在后台把它唤醒再送达，占位写明这一步，
    /// 不让人以为发给了一个没人接的会话。
    private var replyPrompt: LocalizedStringResource {
        session.state == .known(.ended) ? "唤醒 \(session.title) 接着说" : "回复 \(session.title)"
    }

    /// 作答框只收文字：说出去的这句就是答案（`CueStore.speak`），答完文字清空，其余（别处带进草稿的卡片、附件）留着。
    private func answer() {
        guard canSend, answering != nil else { return }
        workspace.speak(to: .session(session, mode: .send), from: box, keeping: { var kept = $0; kept.text = ""; return kept }) { draft in
            draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        didSend()
    }

    private var box: Binding<ComposerDraft> { services.settings.replyDraftBinding(for: session.id) }

    /// 停止这一轮：写一条停止请求，等 Mac 受理；没受理（不在线、出错）时提示原因。受理之后转圈到这一轮歇下（看状态）。
    private func stop() {
        let session = session
        workspace.attempt {
            let request = try await services.stop(session)
            if let failure = try await services.store.outcome(of: request).failure { throw SendError.notDelivered(failure) }
        }
    }

    private func removeNote(_ note: ReplyNote) { services.settings.removeReplyNote(note.id, in: session.id) }

    /// 斜杠命令走投送方式 `command`（由 Agent 展开执行）：是不是命令只在发出这一刻按草稿与会话报的清单认
    /// （`commandLine`），不看按钮上次排版时带来的方式。
    private func send(_ mode: DeliveryMode) {
        guard canSend else { return }
        let accepts = accepts
        let card = draft.attachments.first?.card, command = commandLine
        if let line = command {
            // 命令不是说的话：批注留着，跟下一句发
            workspace.speak(to: .session(session, mode: .command, card: card), from: box, keeping: { ComposerDraft(notes: $0.notes) }) { _ in line }
        } else {
            workspace.speak(to: .session(session, mode: mode, card: card), from: box) { $0.accepting(accepts).stored }
        }
        didSend(talked: command == nil)
    }
}

extension AppSettings {
    /// 回复框绑定的草稿（`replyDraft`，离开会话再回来还在）。
    func replyDraftBinding(for session: UUID) -> Binding<ComposerDraft> {
        Binding(get: { self.replyDraft(for: session) }, set: { self.setReplyDraft($0, for: session) })
    }
}
