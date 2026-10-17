import SwiftUI

/// "对 Cue 说"的输入框（全 App 只此一个）：草稿是 Cue 的那一份（`CueWatch.draft`），可带图片。要做事就在这里说，随手记也在这里：
/// 发送是对 Cue 说（它定项目、建任务、开工），长按发送是"只记下"——记成未分类的一条灵感，不交给它；Cue 没启用时发送就是记下
/// （`Workspace.sayToCue`、`note`）。按下就清空输入框，不等上传；这里只管输入与发完之后做什么（`sent`）。
/// Mac 的 Cue 页上工具排里是 Cue 的模型与思考强度（`CueConfigControls`，形态同会话页回复框；⌘⇧M、⌘⇧E 弹出菜单）；浮起的输入条不放。
/// 手机上它们在 Cue 面板的第一行（`CueHeader`），输入框里不再放一份：聚焦才露出的胶囊找不到。
struct CueComposer: View {
    enum Style: Equatable {
        /// Cue 页底部：Mac 一直展开，手机一行、打了字再长，发完收起键盘。
        case page
        /// 浮起的输入条（⌥⇧Space）：一直展开；`opens` 每变一次（又唤出了）就拿到焦点。
        case bar(opens: Int)
    }

    let style: Style
    /// 每变一次就拿到焦点（手机的 ⌘⇧N、随手记小组件，`Navigation.cueFocusRequests`）。
    var focusRequests = 0
    var sent: () -> Void = {}
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    /// 刚发出、还没读到"话在路上"：库里那条记录要下一次读库才变成 `CuePresence.sending`，这一小段钮先当帧换成发送中，
    /// 不先缩没再长出来。Cue 的现状一变（读到了在路上，或已经不在路上）就交还给它。
    @State private var launched = false
    /// 光从发送钮的箭镞起飞、落进 Cue 的头像。
    @State private var launch = RelayLaunch()
    #if os(macOS)
    /// ⌘⇧M、⌘⇧E 请模型或思考强度弹出菜单。
    @State private var opening: PiConfigPick?
    #endif

    var body: some View {
        let cue = workspace.cue
        Composer(
            draft: Bindable(cue).draft, prompt: cue.canHear ? "对 \(cue.name) 说" : "记一条灵感",
            label: "对 \(cue.name) 说",
            focus: $focused, accepts: .images,
            form: form, showsSendEmpty: sending, shortcuts: shortcuts,
            header: { EmptyView() },
            tools: { tools },
            send: { sendButton })
            .onChange(of: opens, initial: true) { if opens != nil || style == .page && DebugHooks.preset.cueFocus { focused = true } }
            .onChange(of: focusRequests) { focused = true }
            .onChange(of: workspace.cue.presence) { launched = false }
            .task { if style == .page { await DebugHooks.pressCueSendIfAsked(send) } }
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

    @ViewBuilder private var tools: some View {
        #if os(macOS)
        if style == .page { CueConfigControls(opening: $opening) }
        #endif
    }

    private var hasDraft: Bool { !workspace.cue.draft.isEmpty(accepting: .images) }
    /// 空着时的发送中：你最近一句还在路上（与气泡、头像同一个事实，`CuePresence.sending`）。
    private var sending: Bool { workspace.cue.canHear && (launched || workspace.cue.presence == .sending) }

    private var form: ComposerForm {
        #if os(iOS)
        if style == .page { return .line(opensOnFocus: false) }
        #endif
        return .open
    }

    private var shortcuts: [ReplyShortcut: () -> Void] {
        var map: [ReplyShortcut: () -> Void] = [.send: send]
        #if os(macOS)
        if style == .page {
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
