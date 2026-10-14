import SwiftUI

/// "对 Cue 说"的输入框（全 App 只此一个）：草稿是 Cue 的那一份（`CueWatch.draft`），可带图片；没启用时发不出去。
/// 发出与清空草稿在 `Workspace.sayToCue`，这里只管输入与发完之后做什么（`sent`）。
struct CueComposer: View {
    enum Style: Equatable {
        /// Cue 页底部：Mac 一直展开，手机一行、点了才展开，发完收起键盘。
        case page
        /// 浮起的输入条（⌥⇧Space）：一直展开；`opens` 每变一次（又唤出了）就拿到焦点。
        case bar(opens: Int)
    }

    let style: Style
    var sent: () -> Void = {}
    @Environment(Workspace.self) private var workspace
    @FocusState private var focused: Bool
    @State private var sending = false

    var body: some View {
        let cue = workspace.cue
        Composer(
            draft: Bindable(cue).draft, prompt: cue.canHear ? "对 \(cue.name) 说" : "启用后才能对 \(cue.name) 说", label: "对 \(cue.name) 说",
            focus: $focused, accepts: .images,
            form: form, shortcuts: [.send: send],
            header: { EmptyView() }, tools: { EmptyView() },
            send: {
                Button(action: send) { SubmitGlyph(.send, enabled: !sending && cue.canHear) }
                    .buttonStyle(.plain).disabled(sending || !cue.canHear)
                    .accessibilityLabel("发送")
                    #if os(macOS)
                    .help("发送（\(ReplyShortcut.send.symbols)）")
                    #endif
            })
            .onChange(of: opens, initial: true) { if opens != nil { focused = true } }
    }

    private var form: ComposerForm {
        #if os(iOS)
        if style == .page { return .line(opensOnFocus: false) }
        #endif
        return .open
    }

    private var opens: Int? { if case .bar(let opens) = style { opens } else { nil } }

    private func send() {
        guard !sending, workspace.cue.canHear, !workspace.cue.draft.isEmpty(accepting: .images) else { return }
        sending = true
        workspace.attempt {
            defer { sending = false }
            try await workspace.sayToCue()
            #if os(iOS)
            focused = false
            #endif
            sent()
        }
    }
}
