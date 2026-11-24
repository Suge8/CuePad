import CueStore
import SwiftUI

/// 这个会话此刻做不到的不露出，规则同 `MacDelivery`。
/// 等你确认时文字型问题它就是作答框（只收文字）；选择、确认型收成一行"先在上面作答"，这里答不了的写明要去哪回答——都不发自由文本（Pi 不答完题不会去看，消息会一直挂着）。
/// 同步到不了 Mac 时照样发：写下就排着，恢复后自动发出，同对 Cue 说的话（为什么不通只在同步那一处说）；停止要当场生效，那时停用。按下就清空输入框，请求马上贴到对话末尾，不等上传。
struct ReplyBar: View {
    let session: SessionState
    let config: ConfigShown?
    let catalog: AgentCatalog?
    let stopping: Bool
    var commandProgress: MacDelivery.CommandProgress?
    var sending = false
    var recall: String?
    var previews: [PreviewItem] = []
    var cache: ChatMessage.Tools.Cache?
    var revealNote: (ReplyNote) -> Void = { _ in }
    let sent: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.pageActive) private var active
    @Environment(\.sendFlight) private var flight
    @Environment(\.replyCompact) private var compact
    @State private var sentCount = 0
    @FocusState private var focused: Bool
    @Environment(\.panelCovered) private var covered
    @State private var opening: ConfigPick?
    @State private var asleepNote = BubbleSwitch()

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
    private var commands: [SlashCommand] { answering == nil ? catalog?.commands ?? [] : [] }
    private var reachable: Bool { services.syncing.reachesHost }
    private var macOff: String? { session.macOff(at: services.speech) }
    private var hasDraft: Bool { !draft.isEmpty(accepting: accepts) }
    private var canSend: Bool { hasDraft }
    private var canStop: Bool { session.canStop }
    private var shownSending: Bool { !hasDraft && !canStop && (workspace.launching.contains(SendingTarget(session)) || sending) }
    private var glyph: SendGlyph.Phase { canSend ? .ready : shownSending ? .sending : .idle }
    private var commandLine: String? { commands.isEmpty ? nil : Slash.line(of: draft, in: commands, for: session) }
    private var button: ReplyButton? { MacDelivery.button(for: session, hasDraft: hasDraft, command: commandLine != nil) }

    var body: some View {
        Group {
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
        .onAppear {
            let landed = workspace.takeReplyLanding(session.id) && active && !covered
            focused = (takesAsk() || landed) && composes || DebugHooks.args.layoutOpts.modelMenu
        }
        .onChange(of: workspace.replyFocus) { if takesAsk(), composes { focused = true } }
    }

    /// 点名要这一条接焦点的请求（`Workspace.replyFocus`）。同落下来的焦点一样只在提出那一下认（这一条摆出来、摆着时被点名）：
    /// 这时在等作答、没有输入框，就作废，不留到答完题、别处正打着字时再生效。
    private func takesAsk() -> Bool {
        guard workspace.replyFocus == session.id else { return false }
        workspace.replyFocus = nil
        return true
    }

    private var composes: Bool {
        switch reply {
        case .message, .answer: true
        case .answerAbove, .unanswerable: false
        }
    }

    private var expanded: Bool { form.expanded(focused: focused, draft: draft, accepts: accepts) }

    private var composer: some View {
            Composer(
                draft: box, prompt: prompt, promptIcon: wakes ? .wakeSession : nil, label: "回复", focus: $focused, accepts: accepts,
                cardsFrom: session.projectID, form: form, submitsEmpty: canStop, showsSendEmpty: shownSending || macOff != nil, keepsHeader: !draft.notes.isEmpty, tooled: hasTools,
                commands: commands, submit: submit, picks: picks, recall: recall,
                header: {
                    if !draft.notes.isEmpty { ReplyNoteStack(notes: draft.notes, previews: previews, reveal: revealNote, remove: removeNote) }
                },
                tools: {
                    if hasTools, let config { SessionConfigControls(session: session, models: models, shown: config, cache: cache, opening: $opening) }
                },
                send: { sendControl }
            )
            .sensoryFeedback(.success, trigger: sentCount)
            .task { await DebugHooks.pressSendIfAsked(session: true) { submit?() } }
    }

    private func progressLine(_ progress: MacDelivery.CommandProgress) -> some View {
        HStack(spacing: Spacing.glyph) {
            if case .running = progress { Spinner(.mini) }
            Text(progress.text).lineLimit(2)
        }
        .font(Typography.meta).foregroundStyle(progress.failed ? palette.failure : palette.ink3)
    }

    private static let unanswerable: LocalizedStringResource = "CuePad 答不了这类提问，只能让这个会话休眠"

    private var submit: (() -> Void)? {
        if macOff != nil { return { asleepNote.open = true } }
        return switch button {
        case .answer: answer
        case .send(let mode): { send(mode) }
        case .stop, nil: nil
        }
    }

    private var picks: ((ConfigPick) -> Void)? {
        #if os(macOS)
        hasTools ? { opening = $0 } : nil
        #else
        nil
        #endif
    }

    private func didSend() {
        #if os(iOS)
        focused = false
        #endif
        sentCount += 1
        services.settings.play(.send)
        sent()
    }

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
        if let macOff {
            Button { asleepNote.toggle() } label: { SendGlyph(.asleep) }
                .buttonStyle(PressStyle(.button))
                .bubble($asleepNote) { MacAsleepNote(mac: macOff) }
                .accessibilityLabel("「\(macOff)」没开")
        } else {
            sendButton
        }
    }

    @ViewBuilder private var sendButton: some View {
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

    private var interrupts: Bool { session.runtimeState.known?.isTurnRunning == true }
    private static let interruptNote = String(localized: "会打断这一轮，以这句接着做")
    private var sendNote: String { interrupts ? Self.interruptNote : "" }

    private var placeholder: LocalizedStringResource {
        if let answering { return answering.kind == .known(.select) ? "或写你自己的回答" : "回答上面的问题" }
        if !draft.attachments.isEmpty || !draft.files.isEmpty { return "补一句" }
        return interrupts ? "打断本轮" : replyPrompt
    }

    private var prompt: LocalizedStringResource { compact ? replyPrompt : placeholder }

    private var replyPrompt: LocalizedStringResource {
        ended ? "唤醒会话" : "回复 \(session.title)"
    }

    private var ended: Bool { session.state == .known(.ended) }
    private var wakes: Bool { ended && answering == nil && (compact || draft.attachments.isEmpty && draft.files.isEmpty) }

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

    private func send(_ mode: DeliveryMode) {
        guard canSend else { return }
        let id = UUID()
        if commandLine == nil { flight?.depart(draft, as: id) }
        workspace.reply(to: session, commands: commands, from: box, accepting: accepts, mode: mode, card: draft.attachments.first?.card, as: id)
        didSend()
    }
}

private struct MacAsleepNote: View {
    let mac: String
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text("「\(mac)」没开").font(Typography.secondary.weight(.semibold)).foregroundStyle(palette.ink)
            Text("开机后再发，写好的先留着").font(Typography.meta).foregroundStyle(palette.ink2)
        }
        .fixedSize()
        .padding(Spacing.block)
    }
}

extension AppSettings {
    func replyDraftBinding(for session: UUID) -> Binding<ComposerDraft> {
        Binding(get: { self.replyDraft(for: session) }, set: { self.setReplyDraft($0, for: session) })
    }
}

extension EnvironmentValues {
    @Entry var replyCompact = false
}
