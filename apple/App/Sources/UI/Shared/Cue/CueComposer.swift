import CueStore
import SwiftUI

/// 浮起的输入条这一句的去处。
enum CueBarTarget: CaseIterable { case cue, idea, task }

/// "对 Cue 说"的输入框（全 App 只此一个）：草稿是 Cue 的那一份（`CueWatch.draft`），可带图片。要做事就在这里说，随手记也在这里：
/// 发送是对 Cue 说，长按是"只记下"（记成默认项目里的一条灵感，不交给它）；Cue 没启用时发送就是记下。
/// 按下就清空输入框，不等上传；这里只管输入与发完之后做什么（`sent`）。
/// Mac 的 Cue 页上有 Cue 用哪个 Agent、模型与思考强度的工具排（`CueConfigControls`，与新会话同一排）；没启用时不放：
/// 没启用时发出去只是记下，还没有在哪台 Mac 运行，那几颗只能写一份选不了的缺省。
/// 浮起的输入条的工具排是这一句的去处（`CueBarTargets`）：对 Cue 说、记成灵感、建成任务，Tab 轮换；后两种可选项目。
/// 记下后不马上收：占位处写一下记到了哪（`receipt`），这一下里又打了字就留着接着记下一条；没写成（草稿放回来了）也留着。
/// 再唤出时草稿空着就回到对 Cue 说：按快捷键、打字、回车做的事每次一样；有草稿时去处留着，没说完的那句不会发错地方。
/// Cue 运行在别的 Mac 上时工具排末尾的 Mac 图标说明在哪台（`CueNow.elsewhere`）：那几枚胶囊选的就是那台上的大脑。
/// 手机上它们在 Cue 面板的第一行（`CueHeader`），输入框里不再放一份：聚焦才露出的胶囊找不到。
/// 手机与 iPad 的 Cue 页上，右下那一颗空着时是和 Cue 通话、有草稿时是发送（同一颗钮原地换，`SendGlyph`）；通话中这块玻璃原地变成通话条（`PhoneCall`）。
/// 在不在通话、静没静音只看 `VoiceService`，界面不另存一份。
/// Mac 的通话入口在工具排末尾（`CueVoiceComposerEntry`），通话中整个输入框让给通话条（`CueVoicePanel`，`CuePage`）。
struct CueComposer: View {
    enum Style: Equatable {
        case page
        /// 浮起的输入条：一直展开；`opens` 每变一次（又唤出了）就拿到焦点。
        case bar(opens: Int)
    }

    let style: Style
    /// 接"对 Cue 说"的焦点请求（`Workspace.cueFocusPending`）：Cue 页的输入框接，iPad 右侧面板里的不接。
    var takesFocusRequests = false
    /// 浮起的输入条按 Esc。
    var dismiss: () -> Void = {}
    var sent: () -> Void = {}
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @Environment(\.panelCovered) private var covered
    @State private var launch = RelayLaunch()
    @State private var target = CueBarTarget.cue
    @State private var project = Project.defaultID
    @State private var receipt: String?
    #if os(macOS)
    @State private var opening: ConfigPick?
    #else
    /// 接通时输入框有焦点：挂断后还给它。
    @State private var focusAfterCall = false
    #endif

    var body: some View {
        let cue = workspace.cue
        Composer(
            draft: Bindable(cue).draft, prompt: prompt,
            label: "对 \(cue.name) 说",
            focus: $focused, accepts: .files,
            form: form, showsSendEmpty: sending || calls || inCall || receipt != nil, yielded: inCall, lead: lead, tooled: tooled, shortcuts: shortcuts, keys: keys,
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
                if !covered, opens != nil || style == .page && DebugHooks.preset.cueFocus { focused = true }
            }
            .onChange(of: takesFocusRequests && workspace.cueFocusPending, initial: true) { _, pending in
                guard pending, !covered else { return }
                focused = true
                workspace.cueFocusPending = false
            }
            #if os(iOS)
            // 推入别的页就交出焦点、收起键盘，返回时不还：只由系统收起的话 SwiftUI 记着它，返回时在推出转场里把键盘弹回来，
            // 这一页的托管控制器不认转场里到的键盘，输入框与拍板卡就压在键盘底下（实测）
            .onChange(of: workspace.top) { _, top in
                if style == .page, takesFocusRequests, top != .cue { focused = false }
            }
            #endif
            .task { if style == .page { await DebugHooks.pressSendIfAsked(session: false, send) } }
    }

