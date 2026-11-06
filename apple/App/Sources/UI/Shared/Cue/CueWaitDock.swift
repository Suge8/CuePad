import CueStore
import SwiftUI

/// 拍板卡：固定在输入框上方的一张纸，Cue 的提问只在这里答（进展页等你列只看，点了来这里；会话在问的也可在会话页答）——与进展页等你列里的拍板同一份（`CueThread.waiting`，出自 `CueStore.cueTally`；待回复不进来，在上方的提示里）：
/// Cue 的提问与会话在问的同排（等得最久的在前），一次铺开一件：露哪件只记在 `Workspace.cueAsking`（滑卡与小箭头换的写它），不在等了露第一件。
/// 不止一件时像叠在一起的通知：卡后面露出一层叠边（`deck`），眉题行写第几件（`CueWaitEyebrow`）；手机上左右滑卡换一件（跟手，甩过或拖过一段就换，
/// 到头了不接），Mac 上点眉题行的小箭头。答完一件，下一件从叠边里顶上来。
/// 铺开的那件：眉题（`CueWaitEyebrow`）、问句（`CueQuestionLine`）、点名的图、怎么答（`WaitAnswer`，与会话页问题卡同一个；主动作在右下角）。问句是代码按 Cue 写的动作短语写出的
/// （`CueAsking.question`），不靠 Cue 的措辞；要看细节（Cue 的原话、会话里的来龙去脉）点眉题进任务或会话。对话里不另挂还在等你的提问：同一问同屏只一处。
/// 与输入框同宽、同圆角（`Radius.field`）；卡下沿离输入框 `below`，再加叠边那一截。
/// 卡上只能答：别的话在 Cue 页底下的输入框说，一开口 Cue 的提问就收起（Cue 判断不是在答它会放回）；在挂着它的会话里说也当场收起（见 `CueQuestionEnd`）。没有关掉。
/// Cue 停用着时卡照样露、Cue 的选项停用并写"启用后再答"（`CueChoices`）。答了等库里那件结束才换下一件。
struct CueWaitDock: View {
    let waiting: [CueWait]
    /// 要露的那件（`Workspace.cueAsking`）；换一件写回那里。
    let asking: String?
    /// 提问点名的图（`CueThread.shots`）
    let shots: [UUID: [CueShown]]
    let open: (PreviewOpening) -> Void
    /// 卡正在升起、沉回或淡入淡出：这期间对话不另外往上滑（`ChatColumn` 的 `holding`），只跟着它让出的高挪，停了再滑一次。
    @Binding var moving: Bool
    #if os(iOS)
    @Environment(Workspace.self) private var workspace
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pageActive) private var active
    /// 读屏停在哪件的"第几件"上（`CueWaitEyebrow`）：换一件时卡按件换身份（叠边里上浮、旧卡飞出的转场靠它），读屏的焦点随旧卡一起没了，
    /// 换完由卡把焦点放到新那件的这一格（`CueWaitCard.step`）。记在这里不记在卡里：旧卡走了它还在。
    @AccessibilityFocusState private var counter: String?
    /// 手机上滑卡：卡跟着手指横移多少。
    @State private var drag: CGFloat = 0
    /// 滑走的那张往哪边飞出去（换一件时旧卡的去向）；不是滑走的（答完、点箭头）原地淡掉，为 0。
    @State private var exit: CGFloat = 0
    /// 露出的那件：选中的那件；答完沉回去的这一段里还是它（那时它已不在 `waiting` 里）。
    @State private var shown: CueWaitPick?
    /// 露出了多少，0…1：升起的比例（`RiseBehind`，0 是全藏在输入框后面）；减弱动态效果时是不透明度。
    @State private var level: CGFloat
    /// 这一页从什么时候起在前台：在这之前就在等的不算"来了"，不升起。Mac 上挂着不看的页不跟着库变（`pageActive`），
    /// 回到前台时才读到的那几件当场就在、不再从输入框后面升起（升起的这一段对话跟着每帧重排）。
    @State private var watching = Date.now

    /// 页打开时已经在等的那张随页一起排出来、不升起（同 `follow` 的头一次）：等 `onChange` 再放的话卡晚一次更新才排，
    /// 对话按它让出的高又要重排一遍。
    init(waiting: [CueWait], asking: String?, shots: [UUID: [CueShown]], open: @escaping (PreviewOpening) -> Void, moving: Binding<Bool>) {
        self.waiting = waiting
        self.asking = asking
        self.shots = shots
        self.open = open
        _moving = moving
        _shown = State(initialValue: Self.pick(in: waiting, asking: asking))
        _level = State(initialValue: waiting.isEmpty ? 0 : 1)
    }

    /// 选中的那件：还在等就是它，不然是第一件。
    static func current(in waiting: [CueWait], asking: String?) -> CueWait? {
        pick(in: waiting, asking: asking)?.wait
    }

    private static func pick(in waiting: [CueWait], asking: String?) -> CueWaitPick? {
        guard !waiting.isEmpty else { return nil }
        return CueWaitPick(waits: waiting, index: waiting.firstIndex { $0.id == asking } ?? 0)
    }

    private var current: CueWaitPick? { Self.pick(in: waiting, asking: asking) }

    /// 露出的那件此刻的样子：还在等就取库里最新的那份（连同第几件），已经不在了（答完沉回去时）是它最后的样子、只此一件。
    private func live(_ pick: CueWaitPick) -> CueWaitPick {
        waiting.firstIndex { $0.id == pick.id }.map { CueWaitPick(waits: waiting, index: $0) } ?? CueWaitPick(waits: [pick.wait], index: 0)
    }

    /// 来了从输入框后面升起、都答完沉回去（`RiseBehind`，同会话页的整卡）：对话跟着让出的高每帧挪。答完时同一次更新里对话长出这一问与回答，
    /// 那一下先不跟（`ChatScroll.dockLeft`），沉的这一段压着（`moving`），沉完再一次滑上去；卡比长出的那段高时，对话随让出的高连续落下。
    /// 否决过浮在原处淡掉、让出的高一下收掉：长出的与让出的不一样高时对话当帧挪那一截差（卡上带图时上百点）。
    /// 换一件时新的从叠边里上浮一截淡入，旧的滑走的往那边飞出、其余原地淡掉（底边对齐叠放）。减弱动态效果时来也只淡入。卡与下面输入框的间距在卡里（`below`）。
    /// 卡上有字、有回答框，进场不缩放（理由同 `BubblePlacement.transition`；Mac 上缩放还让回答框的 AppKit 文本框每帧按缩放重报尺寸，SwiftUI 报 min <= max 不成立）。
    var body: some View {
        ZStack(alignment: .bottom) {
            if let shown {
                card(live(shown))
                    .offset(x: drag)
                    .id(shown.id)
                    .transition(.asymmetric(
                        insertion: .offset(y: Self.peek).combined(with: .opacity),
                        removal: .offset(x: exit).combined(with: .opacity)))
            }
        }
        // 叠边按卡的整高垫在后面：滑卡时露出的是后一件的纸，不跟着卡动、不随换卡进出
        .background { if shown != nil { deck } }
        .opacity(floats ? level : 1)
        .modifier(RiseBehind(shown: floats ? (waiting.isEmpty ? 0 : 1) : level, floats: floats))
        .onChange(of: current?.id, initial: true) { old, new in follow(animated: old != new) }
        .onChange(of: active) { if active { watching = .now } }
        .debugSettling(moving)
    }

    static let below = Spacing.item
    /// 叠边比卡往下多露这么多、两边各收这么多。只露一层：第几件已写在眉题行，叠边只说后面还有。
    /// 否决两层：卡下沿要按最多层数一直让着，只有一件时卡离输入框也空出一大截。
    private static let peek: CGFloat = 8
    private static let tuck: CGFloat = 12

    /// 卡后面的叠边：与卡一样高、两边各收 `tuck`、往下多露 `peek`，平时只露出卡下沿那一截；后面还有件才露，不随滑卡挪。
    /// 卡下沿让出的那一截一直留着（`card`，没有时留白）：按件数让的话，来一件、答掉一件拍板卡就变高变矮，浮在上面的对话当帧跳一下。
    private var deck: some View {
        let behind = waiting.count > 1
        return Color.clear
            .dockedPaper()
            // 不透明：对话滚到卡后面（`FloatingReply` 不铺底），半透的叠边会透出后面的字
            .opacity(behind ? 1 : 0)
            .padding(.horizontal, Self.tuck)
            .padding(.top, Self.peek)
            .padding(.bottom, Self.below)
            .animation(Motion.fade, value: behind)
            .readerHidden(true)
    }

    /// 铺开的那件（`CueWaitCard`）垫上纸；手机上左右滑换一件。
    /// 整张卡接这一拖（`contentShape`）：只挂在内容上的话卡里的空白处接不住。卡里的按钮照样先接自己的点按。
    private func card(_ pick: CueWaitPick) -> some View {
        let card = CueWaitCard(pick: pick, shots: pick.wait.message.flatMap { shots[$0.id] }, counter: $counter, open: open)
            .frame(maxWidth: .infinity, alignment: .leading)
        #if os(iOS)
            .contentShape(.rect(cornerRadius: Radius.field))
            .gesture(HorizontalPan(allows: { swipes(pick, toward: $0) }, changed: { track($0, on: pick) }, ended: { release(pick, commits: $0, velocity: $1) }))
        #endif
        return card
            .dockedPaper()
            .padding(.bottom, Self.below + Self.peek)
    }

    /// 卡浮着、露出的比例当不透明度用：减弱动态效果时。
    private var floats: Bool { reduceMotion }

    /// 跟上选中的那件：来了升起，都没了沉回去、沉完再拿掉，换了一件原地交替；减弱动态效果时来去都只淡。
    /// 页到前台之前就在等的不升起，当场就在（`watching`）。
    /// 升起用无回弹弹簧、从卡排进去的下一帧起播：卡插进来那一帧排版重，从这一帧起算的话前几十毫秒被吃掉。
    private func follow(animated: Bool) {
        guard let next = current else {
            guard shown != nil else { return }
            guard animated else { return leave() }
            // 沉到一半又来了一件时这一段被接走（`move` 的收尾看 `level`），不把它拿掉
            move(to: 0, Motion.fading(Motion.nudge, reduceMotion: reduceMotion)) { leave() }
            return
        }
        let swapping = shown != nil
        withAnimation(swapping && animated ? Motion.fade : nil) { shown = next }
        guard animated, level < 1, next.wait.since > watching else { return level = 1 }
        moving = true
        Task {
            await NextFrame.wait()
            guard shown?.id == next.id else { return moving = false }
            move(to: 1, Motion.fading(Motion.nudge, reduceMotion: reduceMotion))
        }
    }

    /// 播一段卡的来去，播着的时候 `moving`；动画走完再收尾。沉到一半又来了一件时前一段被接走，它的收尾不算数。
    private func move(to target: CGFloat, _ animation: Animation, then done: @escaping () -> Void = {}) {
        moving = true
        withAnimation(animation, completionCriteria: .removed) { level = target } completion: {
            guard level == target else { return }
            moving = false
            done()
        }
    }

    private func leave() {
        shown = nil
        level = 0
    }

    #if os(iOS)
    /// 这一拖归不归卡：那个方向还有一件（往左拖是下一件）；到头了不接。
    private func swipes(_ pick: CueWaitPick, toward velocity: CGFloat) -> Bool {
        pick.neighbor(by: velocity < 0 ? 1 : -1) != nil
    }

    /// 跟手；拖过头（那边没有下一件）越拖越沉。
    private func track(_ translation: CGFloat, on pick: CueWaitPick) {
        let open = pick.neighbor(by: translation < 0 ? 1 : -1) != nil
        drag = open ? translation : translation * 0.2
        if !reduceMotion { exit = translation < 0 ? -Self.flyOut : Self.flyOut }
    }

    /// 松手：甩过或拖过 `commit` 且那边有下一件就换（旧卡顺着飞出、新卡从叠边里上来），否则弹回。
    private func release(_ pick: CueWaitPick, commits: Bool, velocity: CGFloat) {
        let projected = drag + velocity * 0.12
        let next = commits && abs(projected) > Self.commit ? pick.neighbor(by: projected < 0 ? 1 : -1) : nil
        guard let next else {
            exit = 0
            withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { drag = 0 }
            return
        }
        withAnimation(Motion.fading(Motion.nudge, reduceMotion: reduceMotion), completionCriteria: .removed) {
            drag = 0
            workspace.cueAsking = next.id
            shown = next
        } completion: { exit = 0 }
    }

    /// 拖过这么远（连同甩的势头）就换一件；滑走的卡飞出这么远。
    private static let commit: CGFloat = 80
    private static let flyOut: CGFloat = 480
    #endif
}
