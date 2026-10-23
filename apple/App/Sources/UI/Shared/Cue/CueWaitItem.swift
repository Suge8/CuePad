import CueStore
import SwiftUI

/// 等你卡（`CueWaitDock`）里铺开的那一件，按部分排（卡按地方挑排哪几部分）：
/// - 问句（`question`）：赭黄问号、标题字的问句（`TaskBoard.Wait.asked`），下一行 Cue 的提问是它依据的规矩与范围（最淡的墨、小一号，同进展页等你列），
///   会话的是问题的说明（选项不写进来）；右上角等了多久；Cue 的原话展开时接在下面（`reading`）。
/// - 点名的图（`shots`，Cue 的提问才有，`CueShots`；点开全屏时底栏就是这几个选项，看完当场定）。
/// - 怎么答（`answer`，`WaitAnswer`）；"可以"选的是其中一张图时，那张描靛青圈、选项旁一句"要选别的，在下面跟 Cue 说"。
/// - 末行（`footer`）：Cue 的提问落在的任务（`CueTaskLine`）与原话的开关（`CueOriginalToggle`）；会话在问的没有。
struct CueWaitItem: View {
    enum Part { case question, shots, answer, footer }

    let wait: TaskBoard.Wait
    let part: Part
    let tasks: [UUID: CueTaskRef]
    let shots: [UUID: [CueShown]]
    let open: (PreviewOpening) -> Void
    @Binding var reading: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    /// 末行可点的高。
    static let footerHeight: CGFloat = 44

    var body: some View {
        switch part {
        case .question: question
        case .shots:
            if let message = wait.message, let shown = shots[message.id] {
                CueShots(shots: shown, group: "waiting", reply: .answer(message), chosen: chosen(message), open: open)
            }
        case .answer:
            WaitAnswer(wait: wait.wait, hint: wait.message.flatMap(chosen).map { _ in "要选别的，在下面跟 \(workspace.cue.name) 说" })
        case .footer:
            if let message = wait.message {
                HStack(spacing: 20) {
                    if let ref = message.taskID.flatMap({ tasks[$0] }) { CueTaskLine(ref: ref, height: Self.footerHeight) }
                    CueOriginalToggle(open: $reading, height: Self.footerHeight)
                }
            }
        }
    }

    /// 点名的几张图里"可以"选的那张（`CueShots.chosen`）。
    private func chosen(_ message: CueMessage) -> UUID? {
        shots[message.id].flatMap { CueShots.chosen(for: message.asking, in: $0) }
    }

    private var question: some View {
        let asked = wait.asked
        let below: (text: String, basis: Bool)? = switch wait.wait {
        case .message(let message, _): workspace.waitBasis(of: message).map { ($0, true) }
        case .session: asked.detail.map { ($0, false) }
        }
        return HStack(alignment: .firstTextBaseline, spacing: 9) {
            PiStateGlyph(status: .asking).font(Typography.title)
            VStack(alignment: .leading, spacing: 4) {
                Text(CueQuestionLine<EmptyView>.keepingTail(asked.line)).font(Typography.title).foregroundStyle(palette.ink)
                if let below {
                    Text(below.text).font(below.basis ? Typography.caption : Typography.secondary).foregroundStyle(below.basis ? palette.ink3 : palette.ink2)
                }
                if reading, let message = wait.message {
                    MarkdownText(source: message.text).equatable().font(Typography.secondary).foregroundStyle(palette.ink2)
                        .padding(.top, 8).transition(.opacity)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            LiveText(style: PiClock.Elapsed(since: wait.since)).font(Typography.caption.monospacedDigit()).foregroundStyle(palette.ink3).fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 等你卡顶上那一排：在等的每一件（谁在问 + 哪件事），选中的铺一块底；放不下横着滚，打开时选中的那件滚进来。
/// 会话在问、又不是只能去会话里答的，尾端一个"打开会话"（只能去会话里答的，答法本身就是它）。
struct CueWaitStrip: View {
    let waiting: [TaskBoard.Wait]
    let current: TaskBoard.Wait
    let pick: (String) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    #if os(macOS)
    static let height: CGFloat = 26
    #else
    static let height: CGFloat = 32
    #endif
    /// 一件的名字至多这么宽：长会话名、长任务名截掉尾巴，不把别的件挤出去。
    private static let titleWidth: CGFloat = 150

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 2) { ForEach(waiting) { chip($0).id($0.id) } }
                        .padding(.horizontal, CueWaitDock.side - Self.chipInset)
                }
                .task(id: current.id) {
                    // 排好一帧再滚：头一次排版时各件的宽还没定
                    await NextFrame.wait()
                    proxy.scrollTo(current.id)
                }
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            if case .session(let session, _) = current.wait, session.answerableQuestion != nil || session.question == nil {
                Button { workspace.openSession(session.id, sessionID: session.sessionID) } label: {
                    HStack(spacing: 3) {
                        Text("打开会话")
                        Image(.forward).font(.system(size: 8, weight: .bold))
                    }
                    .font(Typography.caption.weight(.medium)).foregroundStyle(palette.ink2)
                    .padding(.horizontal, Self.chipInset).frame(minHeight: Self.height).contentShape(.capsule)
                }
                .buttonStyle(PressStyle())
                .fixedSize()
                .padding(.trailing, CueWaitDock.side - Self.chipInset)
            }
        }
    }

    private static let chipInset: CGFloat = 9

    private func chip(_ wait: TaskBoard.Wait) -> some View {
        let selected = wait.id == current.id
        return Button { pick(wait.id) } label: {
            HStack(spacing: 6) {
                WaitAsker(wait: wait.wait, size: 16)
                Text(wait.title(cue: workspace.cue.name)).lineLimit(1).frame(maxWidth: Self.titleWidth, alignment: .leading).fixedSize()
            }
            .font(Typography.caption.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? palette.ink : palette.ink2)
            .padding(.horizontal, Self.chipInset).frame(height: Self.height)
            .background(selected ? palette.fill : .clear, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(PressStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
