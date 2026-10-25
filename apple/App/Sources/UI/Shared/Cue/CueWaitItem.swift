import CueStore
import SwiftUI

/// 等你卡（`CueWaitDock`）里铺开的那一件，按部分排（卡按地方挑排哪几部分）：
/// - 问句（`question`）：赭黄问号、标题字的问句（`TaskBoard.Wait.asked`）；会话的问题有说明时（选项不写进来）接在下一行；
///   再下一行是来源与等了多久（最淡的墨、小一号）："推送代码前先问你 · 圆桌 · 已等 38 分钟"，会话的是"Codex 在会话里问你 · 刚刚"；
///   Cue 的原话展开时接在下面（`reading`，开关在眉题行）。
/// - 点名的图（`shots`，Cue 的提问才有，`CueShots`；点开全屏时底栏就是这几个选项，看完当场定）。
/// - 怎么答（`answer`，`WaitAnswer`）：主动作靠右下角，次要的在同一行左边；"可以"选的是其中一张图时，那张描靛青圈、左边一句"要选别的，在下面跟 Cue 说"。
/// 这件事是哪件、第几件在卡顶的眉题行（`CueWaitEyebrow`）。
struct CueWaitItem: View {
    enum Part { case question, shots, answer }

    let wait: TaskBoard.Wait
    let part: Part
    let shots: [UUID: [CueShown]]
    let open: (PreviewOpening) -> Void
    @Binding var reading: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        switch part {
        case .question: question
        case .shots:
            if let message = wait.message, let shown = shots[message.id] {
                CueShots(shots: shown, group: "waiting", reply: .answer(message), chosen: chosen(message), open: open)
            }
        case .answer:
            WaitAnswer(wait: wait.wait, hint: wait.message.flatMap(chosen).map { _ in "要选别的，在下面跟 \(workspace.cue.name) 说" })
        }
    }

    /// 点名的几张图里"可以"选的那张（`CueShots.chosen`）。
    private func chosen(_ message: CueMessage) -> UUID? {
        shots[message.id].flatMap { CueShots.chosen(for: message.asking, in: $0) }
    }

    private var question: some View {
        let asked = wait.asked
        let detail: String? = if case .session = wait.wait { asked.detail } else { nil }
        return HStack(alignment: .firstTextBaseline, spacing: 9) {
            PiStateGlyph(status: .asking).font(Typography.title)
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(CueQuestionLine<EmptyView>.keepingTail(asked.line)).font(Typography.title).foregroundStyle(palette.ink)
                    if let detail { Text(detail).font(Typography.secondary).foregroundStyle(palette.ink2) }
                }
                .accessibilityElement(children: .combine)
                LiveText(style: PiClock.Waited(since: wait.since)) { Text(Dotted(source, $0)) }
                    .font(Typography.caption).foregroundStyle(palette.ink3)
                if reading, let message = wait.message {
                    MarkdownText(source: message.text).equatable().font(Typography.secondary).foregroundStyle(palette.ink2)
                        .padding(.top, 8).transition(.opacity)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 谁问的、凭什么问：Cue 的提问是它依据的规矩与范围（`waitBasis`，旧提问没有），会话的是哪家 Agent 在会话里问你。
    private var source: String? {
        switch wait.wait {
        case .message(let message, _): workspace.waitBasis(of: message)
        case .session(let session, _): "\(session.agent.known?.name ?? "Agent") 在会话里问你"
        }
    }
}

/// 等你卡顶上的眉题行：这件事的名字（`TaskBoard.Wait.title`：任务名或会话名，小号淡墨），点它去那件事——Cue 的提问打开它落在的任务
/// （`CueTaskButton`，接力也落在这里），会话在问的进会话（打开会话的入口就是它）；没落在任务上的提问写 Cue 的名字、不可点。
/// 右边是 Cue 原话的开关（`CueOriginalToggle`，Cue 的提问才有）与"1/3"第几件（只有一件不写）；Mac 上计数两边各一颗小箭头换一件（`step`），
/// 手机上左右滑卡换（`CueWaitDock`）。
struct CueWaitEyebrow: View {
    let wait: TaskBoard.Wait
    let index: Int
    let count: Int
    @Binding var reading: Bool
    let step: (Int) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    static let height: CGFloat = 20

    var body: some View {
        HStack(spacing: 4) {
            name
            Spacer(minLength: 12)
            if wait.message != nil { CueOriginalToggle(open: $reading).padding(.trailing, count > 1 ? 8 : 0) }
            if count > 1 { position }
        }
        .font(Typography.caption)
        .foregroundStyle(palette.ink3)
        .frame(height: Self.height)
    }

    @ViewBuilder private var name: some View {
        let title = wait.title(cue: workspace.cue.name)
        switch wait.wait {
        case .message(let message, _):
            if let task = wait.item?.task.id ?? message.taskID {
                CueTaskButton(task: task) { label(title, linked: true).relaySpot(task: task) }
                    .accessibilityHint("打开任务")
            } else {
                label(title, linked: false)
            }
        case .session(let session, _):
            Button { workspace.openSession(session.id, sessionID: session.sessionID) } label: { label(title, linked: true) }
                .buttonStyle(PressStyle())
                .accessibilityHint("打开会话")
        }
    }

    private func label(_ title: String, linked: Bool) -> some View {
        HStack(spacing: 3) {
            Text(title).lineLimit(1)
            if linked { Image(.forward).font(.system(size: 8, weight: .bold)) }
        }
        // 小字本身矮：点得到的范围往上下扩，不撑高这一行
        .contentShape(.rect.inset(by: -Self.reach))
    }

    @ViewBuilder private var position: some View {
        #if os(macOS)
        arrow(.back, by: -1, enabled: index > 0, label: "上一件")
        #endif
        Text("\(index + 1)/\(count)").monospacedDigit()
            .accessibilityLabel("第 \(index + 1) 件，共 \(count) 件")
        #if os(macOS)
        arrow(.forward, by: 1, enabled: index < count - 1, label: "下一件")
        #endif
    }

    #if os(macOS)
    private func arrow(_ icon: Icon, by offset: Int, enabled: Bool, label: String) -> some View {
        Button { step(offset) } label: {
            Image(icon).font(.system(size: 9, weight: .bold)).frame(width: Self.height, height: Self.height).contentShape(.rect)
        }
        .buttonStyle(PressStyle(.inline))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
    #endif

    private static let reach: CGFloat = 10
}
