import CueStore
import SwiftUI

/// 拍板卡：固定在输入框上方的一张纸，Cue 的提问只在这里答（进展页等你列只看，点了来这里；会话在问的也可在会话页答）——与进展页等你列里的拍板同一份（`CueThread.waiting`，出自 `CueStore.cueTally`；待回复不进来，在上方的提示里）：
/// Cue 的提问与会话在问的同排，一次铺开一件，默认露等得最久的那件（从任务看板点进来的那条先露，`CueThread.leading`）。
/// 不止一件时像叠在一起的通知：卡后面露出一两层叠边（`deck`），眉题行写第几件（`CueWaitEyebrow`）；手机上左右滑卡换一件（跟手，甩过或拖过一段就换，
/// 到头了让给切页），Mac 上点眉题行的小箭头。答完一件，下一件从叠边里顶上来。
/// 铺开的那件：眉题（`CueWaitEyebrow`）、问句（`CueWaitQuestion`）、点名的图、怎么答（`WaitAnswer`，与会话页问题卡同一个；主动作在右下角）。问句是代码按 Cue 写的动作短语写出的
/// （`CueAsking.question`），不靠 Cue 的措辞；要看细节（Cue 的原话、会话里的来龙去脉）点眉题进任务或会话。对话里不另挂还在等你的提问：同一问同屏只一处。
/// 圆角、与输入框和待回复提示之间的空同一套（`ComposerMetrics.radius`、`stackGap`）。
/// 卡上只能答：别的话在 Cue 页底下的输入框说，一开口 Cue 的提问就收起（Cue 判断不是在答它会放回，见 `CueQuestionEnd`）。没有关掉。
/// Cue 停用着时卡照样露、Cue 的选项停用并写"启用后再答"（`CueChoices`）。答了等库里那件结束才换下一件。
struct CueWaitDock: View {
    let waiting: [TaskBoard.Wait]
    /// 提问点名的图（`CueThread.shots`）
    let shots: [UUID: [CueShown]]
    let open: (PreviewOpening) -> Void
    /// 卡正在升起或淡入：这期间对话不另外往上滑（`ChatColumn` 的 `holding`），只跟着它让出的高挪，停了再滑一次。离开时不压（`follow`）。
    @Binding var moving: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chatHeight) private var chatHeight
    /// 换到了哪件（滑卡、小箭头）；不在等了就回到第一件。
    @State private var picked: String?
    /// 手机上滑卡：卡跟着手指横移多少。
    @State private var drag: CGFloat = 0
    /// 滑走的那张往哪边飞出去（换一件时旧卡的去向）；不是滑走的（答完、点箭头）原地淡掉，为 0。
    @State private var exit: CGFloat = 0
    /// 露出的那件：选中的那件；答完淡掉的这一段里还是它（那时它已不在 `waiting` 里）。
    @State private var shown: TaskBoard.Wait?
    /// 露出了多少，0…1：升起的比例（`RiseBehind`，0 是全藏在输入框后面）；减弱动态效果时与离开时是不透明度。
    @State private var level: CGFloat
    /// 都答完（或撤回）正在离开：让出的高一下到位，卡浮在原处淡掉（同减弱动态效果）。
    @State private var leaving = false

    /// 页打开时已经在等的那张随页一起排出来、不升起（同 `follow` 的头一次）：等 `onChange` 再放的话卡晚一次更新才排，
    /// 对话按它让出的高又要重排一遍。
    init(waiting: [TaskBoard.Wait], shots: [UUID: [CueShown]], open: @escaping (PreviewOpening) -> Void, moving: Binding<Bool>) {
        self.waiting = waiting
        self.shots = shots
        self.open = open
        _moving = moving
        _shown = State(initialValue: waiting.first)
        _level = State(initialValue: waiting.isEmpty ? 0 : 1)
    }

    /// 选中的那件：点过的还在等就是它，不然是第一件。
    private var current: TaskBoard.Wait? { waiting.first { $0.id == picked } ?? waiting.first }

    /// 来了从输入框后面升起（`RiseBehind`）；都答完让出的高一下到位、卡浮在原处淡掉：对话里接着长出这一问与你的回答，对话一次滑到终位。
    /// 换一件时新的从叠边里微微放大淡入，旧的滑走的往那边飞出、其余原地淡掉（底边对齐叠放）。减弱动态效果时来也只淡入。卡与下面输入框的间距在卡里（`below`）。
    var body: some View {
        ZStack(alignment: .bottom) {
            if let item = shown {
                card(waiting.first { $0.id == item.id } ?? item)
                    .offset(x: drag)
                    .id(item.id)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.96, anchor: .bottom).combined(with: .opacity),
                        removal: .offset(x: exit).combined(with: .opacity)))
            }
        }
        // 叠边按卡的整高垫在后面：滑卡时露出的是后一件的纸，不跟着卡动、不随换卡进出
        .background { if shown != nil { deck } }
        .opacity(floats ? level : 1)
        .modifier(RiseBehind(shown: floats ? (waiting.isEmpty ? 0 : 1) : level, floats: floats, limit: chatHeight / 2))
        .onChange(of: current?.id, initial: true) { old, new in follow(animated: old != new) }
        // 从任务看板点进来换了要露的那条：回到第一件（它已排到最前）
        .onChange(of: workspace.cueAsking) { picked = nil }
        .debugSettling(moving || leaving)
    }

    static let side: CGFloat = 16
    private static let below = ComposerMetrics.stackGap
    /// 卡里上下的边与几部分之间：眉题离卡顶、怎么答离卡底、各部分之间。
    private static let edge: CGFloat = 12
    private static let gap: CGFloat = 12
    /// 叠边：每层比上一层往下多露这么多、两边各收这么多，至多两层；露得够一眼数出后面还有几件。
    private static let peek: CGFloat = 9
    private static let tuck: CGFloat = 12
    private static let layers = 2

    /// 卡后面露出几层叠边：还有几件在等，至多 `layers`。
    private var behind: Int { min(max(waiting.count - 1, 0), Self.layers) }

    #if os(macOS)
    /// 卡至少多高（Cue 页打开时数要排几格，`CuePage.covered`）：眉题、问句（至少一行标题字）、带图时一排图（`CueShots.floor`）、
    /// 怎么答（至少一颗按钮）与上下的边；叠边不算。只能数少。
    static func floor(_ wait: TaskBoard.Wait, shots: [UUID: [CueShown]], width: CGFloat) -> CGFloat {
        let pictures = wait.message.flatMap { shots[$0.id] }.map { gap + CueShots.floor(count: $0.count, width: width - 2 * side) } ?? 0
        return edge + CueWaitEyebrow.height + 6 + Typography.titleSize + pictures + gap + ControlMetrics.compactHeight + edge + below
    }
    #endif

    /// 卡后面的叠边：与卡一样高，一层比一层窄、往下多露 `peek`，平时只露出卡下沿那一截。跟着在等的件数增减，不随滑卡挪。
    private var deck: some View {
        ZStack {
            ForEach((1...Self.layers).reversed(), id: \.self) { layer in
                Color.clear
                    .paper(radius: ComposerMetrics.radius, lifted: true)
                    .opacity(layer > behind ? 0 : layer == 1 ? 0.85 : 0.6)
                    .padding(.horizontal, Self.tuck * CGFloat(layer))
                    .padding(.top, Self.peek * CGFloat(layer))
                    .padding(.bottom, Self.below + Self.peek * CGFloat(max(behind - layer, 0)))
            }
        }
        .animation(HandOff.quick, value: behind)
        .accessibilityHidden(true)
    }

    /// 第几件、换到哪件（眉题行的小箭头、滑卡）。
    private func index(of wait: TaskBoard.Wait) -> Int { waiting.firstIndex { $0.id == wait.id } ?? 0 }

    private func neighbor(of wait: TaskBoard.Wait, by offset: Int) -> TaskBoard.Wait? {
        let next = index(of: wait) + offset
        return waiting.indices.contains(next) ? waiting[next] : nil
    }

    private func step(from wait: TaskBoard.Wait, by offset: Int) {
        guard let next = neighbor(of: wait, by: offset) else { return }
        withAnimation(HandOff.quick) { picked = next.id }
    }

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

    /// Cue 点名的图（`CueShots`）："可以"选的是其中一张时那张描靛青圈；点开全屏时底栏就是这几个选项，看完当场定。
    @ViewBuilder private func pictures(_ wait: TaskBoard.Wait) -> some View {
        if let message = wait.message, let shown = shots[message.id] {
            CueShots(shots: shown, group: "waiting", reply: .answer(message), chosen: CueShots.chosen(for: message.asking, in: shown), open: open)
        }
    }

    private func eyebrow(_ wait: TaskBoard.Wait) -> some View {
        CueWaitEyebrow(wait: wait, index: index(of: wait), count: max(waiting.count, 1)) { step(from: wait, by: $0) }
            .padding(.top, Self.edge)
    }

    /// 从上到下：眉题、问句与点名的图、怎么答。卡至多占对话区可见高的一半，地方不够时只用剩下的（`RiseLayout`）。
    /// Mac 上放不下时问句与图在卡里滚、怎么答钉在卡底。
    /// 手机上按能放下的挑（`ViewThatFits`）：整张 → 紧凑（去掉图）→ 只剩问句一行（`folded`）。放得下时不进滚动区：滚动区里的按钮按下要晚一下才有反馈。
    private func card(_ wait: TaskBoard.Wait) -> some View {
        #if os(macOS)
        let body = VStack(alignment: .leading, spacing: 0) {
            eyebrow(wait)
            Yielding {
                ScrollView {
                    VStack(alignment: .leading, spacing: Self.gap) {
                        CueWaitQuestion(wait: wait)
                        pictures(wait)
                    }
                    .padding(.top, 6)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            WaitAnswer(wait: wait.wait).padding(.top, Self.gap).layoutPriority(1)
        }
        .padding(.horizontal, Self.side).padding(.bottom, Self.edge)
        #else
        let body = ViewThatFits(in: .vertical) {
            sheet(wait, shots: true)
            sheet(wait, shots: false)
            folded(wait)
        }
        .gesture(HorizontalPan(allows: { swipes(wait, toward: $0) }, changed: { track($0, on: wait) }, ended: { release(wait, commits: $0, velocity: $1) }))
        .accessibilityAction(named: "上一件") { step(from: wait, by: -1) }
        .accessibilityAction(named: "下一件") { step(from: wait, by: 1) }
        #endif
        return body
            .frame(maxWidth: .infinity, alignment: .leading)
            .paper(radius: ComposerMetrics.radius, lifted: true)
            .padding(.bottom, Self.below + Self.peek * CGFloat(behind))
    }

    #if os(iOS)
    /// 一件铺开：眉题、问句、（点名的图、）怎么答。
    private func sheet(_ wait: TaskBoard.Wait, shots: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow(wait)
            VStack(alignment: .leading, spacing: Self.gap) {
                CueWaitQuestion(wait: wait)
                if shots { pictures(wait) }
                WaitAnswer(wait: wait.wait)
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, Self.side).padding(.bottom, Self.edge)
    }

    /// 这一拖归不归卡：那个方向还有一件（往左拖是下一件）；到头了让给页上的横拖（切页）。
    private func swipes(_ wait: TaskBoard.Wait, toward velocity: CGFloat) -> Bool {
        neighbor(of: wait, by: velocity < 0 ? 1 : -1) != nil
    }

    /// 跟手；拖过头（那边没有下一件）越拖越沉。
    private func track(_ translation: CGFloat, on wait: TaskBoard.Wait) {
        let open = neighbor(of: wait, by: translation < 0 ? 1 : -1) != nil
        drag = open ? translation : translation * 0.2
        if !reduceMotion { exit = translation < 0 ? -Self.flyOut : Self.flyOut }
    }

    /// 松手：甩过或拖过 `commit` 且那边有下一件就换（旧卡顺着飞出、新卡从叠边里上来），否则弹回。
    private func release(_ wait: TaskBoard.Wait, commits: Bool, velocity: CGFloat) {
        let projected = drag + velocity * 0.12
        let next = commits && abs(projected) > Self.commit ? neighbor(of: wait, by: projected < 0 ? 1 : -1) : nil
        guard let next else {
            exit = 0
            withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { drag = 0 }
            return
        }
        withAnimation(reduceMotion ? HandOff.quick : Motion.snappy, completionCriteria: .removed) {
            drag = 0
            picked = next.id
            shown = next
        } completion: { exit = 0 }
    }

    /// 拖过这么远（连同甩的势头）就换一件；滑走的卡飞出这么远。
    private static let commit: CGFloat = 80
    private static let flyOut: CGFloat = 480

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
            .frame(minHeight: ControlMetrics.height)
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle())
        .accessibilityHint("收起键盘，展开这张卡")
    }
    #endif
}
