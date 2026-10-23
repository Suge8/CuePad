import CueStore
import SwiftUI

/// 等你列的一件，排版只在这一个视图里（不包卡片，像 Cue 页里对你说的一句）。从上到下：
/// - 抬头一行：项目小图形（看全部项目时；选了项目范围不画；Mac 上悬停是项目联动，`BoardProjectGlyph`）、哪件事（`TaskBoard.Wait.title`；
///   做完了还在问的也照常写、不划线），右边是等了多久（`TaskBoard.Wait.since`）。谁在问不写在这里，只靠头像。点抬头去回答的地方（`BoardLink`）：
///   会话在问的进会话，Cue 问的去 Cue 页那条提问。
/// - 谁在问贴在左下（Cue 的头像，会话在问的是圆里这家 Agent 的品牌标，同推进中的会话卡，`WaitAsker`），旁边一颗 Cue 页同款的气泡（`cueBubble`，泳道上是纯白）：
///   问句（`TaskBoard.Wait.asked`）；Cue 的提问下一行是它依据的规矩与范围（"推送代码前先问你 · 圆桌"，小一号、最淡的墨），会话的是问题的说明（选项不写进来）。
/// - 气泡下方是怎么答（`WaitAnswer`，按问题种类给，靠右）；回答框左边让出头像那一格。
struct BoardWaitCard: View {
    let wait: TaskBoard.Wait
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Self.gap) {
            header.padding(.horizontal, Self.headerInset)
            HStack(alignment: .bottom, spacing: Self.whoGap) {
                WaitAsker(wait: wait.wait, size: Self.who, ringed: true).frame(width: Self.who)
                bubble
            }
            WaitAnswer(wait: wait.wait, compact: true).padding(.leading, replies ? Self.who + Self.whoGap : 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 不包卡片，件与件之间靠多留的这一截空分开
        .padding(.bottom, Self.apart)
        .boardDim(project: wait.project)
    }

    /// 答法是回答框（文字题、Cue 留给你回的）：它左边让出头像那一格，选项靠右不让。
    private var replies: Bool {
        guard case .session(let session, _) = wait.wait else { return false }
        return session.answerableQuestion?.kind.known == .text || session.question == nil
    }

    private var bubble: some View {
        let asked = wait.asked
        return VStack(alignment: .leading, spacing: 3) {
            Text(CueQuestionLine.keepingTail(asked.line)).font(Self.questionFont).foregroundStyle(palette.ink)
            switch wait.wait {
            case .message(let message, _):
                if let basis = workspace.waitBasis(of: message) { Text(basis).font(Self.basisFont).foregroundStyle(palette.ink3) }
            case .session:
                if let detail = asked.detail { Text(detail).font(TaskMetrics.caption).foregroundStyle(palette.ink2) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cueBubble(joined: false, onLane: true)
    }

    private var header: some View {
        BoardLink(to: destination) {
            HStack(spacing: 6) {
                if workspace.scopedProject == nil, let project = workspace.catalog?.project(wait.project) {
                    BoardProjectGlyph(project: project)
                }
                Text(wait.title(cue: workspace.cue.name)).foregroundStyle(palette.ink2).lineLimit(1)
                Spacer(minLength: 8)
                LiveText(style: PiClock.Elapsed(since: wait.since)).monospacedDigit().foregroundStyle(palette.ink3)
            }
            .font(TaskMetrics.caption)
        }
    }

    private var destination: BoardDestination {
        switch wait.wait {
        case .message(let message, _): .question(message.id)
        case .session(let session, _): .session(session)
        }
    }

    /// 抬头、气泡、操作之间。
    private static let gap: CGFloat = 8
    /// 抬头的字对着气泡圆角里的字，往里让一点。
    private static let headerInset: CGFloat = 4
    /// 件与件之间比列里的行距多留的空。
    private static let apart: CGFloat = 6
    /// 谁在问那一格多宽、离气泡多远。
    private static let whoGap: CGFloat = 8
    #if os(macOS)
    private static let who: CGFloat = 22
    private static let questionFont = Typography.body.weight(.medium)
    private static let basisFont = Typography.caption2
    #else
    private static let who: CGFloat = 28
    private static let questionFont = Font.body.weight(.medium)
    private static let basisFont = Font.caption
    #endif
}

/// 等你卡上回答会话的一行：草稿就是会话页回复框那一份（`AppSettings.replyDraft`，两处写的是同一句），发出同会话页的作答
/// （`Workspace.speak`：会话在等 CuePad 答得了的提问时这句就是答案，选项写原文或序号）；只发文字，草稿里的卡片与图片留给会话页。
/// 同步到不了 Mac 时不能发（同回复框）。
struct BoardReply: View {
    let session: PiSessionState
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    private var box: Binding<ComposerDraft> { services.settings.replyDraftBinding(for: session.id) }
    private var canSend: Bool { services.reachesPiHost && !box.wrappedValue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        // 一行时字与发送钮同一条中线（字的格至少与钮同高、竖直居中）；写成几行长高时钮贴在最后一行旁（底对齐，上下边距让最后一行对着钮的中线）
        HStack(alignment: .bottom, spacing: 6) {
            TextField("回答", text: box.text, palette: palette, axis: .vertical)
                .textFieldStyle(.plain).font(Typography.secondary).lineLimit(1...4)
                .padding(.vertical, Self.textInset)
                .frame(minHeight: ComposerMetrics.glyphTarget)
                .onSubmit(send)
            Button(action: send) { SendGlyph(canSend ? .ready : .idle) }
                .buttonStyle(PressStyle(.button))
                .disabled(!canSend)
                .accessibilityLabel("回答")
        }
        .padding(.leading, 12).padding(.trailing, 3).padding(.vertical, 3)
        .background(palette.fill, in: .rect(cornerRadius: 18, style: .continuous))
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
