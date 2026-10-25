import CueStore
import SwiftUI

/// 等你卡（`CueWaitDock`）里铺开的那一件，按部分排（卡按地方挑排哪几部分）：
/// - 问句（`question`）：赭黄问号、标题字的问句（`TaskBoard.Wait.asked`）；会话的问题有说明时（选项不写进来）接在下一行。
///   规矩那一类（`CueAsk.rule`）下一行引他自己的原话（`CueAsking.why`："你说过「方案让我挑」。"）：这一问为什么来问他只有这句说得出，问句本身看不出；
///   别的类只写这一类的泛泛依据（"推送代码前先问你"），问句已经说了是什么事，不写。
/// - 点名的图（`shots`，Cue 的提问才有，`CueShots`；"可以"选的是其中一张时那张描靛青圈；点开全屏时底栏就是这几个选项，看完当场定）。
/// - 怎么答（`answer`，`WaitAnswer`）：主动作靠右下角，次要的在同一行左边。
/// 这件事是哪件、在哪个项目、等了多久、第几件在卡顶的眉题行（`CueWaitEyebrow`）；要看细节点眉题进任务或会话。
struct CueWaitItem: View {
    enum Part { case question, shots, answer }

    let wait: TaskBoard.Wait
    let part: Part
    let shots: [UUID: [CueShown]]
    let open: (PreviewOpening) -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        switch part {
        case .question: question
        case .shots:
            if let message = wait.message, let shown = shots[message.id] {
                CueShots(shots: shown, group: "waiting", reply: .answer(message), chosen: CueShots.chosen(for: message.asking, in: shown), open: open)
            }
        case .answer: WaitAnswer(wait: wait.wait)
        }
    }

    private var question: some View {
        let asked = wait.asked
        let below: String? = switch wait.wait {
        case .message(let message, _): message.asking?.rule != nil ? message.asking?.why : nil
        case .session: asked.detail
        }
        return HStack(alignment: .firstTextBaseline, spacing: 9) {
            PiStateGlyph(status: .asking).font(Typography.title)
            VStack(alignment: .leading, spacing: 4) {
                Text(CueQuestionLine<EmptyView>.keepingTail(asked.line)).font(Typography.title).foregroundStyle(palette.ink)
                if let below { Text(below).font(Typography.secondary).foregroundStyle(palette.ink2) }
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 等你卡顶上的眉题行（小号、淡墨，几样靠间距与深浅分开，不用"·"拼）：
/// - 左边：所在项目（项目自己的图标与颜色，`ProjectGlyph`，同看板与侧栏）与项目名，再是这件事的名字（`TaskBoard.Wait.title`：任务名或会话名，深一档）。
///   名字点得到：Cue 的提问打开它落在的任务（`CueTaskButton`，接力也落在这里），会话在问的进会话（谁在问就是这个会话，打开会话的入口也是它）；
///   没落在任务上的提问写 Cue 的名字、不可点。不属于哪个项目的不写项目。地方不够先截名字。
/// - 右边：等了多久（"刚刚""已等 38 分钟"），不止一件时再是"1/3"第几件；Mac 上计数两边各一颗小箭头换一件（`step`），手机上左右滑卡换（`CueWaitDock`）。
struct CueWaitEyebrow: View {
    let wait: TaskBoard.Wait
    let index: Int
    let count: Int
    let step: (Int) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    static let height: CGFloat = 20

    var body: some View {
        HStack(spacing: 0) {
            if let project = workspace.catalog?.project(wait.project ?? wait.message?.asked?.project) {
                HStack(spacing: 2) {
                    ProjectGlyph(project: project, size: 11)
                    Text(project.name).lineLimit(1)
                }
                .fixedSize()
                .padding(.trailing, 10)
            }
            name.layoutPriority(-1)
            Spacer(minLength: 12)
            LiveText(style: PiClock.Waited(since: wait.since)).monospacedDigit().fixedSize()
            if count > 1 { position.padding(.leading, 10) }
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
        .foregroundStyle(palette.ink2)
        // 小字本身矮：点得到的范围往上下扩，不撑高这一行
        .contentShape(.rect.inset(by: -Self.reach))
    }

    @ViewBuilder private var position: some View {
        HStack(spacing: 0) {
            #if os(macOS)
            arrow(.back, by: -1, enabled: index > 0, label: "上一件")
            #endif
            Text("\(index + 1)/\(count)").monospacedDigit()
                .accessibilityLabel("第 \(index + 1) 件，共 \(count) 件")
            #if os(macOS)
            arrow(.forward, by: 1, enabled: index < count - 1, label: "下一件")
            #endif
        }
        .fixedSize()
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
