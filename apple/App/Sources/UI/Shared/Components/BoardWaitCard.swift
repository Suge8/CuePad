import CueStore
import SwiftUI

/// 等你列的一张卡，卡里的排版只在这一个视图里。从上到下：
/// - 抬头一行：项目小图标（看全部项目时；选了项目范围不画）、标题（会话在问的写会话名，Cue 问的写它落在的任务，Cue 的一般提问写 Cue 的名字；
///   做完了还在问的也照常写、不划线），右边是等了多久（`TaskBoard.Wait.since`）。点抬头去回答的地方（`BoardLink`）：会话在问的进会话，
///   Cue 问的去 Cue 页那条提问。
/// - 要你定什么：Cue 的提问是问句（`CueMessage.headline`），下面一行它依据的规矩与范围（"推送代码前先问你 · 圆桌"，`basis`），再下面是选项——
///   "可以"是实底主按钮（全卡唯一的靛青），"以后「圆桌」里……不用问"写成"以后不用问"（范围上一行已经写了），答的方法同
///   `AppServices.answerCueQuestion`；会话在问的是整段问题连同选项与回答框（`BoardReply`，回答框里写选项原文或序号）。
struct BoardWaitCard: View {
    let wait: TaskBoard.Wait
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    /// 正在答的那条（写成后它从等你里消失，写不成就清掉）。
    @State private var ending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            switch wait.wait {
            case .message(let message, _):
                question(message.headline ?? "")
                if let basis = basis(of: message) {
                    Text(basis).font(TaskMetrics.caption).foregroundStyle(palette.ink3).padding(.top, 3)
                }
                choices(message).padding(.top, Self.actionGap)
            case .session(let session, _):
                // Cue 留给你回的是它最后那句的首句
                question(session.question?.displayText ?? PiProgress.line(of: session) ?? workspace.shown(session, delivery: nil).label)
                BoardReply(session: session).padding(.top, Self.actionGap)
            }
        }
        .padding(TaskMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paper(radius: TaskMetrics.cardRadius)
    }

    private var header: some View {
        BoardLink(to: destination) {
            HStack(spacing: 6) {
                if workspace.scopedProject == nil, let project = workspace.catalog?.project(wait.project) {
                    ProjectGlyph(project: project, size: Self.glyph)
                }
                Text(title).foregroundStyle(palette.ink2).lineLimit(1)
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

    /// 会话在问的写会话名（点了进的就是它），Cue 问的写落在的任务，没落在任务上的写 Cue 的名字。
    private var title: String {
        if case .session(let session, _) = wait.wait { return session.title }
        return wait.item?.task.title ?? workspace.cue.name
    }

    /// 要你定什么那一句。不画问号：列名已经说了在等你。
    private func question(_ text: String) -> some View {
        Text(CueQuestionLine.keepingTail(text))
            .font(Self.questionFont).foregroundStyle(palette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
    }

    /// 依据的规矩与范围："推送代码前先问你 · 圆桌"；规矩那一类是他的原话。认不出类别的旧提问没有这一行。
    private func basis(of message: CueMessage) -> String? {
        guard let asking = message.asking else { return nil }
        let scope = message.asked?.project.flatMap { workspace.catalog?.project($0)?.name }
        return Dotted(asking.rule ?? "\(asking.ask.name)前先问你", scope).visible
    }

    @ViewBuilder private func choices(_ message: CueMessage) -> some View {
        let options = message.choices ?? []
        let buttons = ForEach(Array(options.enumerated()), id: \.offset) { index, option in
            Button(Self.label(option, at: index)) { answer(message, option) }
                .buttonStyle(ControlButtonStyle(kind: index == 0 ? .primary : .quiet, compact: true))
                .accessibilityLabel(option)
                .disabled(ending)
        }
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) { buttons }
        } else {
            HStack(spacing: 4) { buttons }
        }
    }

    /// 选项上写的字：第一项照写，"以后……不用问"收成"以后不用问"（范围在规矩那一行）；答的仍是原文。
    private static func label(_ option: String, at index: Int) -> String {
        index > 0 && option.hasPrefix("以后") && option.hasSuffix("不用问") ? "以后不用问" : option
    }

    private func answer(_ message: CueMessage, _ choice: String) {
        ending = true
        workspace.attempt {
            defer { ending = false }
            try await workspace.services.answerCueQuestion(message.id, choice)
        }
    }

    private static let actionGap: CGFloat = 12
    #if os(macOS)
    private static let glyph: CGFloat = 10
    private static let questionFont = Font.system(size: 15, weight: .semibold)
    #else
    private static let glyph: CGFloat = 12
    private static let questionFont = Font.headline
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
        HStack(alignment: .bottom, spacing: 6) {
            TextField("回答", text: box.text, palette: palette, axis: .vertical)
                .textFieldStyle(.plain).font(Typography.secondary).lineLimit(1...4)
                .padding(.vertical, 7)
                .onSubmit(send)
            Button(action: send) { SendGlyph(canSend ? .ready : .idle) }
                .buttonStyle(PressStyle(.button))
                .disabled(!canSend)
                .accessibilityLabel("回答")
        }
        .padding(.leading, 12).padding(.trailing, 3).padding(.vertical, 3)
        .background(palette.fill, in: .rect(cornerRadius: 18, style: .continuous))
    }

    private func send() {
        guard canSend else { return }
        _ = workspace.speak(to: .session(session, mode: .send), from: box, keeping: { var kept = $0; kept.text = ""; return kept }) { draft in
            draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
