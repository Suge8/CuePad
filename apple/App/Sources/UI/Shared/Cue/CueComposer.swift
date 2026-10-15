import SwiftUI

/// "对 Cue 说"的输入框（全 App 只此一个）：草稿是 Cue 的那一份（`CueWatch.draft`），可带图片；没启用时发不出去。
/// 发出走 `Workspace.speak`（按下就清空输入框，不等上传），这里只管输入与发完之后做什么（`sent`）。
/// Cue 页上工具排里是 Cue 的模型与思考强度（`CueConfigControls`，形态同会话页回复框；Mac 上 ⌘⇧M、⌘⇧E 弹出菜单）；浮起的输入条不放。
struct CueComposer: View {
    enum Style: Equatable {
        /// Cue 页底部：Mac 一直展开，手机一行、聚焦就展开（工具排出现），发完收起键盘。
        case page
        /// 浮起的输入条（⌥⇧Space）：一直展开；`opens` 每变一次（又唤出了）就拿到焦点。
        case bar(opens: Int)
    }

    let style: Style
    var sent: () -> Void = {}
    @Environment(Workspace.self) private var workspace
    @FocusState private var focused: Bool
    /// ⌘⇧M、⌘⇧E 请模型或思考强度弹出菜单（Mac）。
    @State private var opening: PiConfigPick?

    var body: some View {
        let cue = workspace.cue
        Composer(
            draft: Bindable(cue).draft, prompt: cue.canHear ? "对 \(cue.name) 说" : "启用后才能对 \(cue.name) 说", label: "对 \(cue.name) 说",
            focus: $focused, accepts: .images,
            form: form, shortcuts: shortcuts,
            header: { EmptyView() },
            tools: { if style == .page { CueConfigControls(opening: $opening) } },
            send: {
                Button(action: send) { SubmitGlyph(.send, enabled: cue.canHear) }
                    .buttonStyle(.plain).disabled(!cue.canHear)
                    .accessibilityLabel("发送")
                    #if os(macOS)
                    .help("发送（\(ReplyShortcut.send.symbols)）")
                    #endif
            })
            .onChange(of: opens, initial: true) { if opens != nil || style == .page && DebugHooks.preset.cueFocus { focused = true } }
    }

    private var form: ComposerForm {
        #if os(iOS)
        if style == .page { return .line(opensOnFocus: true) }
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
        let cue = workspace.cue, files = workspace.services.store.files
        guard cue.canHear, !cue.draft.isEmpty(accepting: .images) else { return }
        guard workspace.speak(to: .cue, from: Bindable(cue).draft, content: { try $0.stored(in: files) }) != nil else { return }
        #if os(iOS)
        focused = false
        #endif
        sent()
    }
}
