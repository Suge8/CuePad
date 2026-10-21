import CueStore
import CueText
import SwiftUI

/// "等你"：固定在输入框上方，最早的那一条（从任务看板点进来的那条先露，`Workspace.leadingAsk`），收得紧。第一句是要你定什么，由代码按 Cue 写的动作短语写出
/// （`CueAsking.question`），不靠 Cue 的措辞；Cue 的原话默认收起，点"原话"再看（长了在里面滚）。下面是 Cue 点名要你看的图与各看什么
/// （`CueShots`，没点名的没有图；点开全屏时底栏就是这几个选项，看完当场定）、选项（`CueChoices`），末行是关联的任务与原话的开关
/// （Mac 上连同选项；辅助功能字号下各占一行），Mac 与手机同一结构；还有几条在等由页头与侧栏的"等你 M"说。卡上只能选：别的话在 Cue 页底下的输入框说，
/// 一开口卡就收起（Cue 判断不是在答它会放回，见 `CueQuestionEnd`）。没有关掉。
/// 列表与数量只来自 `cueMessagesWaitingForYou()`：回答后等库里那条结束才换下一条，写的时候按钮停用；没写成就报错、按钮恢复，可以再点。
struct CueWaitingDock: View {
    let waiting: [CueMessage]
    let tasks: [UUID: CueTaskRef]
    /// 提问点名的图（`CueThread.shots`）
    let shots: [UUID: [CueShown]]
    let open: (PreviewOpening) -> Void
    /// 卡正在升起、沉下或淡入淡出：这期间对话不另外往上滑（`ChatColumn` 的 `holding`），只跟着它让出的高挪，停了再滑一次。
    @Binding var moving: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.chatHeight) private var chatHeight
    /// 正在结束的那条（写成后它从 `waiting` 里消失，写不成就清掉）。
    @State private var ending: UUID?
    /// 展开了原话的那条：换下一条时自动收起。
    @State private var reading: UUID?
    /// 露出的那条：在等的第一条；答完沉下去的这一段里还是它（那时它已不在 `waiting` 里）。
    @State private var shown: CueMessage?
    /// 露出了多少，0…1：升起的比例（`RiseBehind`，0 是全藏在输入框后面）；减弱动态效果时是不透明度。
    @State private var level: CGFloat

    /// 页打开时已经在等的那张随页一起排出来、不升起（同 `follow` 的头一次）：等 `onChange` 再放的话卡晚一次更新才排，
    /// 对话按它让出的高又要重排一遍。
    init(waiting: [CueMessage], tasks: [UUID: CueTaskRef], shots: [UUID: [CueShown]], open: @escaping (PreviewOpening) -> Void, moving: Binding<Bool>) {
        self.waiting = waiting
        self.tasks = tasks
        self.shots = shots
        self.open = open
        _moving = moving
        _shown = State(initialValue: waiting.first)
        _level = State(initialValue: waiting.isEmpty ? 0 : 1)
    }

    /// 来了从输入框后面升起、答完沉回去（`RiseBehind`，露出的比例是状态、随曲线变：做成移除的过渡的话，沉回去那一下不动画，卡一帧就没了）；
    /// 一条换下一条时新卡在原地与旧卡交叉淡（底边对齐叠放，竖排的话两张同时占位、底栏一下高一倍）。减弱动态效果时只淡入淡出：
    /// 占的高跟着有没有在等的一下到位、卡浮着淡，对话只定位一次。占的高由对话让出（卡在浮着的回复框里，`FloatingReply`）。
    /// 卡与下面输入框的间距在卡里（`below`）：没有在等的时候这一层不占位，也不留出间距。
    var body: some View {
        ZStack(alignment: .bottom) {
            if let message = shown {
                // 只有换下一条时带动画（交叉淡）；头一张出现与沉完拿掉都不带，过渡不播
                card(waiting.first { $0.id == message.id } ?? message)
                    .id(message.id)
                    .transition(.opacity)
            }
        }
        .opacity(reduceMotion ? level : 1)
        .modifier(RiseBehind(shown: reduceMotion ? (waiting.isEmpty ? 0 : 1) : level, floats: reduceMotion, limit: chatHeight / 2))
        .onChange(of: waiting.first?.id, initial: true) { old, new in follow(animated: old != new) }
    }

    private static let below: CGFloat = 8
    /// 卡的内边距：下边小，末行自带可点的高，字离卡底看着与上边距差不多。
    private static let padding = EdgeInsets(top: 16, leading: 16, bottom: 6, trailing: 16)

    #if os(macOS)
    /// 卡至少多高（Cue 页打开时数要排几格，`CuePage.covered`）：内边距与卡底的间距、问句（至少一行标题字）、带图时一排图
    /// （`CueShots.floor`，卡宽 `width` 去掉两边内边距）、末行（`footerHeight`）；原话收着。只能数少。
    static func floor(_ message: CueMessage, shots: [UUID: [CueShown]], width: CGFloat) -> CGFloat {
        let pictures = shots[message.id].map { 16 + CueShots.floor(count: $0.count, width: width - padding.leading - padding.trailing) } ?? 0
        return padding.top + Typography.titleSize + pictures + footerGap + footerHeight + padding.bottom + below
    }
    #endif

    /// 跟上在等的第一条：来了升起，没了沉下去、沉完再拿掉，换了一条原地交替；减弱动态效果时来去都只淡。
    /// 升起用无回弹弹簧、从卡排进去的下一帧起播：卡插进来那一帧排版重，从这一帧起算的话前几十毫秒被吃掉，看着是冒一点、停一下、窜一大截。
    /// 沉下用定长曲线（`Motion.move`）：弹簧最后那段一两点的尾巴要再画上百毫秒，沉到底前卡剩一道细线停在输入框上（升起的尾巴停在整高处，看不见）。
    /// 减弱动态效果时淡入稍慢、淡出要快：淡出时对话已在终位，卡叠在字上的那几帧越短越好。
    private func follow(animated: Bool) {
        guard let next = waiting.first else {
            guard shown != nil else { return }
            guard animated else { return leave() }
            move(to: 0, reduceMotion ? .easeOut(duration: Motion.handOff) : Motion.move) { if waiting.isEmpty { leave() } }
            return
        }
        let swapping = shown != nil
        withAnimation(swapping && animated ? Motion.quick : nil) { shown = next }
        guard animated, level < 1 else { return level = 1 }
        moving = true
        Task {
            await NextFrame.wait()
            guard shown?.id == next.id else { return moving = false }
            move(to: 1, reduceMotion ? Motion.quick : Motion.snappy)
        }
    }

    /// 播一段卡的来去，播着的时候 `moving`；动画走完再收尾。沉到一半又来了一条时前一段被接走，它的收尾不算数（目标已经变了）。
    private func move(to target: CGFloat, _ animation: Animation, then done: @escaping () -> Void = {}) {
        moving = true
        withAnimation(animation, completionCriteria: .removed) { level = target } completion: {
            guard level == target else { return }
            moving = false
            done()
        }
    }

    /// 拿掉：沉到底或淡没了，这时已看不见，不再播过渡。
    private func leave() {
        shown = nil
        level = 0
    }

    /// 从上到下：问句（规矩那一类下面是规矩原话）、一排图、操作。卡至多占对话区可见高的一半，地方不够时只用剩下的（`RiseLayout`）。
    /// Mac 上放不下时上面那段在卡里滚、操作钉在卡底。手机上（键盘弹出、小屏、横屏）按能放下的挑（`ViewThatFits`，按各自的实际高）：
    /// 整张 → 紧凑（去掉那排图；问句与选项钉住，展开的原话在中间滚，末行放得下才露）→ 只剩问句一行（`folded`）。
    /// 紧凑那档的理想高只算问句与选项（原话与末行都是 `Yielding`），所以"问句加选项都放不下"才收成一行；哪一档都不会截出半截字或半张图。
    /// 放得下时不进滚动区：滚动区里的按钮按下要晚一下才有反馈。Mac 上不挑（挑的话几份都要建，第一次打开 Cue 页时卡多建一遍）。
    /// 手机上选项竖排（`CueChoices`）、下面任务与原话一行（辅助功能字号下各占一行）；Mac 上合成一行，右下角是"可以"。
    private func card(_ message: CueMessage) -> some View {
        let ref = message.taskID.flatMap { tasks[$0] }
        let choices = CueChoices(options: message.choices ?? [], disabled: ending == message.id) { answer(message, $0) }
        let side = Self.padding.leading
        #if os(macOS)
        let body = VStack(spacing: 0) {
            Yielding { ScrollView { upper(message, shots: true) }.scrollBounceBehavior(.basedOnSize) }
            footer(message, ref, choices).padding(.top, Self.footerGap)
                .padding(.horizontal, side).padding(.bottom, Self.padding.bottom).layoutPriority(1)
        }
        #else
        let choicesRow = choices.padding(.top, 16).padding(.horizontal, side)
        let footerRow = Group {
            if typeSize.isAccessibilitySize {
                // 任务至多两行、不截断
                VStack(alignment: .leading, spacing: 0) {
                    if let ref { CueTaskLine(ref: ref, height: Self.footerHeight, lines: 2) }
                    originalToggle(message)
                }
            } else {
                footer(message, ref, nil)
            }
        }
        .padding(.top, 4).padding(.horizontal, side)
        let body = ViewThatFits(in: .vertical) {
            VStack(spacing: 0) {
                upper(message, shots: true)
                choicesRow
                footerRow
            }
            .padding(.bottom, Self.padding.bottom)
            VStack(spacing: 0) {
                CueQuestionLine(message: message).padding(.top, Self.padding.top).padding(.horizontal, side)
                if reading == message.id {
                    Yielding { ScrollView { original(message.text).padding(.top, 12).padding(.horizontal, side) }.scrollBounceBehavior(.basedOnSize) }
                }
                choicesRow
                Yielding { ViewThatFits(in: .vertical) { footerRow; Color.clear.frame(height: 0) } }
            }
            .padding(.bottom, Self.padding.bottom)
            folded(message)
        }
        #endif
        return body
            .paper(radius: ComposerMetrics.radius, lifted: true)
            .animation(Motion.quick, value: reading)
            .padding(.bottom, Self.below)
    }

    #if os(iOS)
    /// 连紧凑的样子都放不下（横屏弹着键盘）：整张卡收成问句一行，放不下的用省略号。点它收起键盘，地方够了卡就按上面的挑法展开。
    private func folded(_ message: CueMessage) -> some View {
        Button {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        } label: {
            HStack(spacing: 9) {
                PiStateGlyph(status: .asking).font(Typography.title)
                Text(message.headline ?? "").font(Typography.title).foregroundStyle(palette.ink).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Self.padding.leading)
            .frame(minHeight: Self.footerHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("收起键盘，展开这张卡")
    }
    #endif

    /// 卡里上面那段：问句、展开的原话、一排图（`shots` 为 false 是紧凑的样子，不带图）。
    private func upper(_ message: CueMessage, shots showsShots: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CueQuestionLine(message: message)
            if reading == message.id { original(message.text).padding(.top, 12).transition(.opacity) }
            if showsShots, let shots = shots[message.id] {
                CueShots(shots: shots, group: "waiting", reply: .answer(message), open: open).padding(.top, 16)
            }
        }
        .padding(.top, Self.padding.top).padding(.horizontal, Self.padding.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 末行（任务、原话；Mac 上连同选项）可点的高。
    private static let footerHeight: CGFloat = 44

    /// 末行：任务在左；带选项时（Mac）原话紧跟任务（间距 20）、选项在尾端，不带时原话在右端。
    private func footer(_ message: CueMessage, _ ref: CueTaskRef?, _ choices: CueChoices?) -> some View {
        HStack(spacing: 0) {
            if let ref {
                CueTaskLine(ref: ref, height: Self.footerHeight).accessibilitySortPriority(1).padding(.trailing, choices == nil ? 10 : 20)
            }
            if let choices {
                originalToggle(message)
                Spacer(minLength: 16)
                choices.accessibilitySortPriority(2)
            } else {
                Spacer(minLength: 0)
                originalToggle(message)
            }
        }
        .accessibilityElement(children: .contain)
    }
    #if os(macOS)
    /// 末行离上面的问句与图。
    private static let footerGap: CGFloat = 12
    #endif

    /// Cue 的原话：整段排在问句下面，长了随卡里那段一起滚。
    private func original(_ text: String) -> some View {
        MarkdownText(source: text).equatable().font(Typography.secondary).foregroundStyle(palette.ink2)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func originalToggle(_ message: CueMessage) -> some View {
        let open = reading == message.id
        return Button { reading = open ? nil : message.id } label: {
            HStack(spacing: 4) {
                Text("原话")
                Image(.expand).font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(open ? 180 : 0))
            }
            .font(Typography.meta.weight(.medium)).foregroundStyle(palette.ink2)
            .frame(minHeight: Self.footerHeight).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(open ? "收起原话" : "看 Cue 的原话")
    }

    private func answer(_ message: CueMessage, _ choice: String) {
        ending = message.id
        workspace.attempt {
            defer { ending = nil }
            try await workspace.services.answerCueQuestion(message.id, choice)
        }
    }
}

extension Workspace {
    /// "等你"卡露的先后：从任务看板点进来的那条（`cueAsking`）还在等就排到最前，其余照旧从早到晚。
    func leadingAsk(_ waiting: [CueMessage]) -> [CueMessage] {
        guard let id = cueAsking, let index = waiting.firstIndex(where: { $0.id == id }), index > 0 else { return waiting }
        var ordered = waiting
        ordered.insert(ordered.remove(at: index), at: 0)
        return ordered
    }
}
