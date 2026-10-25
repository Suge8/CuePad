import SwiftUI

/// "对 Cue 说"的输入框（全 App 只此一个）：草稿是 Cue 的那一份（`CueWatch.draft`），可带图片。要做事就在这里说，随手记也在这里：
/// 发送是对 Cue 说（它定项目、建任务、开工），长按发送是"只记下"——记成默认项目里的一条灵感，不交给它；Cue 没启用时发送就是记下
/// （`Workspace.sayToCue`、`note`）。按下就清空输入框，不等上传；这里只管输入与发完之后做什么（`sent`）。
/// Mac 的 Cue 页上工具排里是 Cue 用哪个 Agent、模型与思考强度（`CueConfigControls`，与新会话同一排；⌘⇧M、⌘⇧E 弹出模型与思考强度的菜单）；浮起的输入条不放，
/// 没启用时也不放：发出去只是记下，还没有在哪台 Mac 运行，那几颗只能写一份选不了的缺省。
/// Cue 运行在别的 Mac 上时工具排末尾一句旁注写在哪台（`CueNow.elsewhere`）：那几枚胶囊选的就是那台上的大脑。
/// 手机上它们在 Cue 面板的第一行（`CueHeader`），输入框里不再放一份：聚焦才露出的胶囊找不到。
struct CueComposer: View {
    enum Style: Equatable {
        /// Cue 页底部：Mac 一直展开，手机一行、打了字再长，发完收起键盘。
        case page
        /// 浮起的输入条（⌥⇧Space）：一直展开；`opens` 每变一次（又唤出了）就拿到焦点。
        case bar(opens: Int)
    }

    let style: Style
    /// 接"对 Cue 说"的焦点请求（`Workspace.cueFocusPending`）：Cue 页的输入框接，iPad 右侧面板里的不接。
    var takesFocusRequests = false
    var sent: () -> Void = {}
    /// 焦点进出时告诉外面（iPhone Cue 页底部的"⋯"随它让开）。
    var focusChanged: (Bool) -> Void = { _ in }
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    /// 刚发出、还没读到这一句：库里那条记录要下一次读库才变成 `CueWatch.sending`，这一小段钮先当帧换成发送中，
    /// 不先缩没再长出来。读到了这一句（`lastYouSaid` 变了，此时在不在路上都已算进 `sending`）就交还给它。
    /// 只看这两项不看整个现状：在想、用工具时每一步都变，读它的话整个输入框跟着重算。
    @State private var launched = false
    /// 光从发送钮的机头起飞、落进 Cue 的头像。
    @State private var launch = RelayLaunch()
    #if os(macOS)
    /// ⌘⇧M、⌘⇧E 请模型或思考强度弹出菜单。
    @State private var opening: PiConfigPick?
    /// 大脑那一排的可选与当前（Mac 的 Cue 页工具排）。
    @State private var brain: AgentModelChoice?
    #endif

    var body: some View {
        let cue = workspace.cue
        Composer(
            draft: Bindable(cue).draft, prompt: cue.canHear ? "对 \(cue.name) 说" : "记一条灵感",
            label: "对 \(cue.name) 说",
            focus: $focused, accepts: .images,
            form: form, showsSendEmpty: sending, tooled: tooled, shortcuts: shortcuts,
            header: { EmptyView() },
            tools: { tools },
            send: { sendButton })
            .onChange(of: opens, initial: true) { if opens != nil || style == .page && DebugHooks.preset.cueFocus { focused = true } }
            .onChange(of: takesFocusRequests && workspace.cueFocusPending, initial: true) { _, pending in
                guard pending else { return }
                focused = true
                workspace.cueFocusPending = false
            }
            .onChange(of: focused) { focusChanged(focused) }
            #if os(iOS)
            // 推入别的页就交出焦点、收起键盘，返回时不还：只由系统收起的话 SwiftUI 记着它，返回时在推出转场里把键盘弹回来，
            // 这一页的托管控制器不认转场里到的键盘，输入框与拍板卡就压在键盘底下（实测）。焦点经上面那条报给底部那一排
            .onChange(of: workspace.top) { _, top in
                if style == .page, takesFocusRequests, top != .cue { focused = false }
            }
            #endif
            .onChange(of: workspace.cue.lastYouSaid) { launched = false }
            .task { if style == .page { await DebugHooks.pressSendIfAsked(session: false, send) } }
    }

    /// 发送钮：点是发送，长按是"只记下"（`MenuButton`：菜单开着时输入框锁在原位）。Cue 没启用时只有记下。
    @ViewBuilder private var sendButton: some View {
        let cue = workspace.cue
        if cue.canHear {
            MenuButton(
                sections: [ChoiceMenu.Section(choices: [ChoiceMenu.Choice(title: "只记下（记成灵感）", image: .icon(.write), choose: note)])],
                primary: send, press: .button, accessibilityLabel: "发送", hint: "长按只记下"
            ) {
                SendGlyph(hasDraft ? .ready : .sending)
            }
            .disabled(!hasDraft)
            .relayLaunch(launch, color: palette.signature)
            .fixedSize()
            #if os(macOS)
            .help("发送（\(ReplyShortcut.send.symbols)）；按住只记下")
            #endif
        } else {
            Button(action: send) { SendGlyph(.save(enabled: true)) }
                .buttonStyle(PressStyle(.button))
                .accessibilityLabel("记下")
        }
    }

    /// Agent、模型与思考强度只在 Mac 的 Cue 页上（`tools`）。
    private var tooled: Bool {
        #if os(macOS)
        style == .page && workspace.cue.canHear
        #else
        false
        #endif
    }

    @ViewBuilder private var tools: some View {
        #if os(macOS)
        if tooled {
            HStack(spacing: 8) {
                CueConfigControls(choice: brain, opening: $opening)
                CueHostNote()
            }
            .observingCueBrain(into: $brain)
        }
        #endif
    }

    private var hasDraft: Bool { !workspace.cue.draft.isEmpty(accepting: .images) }
    /// 空着时的发送中：你最近一句还在路上（与气泡、头像同一个事实，`CueWatch.sending`）。
    private var sending: Bool { workspace.cue.canHear && (launched || workspace.cue.sending) }

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
        guard hasDraft, workspace.sayToCue(from: Bindable(workspace.cue).draft) != nil else { return }
        launched = true
        launch.fly(reduceMotion: reduceMotion)
        finish()
    }

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
/// 工具排末尾的旁注：Cue 运行在别的 Mac 上时写在哪台。单拆一个视图读 Cue 此刻：输入框本身不随它重算。
private struct CueHostNote: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        if let elsewhere = workspace.cue.now.elsewhere {
            Label(elsewhere, icon: .mac)
                .font(Typography.meta).foregroundStyle(palette.ink3)
                .lineLimit(1).fixedSize()
                .padding(.trailing, 4)
                .transition(.opacity)
        }
    }
}
#endif
