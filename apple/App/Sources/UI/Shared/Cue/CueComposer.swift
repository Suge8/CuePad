import CueStore
import SwiftUI

enum CueBarTarget: CaseIterable { case cue, idea, task }

struct CueComposer: View {
    enum Style: Equatable {
        case page
        case bar(opens: Int)
    }

    let style: Style
    var takesFocusRequests = false
    var dismiss: () -> Void = {}
    var sent: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sendFlight) private var flight
    @FocusState private var focused: Bool
    @Environment(\.panelCovered) private var covered
    @State private var launch = RelayLaunch()
    @State private var target = CueBarTarget.cue
    @State private var project = Project.defaultID
    @State private var receipt: String?
    #if os(iOS)
    @State private var focusAfterCall = false
    #endif

    var body: some View {
        let cue = workspace.cue
        Composer(
            draft: Bindable(cue).draft, prompt: prompt,
            label: "对 \(cue.name) 说",
            focus: $focused, accepts: .files,
            form: form, showsSendEmpty: sending || calls || inCall || receipt != nil, yielded: inCall, lead: lead, tooled: tooled, submit: send, keys: keys,
            header: { EmptyView() },
            tools: { tools },
            send: { sendButton })
            #if os(iOS)
            .modifier(PhoneCall(active: inCall))
            .onChange(of: inCall) { _, now in
                if now {
                    focusAfterCall = focused
                    focused = false
                } else if focusAfterCall, !covered {
                    focusAfterCall = false
                    focused = true
                }
            }
            #endif
            .onChange(of: opens, initial: true) {
                if !hasDraft { target = .cue }
                if !covered, opens != nil || style == .page && DebugHooks.args.cueOpts.focus { focused = true }
            }
            .onChange(of: takesFocusRequests && workspace.cueFocusPending, initial: true) { _, pending in
                guard pending, !covered else { return }
                focused = true
                workspace.cueFocusPending = false
            }
            #if os(iOS)
            // 推入别的页就交出焦点、收起键盘，返回时不还：只由系统收起的话 SwiftUI 记着它，返回时在推出转场里把键盘弹回来，
            // 这一页的托管控制器不认转场里到的键盘，输入框就压在键盘底下（实测）
            .onChange(of: workspace.mainRoute) { _, top in
                if style == .page, takesFocusRequests, top != .cue { focused = false }
            }
            #endif
            .task { if style == .page { await DebugHooks.pressSendIfAsked(session: false, send) } }
    }

    @ViewBuilder private var sendButton: some View {
        let cue = workspace.cue
        if aim == .cue, cue.canHear {
            let hangingUp = inCall && workspace.services.voice.phase == .closing
            MenuButton(
                sections: hasDraft ? [ChoiceMenu.Section(choices: [ChoiceMenu.Choice(title: "只记下（记成灵感）", image: .icon(.write), choose: note)])] : [],
                primary: inCall ? hangUp : calls ? call : send, press: .button,
                accessibilityLabel: inCall ? "结束通话" : calls ? "和 Cue 通话" : "发送", hint: inCall || calls ? nil : "长按只记下"
            ) {
                SendGlyph(hasDraft ? .ready : inCall ? (hangingUp ? .stopping : .hangUp) : calls ? .call(enabled: callReady) : .sending)
            }
            .disabled(inCall ? hangingUp : !hasDraft && !calls)
            .relayLaunch(launch, color: palette.signature)
            .fixedSize()
            #if os(macOS)
            .help(calls ? Text(workspace.voiceStartBlock?.message ?? "和 Cue 通话") : Text("发送（\(ReplyShortcut.send.symbols)）；按住只记下"))
            #endif
        } else {
            Button(action: send) { SendGlyph(.save(enabled: true)) }
                .buttonStyle(PressStyle(.button))
                .accessibilityLabel(aim == .task ? "添加任务" : "记下")
        }
    }

    private var tooled: Bool {
        #if os(macOS)
        opens != nil
        #else
        false
        #endif
    }

    @ViewBuilder private var tools: some View {
        #if os(macOS)
        if opens != nil {
            CueBarTargets(targets: targets, aim: aim, project: destination, pick: { target = $0 }) { project = $0 }
        }
        #endif
    }

    private var targets: [CueBarTarget] { workspace.cue.canHear ? CueBarTarget.allCases : [.idea, .task] }

    private var aim: CueBarTarget {
        guard opens != nil else { return .cue }
        return targets.contains(target) ? target : .idea
    }

    private var destination: UUID { workspace.catalog?.project(project) == nil ? Project.defaultID : project }

    private var prompt: LocalizedStringResource {
        if let receipt { return .verbatim(receipt) }
        return switch aim {
        case .cue: workspace.cue.canHear ? "对 \(workspace.cue.name) 说" : "记下灵感"
        case .idea: "记下灵感"
        case .task: "添加任务"
        }
    }

    private var keys: [ComposerKey: () -> Void] {
        guard opens != nil else { return [:] }
        return [.next: { turn(1) }, .previous: { turn(-1) }, .dismiss: dismiss]
    }

    private func turn(_ step: Int) {
        let targets = targets
        guard let index = targets.firstIndex(of: aim) else { return }
        target = targets[(index + step + targets.count) % targets.count]
    }

    private var hasDraft: Bool { !workspace.cue.draft.isEmpty(accepting: .files) }

    private var phonePage: Bool {
        #if os(iOS)
        style == .page
        #else
        false
        #endif
    }
    private var calls: Bool { style == .page && workspace.cue.canHear && !hasDraft && !sending }
    private var inCall: Bool { phonePage && !workspace.services.voice.canStart }
    private var callReady: Bool { workspace.voiceStartBlock == nil }

    private var lead: ComposerLead? {
        #if os(iOS)
        guard inCall else { return nil }
        let voice = workspace.services.voice
        return ComposerLead(icon: voice.isMuted ? .muted : .microphone, label: voice.isMuted ? "取消静音" : "静音",
                            on: voice.isMuted, enabled: voice.canMute) { workspace.runVoice(.setMuted(!voice.isMuted)) }
        #else
        nil
        #endif
    }

    private func call() {
        #if os(iOS)
        workspace.callCue()
        #else
        workspace.startVoiceCall()
        #endif
    }

    private func hangUp() {
        #if os(iOS)
        workspace.runVoice(.hangUp)
        #endif
    }
    private var sending: Bool { aim == .cue && workspace.cue.canHear && (workspace.launching.contains(.cue) || workspace.cue.sending) }

    private var form: ComposerForm {
        #if os(iOS)
        if style == .page { return .line(opensOnFocus: false) }
        #endif
        return .open
    }

    private var opens: Int? { if case .bar(let opens) = style { opens } else { nil } }

    private func send() {
        guard hasDraft else { return }
        let draft = Bindable(workspace.cue).draft
        if aim == .cue {
            let event = CueWatch.Send(at: .now, beat: workspace.cue.beat)
            let id = UUID()
            if workspace.cue.canHear { flight?.depart(draft.wrappedValue, as: id) }
            guard workspace.sayToCue(from: draft, as: id) != nil else { return }
            workspace.cue.sent(event)
            workspace.services.settings.play(.send)
            launch.fly(since: event.at, reduceMotion: reduceMotion)
        } else {
            let asTask = aim == .task
            let name = workspace.catalog?.project(destination)?.shownName ?? ""
            guard let saving = workspace.note(from: draft, asTask: asTask, in: destination) else { return }
            Task {
                await saving.value
                guard !hasDraft else { return }
                receipt = asTask ? CaptureCopy.added(to: name) : CaptureCopy.saved(to: name)
                try? await Task.sleep(for: Self.receiptHold)
                receipt = nil
                if !hasDraft { finish() }
            }
            return
        }
        finish()
    }

    private static let receiptHold: Duration = .milliseconds(450)

    private func note() {
        guard workspace.note(from: Bindable(workspace.cue).draft) != nil else { return }
        finish()
    }

    private func finish() {
        #if os(iOS)
        focused = false
        #endif
        sent()
    }
}
