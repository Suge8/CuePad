import CueStore
import SwiftUI

/// 这个会话此刻做不到的不露出，规则同 `MacDelivery`。
/// 等你确认时文字型问题它就是作答框（只收文字）；选择、确认型收成一行"先在上面作答"，这里答不了的写明要去哪回答——都不发自由文本（Pi 不答完题不会去看，消息会一直挂着）。
/// 同步到不了 Mac 时照样发：写下就排着，恢复后自动发出，同对 Cue 说的话（为什么不通只在同步那一处说）；停止要当场生效，那时停用。按下就清空输入框，请求马上贴到对话末尾，不等上传。
struct ReplyBar: View {
    let session: SessionState
    let config: ConfigShown?
    let catalog: AgentCatalog?
    var compact = false
    let stopping: Bool
    var commandProgress: MacDelivery.CommandProgress?
    var sending = false
    var recall: String?
    var previews: [PreviewItem] = []
    /// 最新那条回答带的提示缓存（`ChatMessage.Tools.Cache`）：过了 `warmUntil` 还没说下一句，写字时提醒这一句要重读多少。
    var cache: ChatMessage.Tools.Cache?
    var revealNote: (ReplyNote) -> Void = { _ in }
    let sent: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.pageActive) private var active
    @State private var sentCount = 0
    @FocusState private var focused: Bool
    @Environment(\.panelCovered) private var covered
    @State private var opening: ConfigPick?
    @State private var cold = false

    /// 回复框的草稿（每个会话一份，`AppSettings.replyDraft`）只在回复框里读写：会话页不经手它，
    /// 打字时只有回复框（与列表里那一行）重算，会话页、对话都不动。
    private var draft: ComposerDraft {
        get { services.settings.replyDraft(for: session.id) }
        nonmutating set { services.settings.setReplyDraft(newValue, for: session.id) }
    }

    private var hasTools: Bool {
        config != nil && !models.isEmpty
    }

    private var form: ComposerForm {
        #if os(macOS)
        .open
        #else
        compact && !canStop ? .capsule(opensOnFocus: hasTools) : .line(opensOnFocus: hasTools)
        #endif
    }

    private var models: [ModelOption] { catalog?.models ?? [] }

    private var reply: ReplyMode { MacDelivery.reply(to: session) }

    private var answering: Question? {
        if case .answer(let question) = reply { question } else { nil }
    }

    private var accepts: ComposerKinds { answering == nil ? .reply : [] }
    private var commands: [SlashCommand] { answering == nil ? session.usableCommands(in: catalog) : [] }
    private var reachable: Bool { services.reachesHost }
    private var hasDraft: Bool { !draft.isEmpty(accepting: accepts) }
    private var canSend: Bool { hasDraft }
    private var canStop: Bool { session.canStop }
    private var shownSending: Bool { !hasDraft && !canStop && (workspace.launching.contains(session) || sending) }
    private var glyph: SendGlyph.Phase { canSend ? .ready : shownSending ? .sending : .idle }
    private var commandLine: String? { commands.isEmpty ? nil : Slash.line(of: draft, in: commands, for: session) }
    private var button: ReplyButton? { MacDelivery.button(for: session, hasDraft: hasDraft, command: commandLine != nil) }

    var body: some View {
        switch reply {
        case .answerAbove: notice("先在上面作答", icon: .above)
        case .unanswerable: notice(Self.unanswerable, icon: .mac)
        case .message, .answer:
            composer.composerNotice(commandProgress != nil || expanded && (config?.failure != nil || recache != nil)) {
                if let commandProgress { progressLine(commandProgress) }
                if expanded {
                    MacInputNotice(failure: config?.failure)
                    if let recache {
                        Group {
                            if cache?.estimated == true {
                                Text("缓存可能已冷，这一句可能重读约 \(CueContext.tokens(recache))")
                            } else {
                                Text("缓存已冷，这一句会重读约 \(CueContext.tokens(recache))")
                            }
                        }
                        .font(Typography.caption).foregroundStyle(palette.ink3)
                    }
                }
            }
            .task(id: cache?.warmUntil) {
                cold = false
                guard let until = cache?.warmUntil else { return }
                try? await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow)))
                cold = !Task.isCancelled
            }
        }
    }

    /// 小上下文重读不值一提；这一轮还在跑时缓存正被用着。
    private var recache: Int? {
        guard cold, !session.runtimeState.isWorking, let context = cache?.context, context >= Self.recacheWorthSaying else { return nil }
        return context
    }

    private static let recacheWorthSaying = 20_000

    private var expanded: Bool { form == .open || focused || !form.isCapsule && !draft.isEmpty(accepting: accepts.union(.notes)) }

    private var composer: some View {
            Composer(
                draft: box, prompt: compact ? replyPrompt : placeholder, label: "回复", focus: $focused, accepts: accepts,
                cardsFrom: session.projectID, form: form, submitsEmpty: canStop, showsSendEmpty: shownSending, keepsHeader: !draft.notes.isEmpty, tooled: hasTools,
                commands: commands, shortcuts: shortcuts, recall: recall,
                header: {
                    if !draft.notes.isEmpty { ReplyNoteStack(notes: draft.notes, previews: previews, reveal: revealNote, remove: removeNote) }
                },
                tools: {
                    if hasTools, let config { SessionConfigControls(session: session, models: models, shown: config, opening: $opening) }
                },
                send: { sendControl }
            )
            .sensoryFeedback(.success, trigger: sentCount)
            // 读到了（在路上，或 Agent 已经接过去开始跑）就交还给页面；页面走了也不留
            .onChange(of: sending) { workspace.launching.settle(session) }
            .onChange(of: canStop) { workspace.launching.settle(session) }
            .onDisappear { workspace.launching.settle(session) }
            .task { await DebugHooks.pressSendIfAsked(session: true) { shortcuts[.send]?() } }
            .onChange(of: workspace.replyFocus, initial: true) {
                guard workspace.replyFocus == session.id else { return }
                workspace.replyFocus = nil
                focused = true
            }
            #if os(macOS)
            .onAppear { focused = active && !covered }
            #endif
    }

    private func progressLine(_ progress: MacDelivery.CommandProgress) -> some View {
        HStack(spacing: Spacing.glyph) {
            if case .running = progress { Spinner(.mini) }
            Text(progress.text).lineLimit(2)
        }
        .font(Typography.meta).foregroundStyle(progress.failed ? palette.failure : palette.ink3)
    }

    private static let unanswerable: LocalizedStringResource = "CuePad 答不了这类提问，只能结束这个会话"

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
    private func didSend(talked: Bool = true) {
        if talked { workspace.launching.begin(session) } else { workspace.launching.settle(session) }
        #if os(iOS)
        focused = false
        #endif
        sentCount += 1
        sent()
    }

    /// 等你确认、不能发自由文本时收成的一行，与空着的回复框同高（Mac 是两层的高）：问题卡来去时回复框不跟着变高变矮，浮在上面的对话只跟着卡挪（`RiseBehind`）。
    private func notice(_ text: LocalizedStringResource, icon: Icon) -> some View {
        Label(text, icon: icon)
            .font(Typography.secondary).foregroundStyle(palette.ink2)
            .padding(.horizontal, Spacing.block).frame(maxWidth: .infinity, minHeight: Self.noticeHeight, alignment: .leading)
            .glass(in: .rect(cornerRadius: Radius.field))
    }

    #if os(macOS)
    private static let noticeHeight = ComposerMetrics.openOneLine
    #else
    private static let noticeHeight = 2 * Radius.field
    #endif

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

    private var interrupts: Bool { session.state.known?.isTurnRunning == true }
    private static let interruptNote = String(localized: "会打断这一轮，以这句接着做")
    private var sendNote: String { interrupts ? Self.interruptNote : "" }

    private var placeholder: LocalizedStringResource {
        if let answering { return answering.kind == .known(.select) ? "或写你自己的回答" : "回答上面的问题" }
        if !draft.attachments.isEmpty || !draft.files.isEmpty { return "补一句" }
        return interrupts ? "打断本轮" : replyPrompt
    }

    /// 回给这个会话的那句占位：已结束的会话也能接着说——发出后它所在的 Mac 先在后台把它唤醒再送达，占位写明这一步，
    /// 不让人以为发给了一个没人接的会话。
    private var replyPrompt: LocalizedStringResource {
        session.state == .known(.ended) ? "唤醒 \(session.title) 接着说" : "回复 \(session.title)"
    }

    /// 说出去的这句就是答案（`CueStore.speak`），答完文字清空，其余（别处带进草稿的卡片、附件）留着。
    private func answer() {
        guard canSend, answering != nil else { return }
        workspace.answer(session, from: box)
        didSend()
    }

    private var box: Binding<ComposerDraft> { services.settings.replyDraftBinding(for: session.id) }

    private func stop() {
        Task { await workspace.stop(session) }
    }

    private func removeNote(_ note: ReplyNote) { services.settings.removeReplyNote(note.id, in: session.id) }

    /// 是命令还是说的话只在发出这一刻按草稿与会话报的清单认（`Workspace.reply`），不看按钮上次排版时带来的方式。
    private func send(_ mode: DeliveryMode) {
        guard canSend else { return }
        let talked = commandLine == nil
        workspace.reply(to: session, commands: commands, from: box, accepting: accepts, mode: mode, card: draft.attachments.first?.card)
        didSend(talked: talked)
    }
}

extension AppSettings {
    func replyDraftBinding(for session: UUID) -> Binding<ComposerDraft> {
        Binding(get: { self.replyDraft(for: session) }, set: { self.setReplyDraft($0, for: session) })
    }
}
