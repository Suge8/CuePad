import CueStore
import SwiftUI

/// "等你"：固定在输入框上方的一张纸，要你拍板的事只在这里——来源与进展页等你列、Cue 那一行的"等你 M"同一份（`CueThread.waiting`，出自 `CueStore.cueTally`）：
/// Cue 的提问与会话在问的同排。顶上一排是在等的每一件（`CueWaitStrip`），点哪件铺开哪件；默认露最早的那件（从任务看板点进来的那条先露，`CueThread.leading`）。
/// 铺开的那件（`CueWaitItem`）：问句、点名的图、怎么答（`WaitAnswer`，与进展页等你列、会话页问题卡同一个）与末行。问句是代码按 Cue 写的动作短语写出的
/// （`CueAsking.question`），不靠 Cue 的措辞；Cue 的原话默认收起，点"原话"再看。对话里不另挂还在等你的提问：同一问同屏只一处。
/// 卡上只能答：别的话在 Cue 页底下的输入框说，一开口 Cue 的提问就收起（Cue 判断不是在答它会放回，见 `CueQuestionEnd`）。没有关掉。
/// Cue 停用着时卡照样露、Cue 的选项停用并写"启用后再答"（`CueChoices`）。答了等库里那件结束才换下一件。
struct CueWaitDock: View {
    let waiting: [TaskBoard.Wait]
    let tasks: [UUID: CueTaskRef]
    /// 提问点名的图（`CueThread.shots`）
    let shots: [UUID: [CueShown]]
    let open: (PreviewOpening) -> Void
    /// 卡正在升起或淡入：这期间对话不另外往上滑（`ChatColumn` 的 `holding`），只跟着它让出的高挪，停了再滑一次。离开时不压（`follow`）。
    @Binding var moving: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chatHeight) private var chatHeight
    /// 点了顶上那一排的哪件；不在等了就回到第一件。
    @State private var picked: String?
    /// 展开了原话的那件：换一件时收起。
    @State private var reading: String?
    /// 露出的那件：选中的那件；答完淡掉的这一段里还是它（那时它已不在 `waiting` 里）。
    @State private var shown: TaskBoard.Wait?
    /// 露出了多少，0…1：升起的比例（`RiseBehind`，0 是全藏在输入框后面）；减弱动态效果时与离开时是不透明度。
    @State private var level: CGFloat
    /// 都答完（或撤回）正在离开：让出的高一下到位，卡浮在原处淡掉（同减弱动态效果）。
    @State private var leaving = false

    /// 页打开时已经在等的那张随页一起排出来、不升起（同 `follow` 的头一次）：等 `onChange` 再放的话卡晚一次更新才排，
    /// 对话按它让出的高又要重排一遍。
    init(waiting: [TaskBoard.Wait], tasks: [UUID: CueTaskRef], shots: [UUID: [CueShown]], open: @escaping (PreviewOpening) -> Void, moving: Binding<Bool>) {
        self.waiting = waiting
        self.tasks = tasks
        self.shots = shots
        self.open = open
        _moving = moving
        _shown = State(initialValue: waiting.first)
        _level = State(initialValue: waiting.isEmpty ? 0 : 1)
    }

    /// 选中的那件：点过的还在等就是它，不然是第一件。
    private var current: TaskBoard.Wait? { waiting.first { $0.id == picked } ?? waiting.first }

    /// 来了从输入框后面升起（`RiseBehind`）；都答完让出的高一下到位、卡浮在原处淡掉：对话里接着长出这一问与你的回答，对话一次滑到终位。
    /// 换一件时新的在原地与旧的交叉淡（底边对齐叠放）。减弱动态效果时来也只淡入。卡与下面输入框的间距在卡里（`below`）。
    var body: some View {
        ZStack(alignment: .bottom) {
            if let item = shown {
                card(waiting.first { $0.id == item.id } ?? item)
                    .id(item.id)
                    .transition(.opacity)
            }
        }
        .opacity(floats ? level : 1)
        .modifier(RiseBehind(shown: floats ? (waiting.isEmpty ? 0 : 1) : level, floats: floats, limit: chatHeight / 2))
        .onChange(of: current?.id, initial: true) { old, new in follow(animated: old != new) }
        // 从任务看板点进来换了要露的那条：回到第一件（它已排到最前）
        .onChange(of: workspace.cueAsking) { picked = nil }
        .debugSettling(moving || leaving)
    }

    static let side: CGFloat = 16
    private static let below: CGFloat = 8
    private static let top: CGFloat = 8
    private static let bottom: CGFloat = 6

    #if os(macOS)
    /// 卡至少多高（Cue 页打开时数要排几格，`CuePage.covered`）：顶上那一排、问句（至少一行标题字）、带图时一排图（`CueShots.floor`）、
    /// 末行与卡底的间距；原话收着。只能数少。
    static func floor(_ wait: TaskBoard.Wait, shots: [UUID: [CueShown]], width: CGFloat) -> CGFloat {
        let pictures = wait.message.flatMap { shots[$0.id] }.map { 16 + CueShots.floor(count: $0.count, width: width - 2 * side) } ?? 0
        return top + CueWaitStrip.height + 12 + Typography.titleSize + pictures + footerGap + CueWaitItem.footerHeight + bottom + below
    }

    private static let footerGap: CGFloat = 12
    #endif

    /// 卡浮着、露出的比例当不透明度用：减弱动态效果时与离开时。
    private var floats: Bool { reduceMotion || leaving }

    /// 跟上选中的那件：来了升起，都没了淡掉、淡完再拿掉，换了一件原地交替；减弱动态效果时来也只淡。
    /// 升起用无回弹弹簧、从卡排进去的下一帧起播：卡插进来那一帧排版重，从这一帧起算的话前几十毫秒被吃掉。
    /// 淡入稍慢、淡出要快：淡出时对话正滑向终位，卡叠在字上的那几帧越短越好。离开时不压住对话（`moving`）。
    private func follow(animated: Bool) {
        guard let next = current else {
            guard shown != nil else { return }
            guard animated else { return leave() }
            leaving = true
            // 收尾看此刻的状态（`leaving`）：淡的这 80ms 里又来了一件时不把它拿掉
            move(to: 0, .easeOut(duration: HandOff.gap), holds: false) { if leaving { leave() } }
            return
        }
        let swapping = shown != nil
        leaving = false
        if reading != next.id { reading = nil }
        withAnimation(swapping && animated ? HandOff.quick : nil) { shown = next }
        guard animated, level < 1 else { return level = 1 }
        moving = true
        Task {
            await NextFrame.wait()
            guard shown?.id == next.id else { return moving = false }
            move(to: 1, reduceMotion ? HandOff.quick : Motion.snappy)
        }
    }

    /// 播一段卡的来去，`holds` 时播着的时候 `moving`；动画走完再收尾。淡到一半又来了一件时前一段被接走，它的收尾不算数。
    private func move(to target: CGFloat, _ animation: Animation, holds: Bool = true, then done: @escaping () -> Void = {}) {
        moving = holds
        withAnimation(animation, completionCriteria: .removed) { level = target } completion: {
            guard level == target else { return }
            moving = false
            done()
        }
    }

    private func leave() {
        shown = nil
        level = 0
        leaving = false
    }

    private func part(_ wait: TaskBoard.Wait, _ part: CueWaitItem.Part) -> CueWaitItem {
        CueWaitItem(
            wait: wait, part: part, tasks: tasks, shots: shots, open: open,
            reading: Binding { reading == wait.id } set: { reading = $0 ? wait.id : nil })
    }

    private func strip(_ wait: TaskBoard.Wait) -> some View {
        CueWaitStrip(waiting: waiting.isEmpty ? [wait] : waiting, current: wait) { id in withAnimation(HandOff.quick) { picked = id } }
            .padding(.top, Self.top)
    }

    /// 从上到下：顶上那一排、问句与点名的图、怎么答与末行。卡至多占对话区可见高的一半，地方不够时只用剩下的（`RiseLayout`）。
    /// Mac 上放不下时问句与图在卡里滚、怎么答钉在卡底，末行与怎么答合成一行（任务、原话在左，选项在右）。
    /// 手机上按能放下的挑（`ViewThatFits`）：整张 → 紧凑（去掉图与末行）→ 只剩问句一行（`folded`）。放得下时不进滚动区：滚动区里的按钮按下要晚一下才有反馈。
    private func card(_ wait: TaskBoard.Wait) -> some View {
        #if os(macOS)
        let body = VStack(spacing: 0) {
            strip(wait)
            Yielding {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        part(wait, .question)
                        part(wait, .shots)
                    }
                    .padding(.top, 12).padding(.horizontal, Self.side)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            macFooter(wait).padding(.top, Self.footerGap).padding(.horizontal, Self.side).padding(.bottom, Self.bottom).layoutPriority(1)
        }
        #else
        let body = ViewThatFits(in: .vertical) {
            VStack(alignment: .leading, spacing: 0) {
                strip(wait)
                VStack(alignment: .leading, spacing: 16) {
                    part(wait, .question)
                    part(wait, .shots)
                    part(wait, .answer)
                }
                .padding(.top, 12).padding(.horizontal, Self.side)
                part(wait, .footer).padding(.top, 4).padding(.horizontal, Self.side)
            }
            .padding(.bottom, wait.message == nil ? 14 : Self.bottom)
            VStack(alignment: .leading, spacing: 16) {
                strip(wait)
                part(wait, .question).padding(.horizontal, Self.side)
                part(wait, .answer).padding(.horizontal, Self.side)
            }
            .padding(.bottom, 14)
            folded(wait)
        }
        #endif
        return body
            .frame(maxWidth: .infinity, alignment: .leading)
            .paper(radius: ComposerMetrics.radius, lifted: true)
            .animation(HandOff.quick, value: reading)
            .padding(.bottom, Self.below)
    }

    #if os(macOS)
    /// Mac 的末行：Cue 的提问是任务与原话在左、选项在右；会话在问的只有怎么答（回答框铺满一行）。
    @ViewBuilder private func macFooter(_ wait: TaskBoard.Wait) -> some View {
        if wait.message != nil {
            HStack(spacing: 0) {
                part(wait, .footer)
                Spacer(minLength: 16)
                part(wait, .answer).fixedSize(horizontal: true, vertical: false)
            }
        } else {
            part(wait, .answer).padding(.bottom, 8)
        }
    }
    #else
    /// 连紧凑的样子都放不下（横屏弹着键盘）：整张卡收成问句一行。点它收起键盘，地方够了卡就按上面的挑法展开。
    private func folded(_ wait: TaskBoard.Wait) -> some View {
        Button {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        } label: {
            HStack(spacing: 9) {
                PiStateGlyph(status: .asking).font(Typography.title)
                Text(wait.asked.line).font(Typography.title).foregroundStyle(palette.ink).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Self.side)
            .frame(minHeight: CueWaitItem.footerHeight)
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle())
        .accessibilityHint("收起键盘，展开这张卡")
    }
    #endif
}
