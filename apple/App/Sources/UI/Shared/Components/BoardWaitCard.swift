import CueStore
import SwiftUI

/// 等你列的一件，排版只在这一个视图里（方案 A2：不包卡片，像 Cue 页里对你说的一句）。从上到下：
/// - 抬头一行：项目小图形（看全部项目时；选了项目范围不画；Mac 上悬停是项目联动，`BoardProjectGlyph`）、标题（会话在问的写会话名，Cue 问的写它落在的任务，Cue 的一般提问写 Cue 的名字；
///   做完了还在问的也照常写、不划线），右边是等了多久（`TaskBoard.Wait.since`）。点抬头去回答的地方（`BoardLink`）：会话在问的进会话，
///   Cue 问的去 Cue 页那条提问。
/// - 谁在问贴在左下（Cue 的头像 `CueAvatar`，会话在问的是圆里这家 Agent 的品牌标，同推进中的会话卡），旁边一颗 Cue 页同款的气泡（`cueBubble`，泳道上是纯白）：问句（`CueMessage.headline`），
///   下一行它依据的规矩与范围（"推送代码前先问你 · 圆桌"，`basis`）。
/// - 气泡下方：Cue 的提问是选项，靠右——"可以"实心靛青在最右（全卡唯一的靛青），"以后「圆桌」里……不用问"写成"以后不用问"的描边胶囊在它左边
///   （范围气泡里已经写了），答的方法同 `AppServices.answerCueQuestion`；会话在问的是回答框（`BoardReply`），左边让出头像那一格。
struct BoardWaitCard: View {
    let wait: TaskBoard.Wait
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.boardCompact) private var compact
    /// 正在答的那条（写成后它从等你里消失，写不成就清掉）。
    @State private var ending = false

    var body: some View {
        VStack(alignment: .leading, spacing: Self.gap) {
            header.padding(.horizontal, Self.headerInset)
            // 原型 B 的半屏列：谁在问让出那一格，气泡与回答框占满列宽
            HStack(alignment: .bottom, spacing: Self.whoGap) {
                if !compact { asker.frame(width: Self.who) }
                bubble
            }
            switch wait.wait {
            case .message(let message, _): choices(message)
            case .session(let session, _): BoardReply(session: session).padding(.leading, compact ? 0 : Self.who + Self.whoGap)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 不包卡片，件与件之间靠多留的这一截空分开
        .padding(.bottom, Self.apart)
        .boardDim(project: wait.project)
    }

    /// 谁在问：Cue 的头像（此刻的表情），会话在问的是这家 Agent 的品牌标（同推进中的会话卡）。
    @ViewBuilder private var asker: some View {
        switch wait.wait {
        case .message: CueAvatar(mood: workspace.cue.expression, size: Self.avatar)
        case .session(let session, _):
            Group { if let kind = session.agent.known { kind.mark.image } else { Image(.terminal) } }
                .font(.system(size: Self.who * 0.5)).foregroundStyle(palette.ink2)
                .frame(width: Self.who, height: Self.who)
                .background(palette.paper, in: .circle)
                .overlay(Circle().strokeBorder(palette.hair))
                .accessibilityHidden(true)
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch wait.wait {
            case .message(let message, _):
                question(message.headline ?? "")
                if let basis = basis(of: message) { Text(basis).font(TaskMetrics.caption).foregroundStyle(palette.ink3) }
            case .session(let session, _):
                // Cue 留给你回的是它最后那句的首句
                question(session.question?.displayText ?? PiProgress.line(of: session) ?? workspace.shown(session, delivery: nil).label)
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
        Text(CueQuestionLine.keepingTail(text)).font(compact ? .subheadline.weight(.medium) : Self.questionFont).foregroundStyle(palette.ink)
    }

    /// 依据的规矩与范围："推送代码前先问你 · 圆桌"；规矩那一类是他的原话。认不出类别的旧提问没有这一行。
    private func basis(of message: CueMessage) -> String? {
        guard let asking = message.asking else { return nil }
        let scope = message.asked?.project.flatMap { workspace.catalog?.project($0)?.name }
        return Dotted(asking.rule ?? "\(asking.ask.name)前先问你", scope).visible
    }

    @ViewBuilder private func choices(_ message: CueMessage) -> some View {
        let options = message.choices ?? []
        // 主选项在最右：从右往左排，读屏仍按选项原来的先后念
        let buttons = ForEach(Array(options.enumerated()).reversed(), id: \.offset) { index, option in
            Button(Self.label(option, at: index)) { answer(message, option) }
                .buttonStyle(ControlButtonStyle(kind: index == 0 ? .primary : .secondary, compact: true))
                .accessibilityLabel(option)
                .accessibilitySortPriority(Double(options.count - index))
                .disabled(ending)
        }
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .trailing, spacing: 6) { buttons }
            } else {
                HStack(spacing: 6) { buttons }
            }
        }
        .accessibilityElement(children: .contain)
        .frame(maxWidth: .infinity, alignment: .trailing)
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
    private static let avatar = CueAvatar.Size.inline
    private static let questionFont = Typography.body.weight(.medium)
    #else
    private static let who: CGFloat = 28
    private static let avatar = CueAvatar.Size.inline
    private static let questionFont = Font.body.weight(.medium)
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