    /// 长按菜单是 `MenuButton`：菜单开着时输入框锁在原位。
    /// 手机空着时同一颗是通话（`calls`）、通话中是挂断，长按没有菜单。
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
            .help("发送（\(ReplyShortcut.send.symbols)）；按住只记下")
            #endif
        } else {
            Button(action: send) { SendGlyph(.save(enabled: true)) }
                .buttonStyle(PressStyle(.button))
                .accessibilityLabel(aim == .task ? "添加任务" : "记下")
        }
    }

    private var tooled: Bool {
        #if os(macOS)
        opens != nil || workspace.cue.canHear
        #else
        false
        #endif
    }

    @ViewBuilder private var tools: some View {
        #if os(macOS)
        if opens != nil {
            CueBarTargets(targets: targets, aim: aim, project: destination, pick: { target = $0 }) { project = $0 }
        } else if tooled {
            CueBrainRow(opening: $opening)
        }
        #endif
    }

    /// Cue 没启用时没有对它说那一格。
    private var targets: [CueBarTarget] { workspace.cue.canHear ? CueBarTarget.allCases : [.idea, .task] }

    /// Cue 页只有对 Cue 说（没启用时发送就是记下，`Workspace.sayToCue`）。
    private var aim: CueBarTarget {
        guard opens != nil else { return .cue }
        return targets.contains(target) ? target : .idea
    }

    /// 选过的项目后来删了就回到默认项目。
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
    private var calls: Bool { phonePage && workspace.cue.canHear && !hasDraft && !sending }
    private var inCall: Bool { phonePage && !workspace.services.voice.canStart }
    private var callReady: Bool { workspace.services.voice.startUnavailableReason == nil }

    private var lead: ComposerLead? {
        #if os(iOS)
        guard inCall else { return nil }
        let voice = workspace.services.voice
        return ComposerLead(icon: voice.isMuted ? .muted : .microphone, label: voice.isMuted ? "取消静音" : "静音",
                            on: voice.isMuted, enabled: voice.canMute) { workspace.runPhoneVoice(.setMuted(!voice.isMuted)) }
        #else
        nil
        #endif
    }

    private func call() {
        #if os(iOS)
        workspace.callCue()
        #endif
    }

    private func hangUp() {
        #if os(iOS)
        workspace.runPhoneVoice(.hangUp)
        #endif
    }
    /// 空着时的发送中：你最近一句还在路上（与气泡、头像同一个事实，`CueWatch.sending`）。
    private var sending: Bool { aim == .cue && workspace.cue.canHear && (workspace.cue.launching || workspace.cue.sending) }

    private var form: ComposerForm {
        #if os(iOS)
        if style == .page { return .line(opensOnFocus: false) }
        #endif
        return .open
    }

    private var shortcuts: [ReplyShortcut: () -> Void] {
        var map: [ReplyShortcut: () -> Void] = [.send: send]
        #if os(macOS)
        if tooled {
            map[.model] = { opening = .model }
            map[.thinking] = { opening = .thinking }
        }
        #endif
        return map
    }

    private var opens: Int? { if case .bar(let opens) = style { opens } else { nil } }

    private func send() {
        guard hasDraft else { return }
        let draft = Bindable(workspace.cue).draft
        if aim == .cue {
            let event = CueWatch.Send(at: .now, beat: workspace.cue.beat)
            guard workspace.sayToCue(from: draft) != nil else { return }
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

    /// 够认出那一句，又不让人等。
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

#if os(macOS)
/// 大脑的可选与当前由这一排自己订阅：读到、变了只重算这一排，不重算整个输入框。
private struct CueBrainRow: View {
    @Binding var opening: ConfigPick?
    @State private var brain: AgentModelChoice?

    var body: some View {
        CueConfigControls(choice: brain, opening: $opening) {
            CueHostNote()
            CueVoiceComposerEntry()
        }
        .observingCueBrain(into: $brain)
    }
}

/// 单拆一个视图读 Cue 此刻：输入框本身不随它重算。
private struct CueHostNote: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        if let elsewhere = workspace.cue.now.elsewhere {
            Image(.mac)
                .font(Typography.meta).foregroundStyle(palette.ink3)
                .help(elsewhere).iconLabel(elsewhere)
                .padding(.trailing, Spacing.tight)
                .transition(.opacity)
        }
    }
}
#endif
