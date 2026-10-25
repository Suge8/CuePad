import CueStore
import SwiftUI

/// 等你列里拍板的一件（待回复是 `BoardReplyCard`）：和 Cue 页的拍板卡同一套写法，一件一张纸（`paper`，同看板别的卡）。从上到下：
/// 眉题（`CueWaitEyebrow` 的 `board`：项目、哪件事，点了去任务或会话，等了多久）、问句（`CueWaitQuestion`，正文字号；规矩那一类引他的原话）、
/// 怎么答（`WaitAnswer`，主动作靠右下角）。不带图：带点名图的提问（审美、带证据图的）要看了图才定得了，不让在这里盲点"可以"，
/// 回答处换成次级的"看图再定 ›"，去 Cue 页、这一问排到拍板卡最前（`askOnCuePage`）；与按钮同高，卡高不变。
/// Mac 上照看板卡的语法，项目名与等了多久在悬停提示里。手机竖版看板里卡铺满格，怎么答压在卡底。
struct BoardWaitCard: View {
    let wait: TaskBoard.Wait
    @Environment(Workspace.self) private var workspace
    @Environment(\.boardRow) private var row

    var body: some View {
        VStack(alignment: .leading, spacing: Self.gap) {
            CueWaitEyebrow(wait: wait, place: .board)
            CueWaitQuestion(wait: wait, dense: true)
            if row { Spacer(minLength: 0) }
            answer.padding(.top, Self.gap)
        }
        .padding(.horizontal, TaskMetrics.cardPadding).padding(.vertical, Self.vertical)
        .frame(maxWidth: .infinity, maxHeight: row ? .infinity : nil, alignment: .topLeading)
        .paper(radius: TaskMetrics.cardRadius)
        #if os(macOS)
        .help(Dotted(workspace.catalog?.project(wait.shownProject)?.name, PiClock.Waited(since: wait.since).format(.now)).visible)
        #endif
        .boardDim(project: wait.project)
    }

    @ViewBuilder private var answer: some View {
        if let message = wait.message, !message.shots.isEmpty {
            Button { workspace.askOnCuePage(message.id) } label: {
                HStack(spacing: 4) {
                    Text("看图再定")
                    Image(.forward).font(.system(size: 9, weight: .bold))
                }
            }
            .buttonStyle(ControlButtonStyle(kind: .secondary))
            .accessibilityHint("去 Cue 页看图回答")
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            WaitAnswer(wait: wait.wait)
        }
    }

    /// 眉题、问句、怎么答之间。
    private static let gap: CGFloat = 6
    private static let vertical: CGFloat = 8
}

/// 等你卡上回答会话的一行：草稿就是会话页回复框那一份（`AppSettings.replyDraft`，两处写的是同一句），发出同会话页的作答
/// （`Workspace.speak`：会话在等 CuePad 答得了的提问时这句就是答案，选项写原文或序号）；只发文字，草稿里的卡片与图片留给会话页。
/// 同步到不了 Mac 时不能发（同回复框）。
struct BoardReply: View {
    let session: PiSessionState
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @FocusState private var writing: Bool

    private var box: Binding<ComposerDraft> { services.settings.replyDraftBinding(for: session.id) }
    private var canSend: Bool { services.reachesPiHost && !box.wrappedValue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        // 一行时字与发送钮同一条中线（字的格至少与钮同高、竖直居中）；写成几行长高时钮贴在最后一行旁（底对齐，上下边距让最后一行对着钮的中线）
        HStack(alignment: .bottom, spacing: 6) {
            TextField("回答", text: box.text, palette: palette, axis: .vertical)
                .textFieldStyle(.plain).font(Typography.secondary).lineLimit(1...4)
                .padding(.vertical, Self.textInset)
                .frame(minHeight: ComposerMetrics.glyphTarget)
                .focused($writing)
                .onSubmit(send)
            Button(action: send) { SendGlyph(canSend ? .ready : .idle) }
                .buttonStyle(PressStyle(.button))
                .disabled(!canSend)
                .accessibilityLabel("回答")
        }
        .padding(.leading, 12).padding(.trailing, 3).padding(.vertical, 3)
        .background(palette.fill, in: .rect(cornerRadius: 18, style: .continuous))
        #if os(iOS)
        .staysAboveKeyboard(while: writing, text: box.wrappedValue.text)
        .preference(key: BoardReplying.self, value: writing)
        #endif
    }

    /// 字上下各让出的空：一行字（约 16）加两边正好是钮的点按高，多行时最后一行仍落在钮的中线附近。
    private static let textInset: CGFloat = 12

    private func send() {
        guard canSend else { return }
        _ = workspace.speak(to: .session(session, mode: .send), from: box, keeping: { var kept = $0; kept.text = ""; return kept }) { draft in
            draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

#if os(iOS)
/// 看板里有回答框正在写（手机竖版看板据此让别的行退开，`PhoneBoard`）。
struct BoardReplying: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
#endif
