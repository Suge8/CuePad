#if os(macOS)
import SwiftUI

/// "对 Cue 说"输入条的内容（`CueBar`）：上面一行头像、名字与此刻在做什么（有等你的写"等你 N"），下面是一直展开的输入框（可带图片）。
/// 说出去就收起；草稿与 Cue 页同一份（`CueWatch.draft`），没说完收起了，在 Cue 页里接着写。
struct CueBarView: View {
    /// 调试画面里放在桌面图上拍时没有宿主。
    let bar: CueBar?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @FocusState private var focused: Bool
    @State private var sending = false

    var body: some View {
        let cue = workspace.cue
        VStack(alignment: .leading, spacing: 8) {
            CueStatusRow()
                .padding(.horizontal, 14).padding(.vertical, 10)
                .glass(in: .rect(cornerRadius: 22))
            Composer(
                draft: Bindable(cue).draft, prompt: cue.canHear ? "对 \(cue.name) 说" : "启用后才能对 \(cue.name) 说", label: "对 \(cue.name) 说", focus: $focused, accepts: .images,
                form: .open, shortcuts: [.send: send],
                header: { EmptyView() }, tools: { EmptyView() },
                send: {
                    Button(action: send) { SubmitGlyph(.send, enabled: !sending && cue.canHear) }
                        .buttonStyle(.plain).disabled(sending || !cue.canHear)
                        .accessibilityLabel("发送")
                        .help("发送（\(ReplyShortcut.send.symbols)）")
                })
        }
        .frame(width: 560)
        .onChange(of: bar?.opens, initial: true) { focused = true }
    }

    private func send() {
        let draft = workspace.cue.draft
        guard !sending, workspace.cue.canHear, !draft.isEmpty(accepting: .images) else { return }
        sending = true
        workspace.attempt {
            defer { sending = false }
            try await workspace.sayToCue(draft)
            workspace.cue.draft = ComposerDraft()
            bar?.hide()
        }
    }
}

#endif

import SwiftUI

/// 一行 Cue 的现状（侧栏最上面、菜单栏面板、输入条）：头像、名字、此刻在做什么或它最近一句，有等你的写"等你 N"（赭黄）。
struct CueStatusRow<Trailing: View>: View {
    var font = Typography.body.weight(.semibold)
    @ViewBuilder var trailing: Trailing
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let cue = workspace.cue
        HStack(spacing: 10) {
            CueAvatar(mood: cue.mood(), presence: cue.presence, size: .row)
            VStack(alignment: .leading, spacing: 1) {
                Text(cue.name).font(font).foregroundStyle(palette.ink).lineLimit(1)
                if let line = cue.presence.line(name: cue.name) ?? cue.digest.lastSaid {
                    Text(line).font(Typography.meta).foregroundStyle(cue.presence.isUnreachable ? palette.failure : palette.ink3).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            CueWaitingBadge(count: cue.digest.waiting)
            trailing
        }
        .animation(Motion.quick, value: cue.digest)
    }
}

extension CueStatusRow where Trailing == EmptyView {
    init(font: Font = Typography.body.weight(.semibold)) { self.init(font: font) { EmptyView() } }
}

/// "等你 N"：赭黄的字（等你确认的颜色），没有在等的不画。Mac 侧栏、菜单栏面板、iPad 侧栏用它；iPhone 底栏是角标。
struct CueWaitingBadge: View {
    let count: Int
    @Environment(\.palette) private var palette

    var body: some View {
        if count > 0 {
            Text("等你 \(count)").font(Typography.meta.weight(.semibold)).monospacedDigit().foregroundStyle(palette.attention)
                .fixedSize()
                .transition(.opacity)
        }
    }
}
