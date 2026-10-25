import CueStore
import SwiftUI

/// 拍板卡（Cue 页的 `CueWaitDock`）里铺开的那一件，按部分排（卡按地方挑排哪几部分）：问句（`CueWaitQuestion`）、点名的图（`shots`，Cue 的提问才有，`CueShots`；
/// "可以"选的是其中一张时那张描靛青圈；点开全屏时底栏就是这几个选项，看完当场定）、怎么答（`WaitAnswer`：主动作靠右下角，次要的在同一行左边）。
/// 这件事是哪件、在哪个项目、等了多久、第几件在卡顶的眉题行（`CueWaitEyebrow`）；要看细节点眉题进任务或会话。
/// 进展页等你列的拍板卡（`BoardWaitCard`）用同样的眉题、问句与答法，不带图。
struct CueWaitItem: View {
    enum Part { case question, shots, answer }

    let wait: TaskBoard.Wait
    let part: Part
    let shots: [UUID: [CueShown]]
    let open: (PreviewOpening) -> Void

    var body: some View {
        switch part {
        case .question: CueWaitQuestion(wait: wait)
        case .shots:
            if let message = wait.message, let shown = shots[message.id] {
                CueShots(shots: shown, group: "waiting", reply: .answer(message), chosen: CueShots.chosen(for: message.asking, in: shown), open: open)
            }
        case .answer: WaitAnswer(wait: wait.wait)
        }
    }
}

/// 一件拍板要你定什么：赭黄问号、问句（`TaskBoard.Wait.asked`）；会话的问题有说明时（选项不写进来）接在下一行。
/// 规矩那一类（`CueAsk.rule`）下一行引他自己的原话（`CueAsking.why`："你说过「方案让我挑」。"）：这一问为什么来问他只有这句说得出，问句本身看不出；
/// 别的类不写依据（"推送代码前先问你"）：问句已经说了是什么事。`dense`：进展页等你列，问句是正文字号（列窄，问句是卡上最大的字但不是页上的标题）。
struct CueWaitQuestion: View {
    let wait: TaskBoard.Wait
    var dense = false
    @Environment(\.palette) private var palette

    var body: some View {
        let asked = wait.asked
        let below: String? = switch wait.wait {
        case .message(let message, _): message.asking?.rule != nil ? message.asking?.why : nil
        case .session: asked.detail
        }
        let font = dense ? Self.denseFont : Typography.title
        return HStack(alignment: .firstTextBaseline, spacing: dense ? 6 : 9) {
            PiStateGlyph(status: .asking).font(font)
            VStack(alignment: .leading, spacing: dense ? 2 : 4) {
                Text(CueQuestionLine<EmptyView>.keepingTail(asked.line)).font(font).foregroundStyle(palette.ink)
                if let below { Text(below).font(dense ? TaskMetrics.caption : Typography.secondary).foregroundStyle(palette.ink2) }
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    #if os(macOS)
    private static let denseFont = Typography.body.weight(.semibold)
    #else
    private static let denseFont = Font.body.weight(.semibold)
    #endif
}

/// 拍板卡顶上的眉题行（小号、淡墨，几样靠间距与深浅分开，不用"·"拼），Cue 页的拍板卡与进展页等你列（`place`）共用：
/// - 左边：所在项目（项目自己的图标与颜色，`ProjectGlyph`，同看板与侧栏）与项目名，再是这件事的名字（`TaskBoard.Wait.title`：任务名或会话名，深一档）。
///   名字点得到：Cue 的提问打开它落在的任务（`CueTaskButton`，接力也落在这里），会话在问的进会话（谁在问就是这个会话，打开会话的入口也是它）；
///   没落在任务上的提问写 Cue 的名字，Cue 页上不可点，看板上点了去 Cue 页那一问（`Workspace.cueAsking`）。不属于哪个项目的不写项目。地方不够先截名字。
/// - 右边：等了多久（"刚刚""已等 38 分钟"）；Cue 页上不止一件时再是"1/3"第几件，Mac 上计数两边各一颗小箭头换一件（`step`），手机上左右滑卡换（`CueWaitDock`）。
/// - 看板上照看板卡的语法：只看一个项目时不写项目；Mac 上列窄，项目只留小图形（悬停联动，`BoardProjectGlyph`），项目名与等了多久收进卡的悬停提示（`BoardWaitCard`）。
struct CueWaitEyebrow: View {
    enum Place {
        /// Cue 页拍板卡：第几件、共几件、换一件
        case dock(index: Int, count: Int, step: (Int) -> Void)
        case board
    }

    let wait: TaskBoard.Wait
    let place: Place
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    static let height: CGFloat = 20

    var body: some View {
        HStack(spacing: 0) {
            project
            name.layoutPriority(-1)
            Spacer(minLength: 12)
            if !Self.tipped(place) { LiveText(style: PiClock.Waited(since: wait.since)).monospacedDigit().fixedSize() }
            if case .dock(let index, let count, let step) = place, count > 1 { position(index, count, step).padding(.leading, 10) }
        }
        .font(Typography.caption)
        .foregroundStyle(palette.ink3)
        .frame(height: Self.height)
    }

    /// 项目名与等了多久收进悬停提示（Mac 看板）。
    static func tipped(_ place: Place) -> Bool {
        #if os(macOS)
        if case .board = place { return true }
        #endif
        return false
    }

    @ViewBuilder private var project: some View {
        let board = if case .board = place { true } else { false }
        if !(board && workspace.scopedProject != nil), let project = workspace.catalog?.project(wait.shownProject) {
            if board && Self.tipped(place) {
                BoardProjectGlyph(project: project).padding(.trailing, 6)
            } else {
                HStack(spacing: 2) {
                    ProjectGlyph(project: project, size: 11)
                    Text(project.name).lineLimit(1)
                }
                .fixedSize()
                .padding(.trailing, 10)
            }
        }
    }

    @ViewBuilder private var name: some View {
        let title = wait.title(cue: workspace.cue.name)
        switch wait.wait {
        case .message(let message, _):
            if let task = wait.item?.task.id ?? message.taskID {
                CueTaskButton(task: task) { label(title, linked: true).relaySpot(task: task) }
                    .accessibilityHint("打开任务")
            } else if case .board = place {
                Button { workspace.askOnCuePage(message.id) } label: { label(title, linked: true) }
                    .buttonStyle(PressStyle())
                    .accessibilityHint("去 Cue 页回答")
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

    private func position(_ index: Int, _ count: Int, _ step: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 0) {
            #if os(macOS)
            arrow(.back, enabled: index > 0, label: "上一件") { step(-1) }
            #endif
            Text("\(index + 1)/\(count)").monospacedDigit()
                .accessibilityLabel("第 \(index + 1) 件，共 \(count) 件")
            #if os(macOS)
            arrow(.forward, enabled: index < count - 1, label: "下一件") { step(1) }
            #endif
        }
        .fixedSize()
    }

    #if os(macOS)
    private func arrow(_ icon: Icon, enabled: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(icon).font(.system(size: 9, weight: .bold)).frame(width: Self.height, height: Self.height).contentShape(.rect)
        }
        .buttonStyle(PressStyle(.inline))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
    #endif

    private static let reach: CGFloat = 10
}
