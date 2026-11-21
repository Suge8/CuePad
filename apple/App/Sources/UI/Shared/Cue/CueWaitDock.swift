import CueStore
import SwiftUI

struct CueWaitDock: View {
    let waiting: [CueWait]
    let asking: String?
    let shots: [UUID: [CueShown]]
    let open: (PreviewOpening) -> Void
    @Binding var moving: Bool
    #if os(iOS)
    @Environment(Workspace.self) private var workspace
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pageActive) private var active
    /// 读屏停在哪件的"第几件"上（`CueWaitEyebrow`）：换一件时卡按件换身份（叠边里上浮、旧卡飞出的转场靠它），读屏的焦点随旧卡一起没了，
    /// 换完由卡把焦点放到新那件的这一格（`CueWaitCard.step`）。记在这里不记在卡里：旧卡走了它还在。
    @AccessibilityFocusState private var counter: String?
    @State private var drag: CGFloat = 0
    @State private var exit: CGFloat = 0
    @State private var shown: CueWaitPick?
    @State private var level: CGFloat
    @State private var watching = Date.now

    init(waiting: [CueWait], asking: String?, shots: [UUID: [CueShown]], open: @escaping (PreviewOpening) -> Void, moving: Binding<Bool>) {
        self.waiting = waiting
        self.asking = asking
        self.shots = shots
        self.open = open
        _moving = moving
        _shown = State(initialValue: Self.pick(in: waiting, asking: asking))
        _level = State(initialValue: waiting.isEmpty ? 0 : 1)
    }

    static func current(in waiting: [CueWait], asking: String?) -> CueWait? {
        pick(in: waiting, asking: asking)?.wait
    }

    private static func pick(in waiting: [CueWait], asking: String?) -> CueWaitPick? {
        guard !waiting.isEmpty else { return nil }
        return CueWaitPick(waits: waiting, index: waiting.firstIndex { $0.id == asking } ?? 0)
    }

    private var current: CueWaitPick? { Self.pick(in: waiting, asking: asking) }

    private func live(_ pick: CueWaitPick) -> CueWaitPick {
        waiting.firstIndex { $0.id == pick.id }.map { CueWaitPick(waits: waiting, index: $0) } ?? CueWaitPick(waits: [pick.wait], index: 0)
    }

    /// 来了从输入框后面升起、都答完沉回去（`RiseBehind`，同会话页的整卡）：对话跟着让出的高每帧挪。答完时同一次更新里对话长出这一问与回答，那一下先不跟（`CuePage` 的 `sinking`），沉的这一段压着（`moving`），沉完再一次滑上去。
    /// 否决过浮在原处淡掉、让出的高一下收掉：长出的与让出的不一样高时对话当帧挪那一截差（卡上带图时上百点）。
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
        .background { if shown != nil { deck } }
        .opacity(floats ? level : 1)
        .modifier(RiseBehind(shown: floats ? (waiting.isEmpty ? 0 : 1) : level, floats: floats))
        .onChange(of: current?.id, initial: true) { old, new in follow(animated: old != new) }
        .onChange(of: active) { if active { watching = .now } }
        .debugSettling(moving)
    }

    static let below = Spacing.item
    private static let peek: CGFloat = 8
    private static let tuck: CGFloat = 12

    private var deck: some View {
        let behind = waiting.count > 1
        return Color.clear
            .dockedPaper()
            .opacity(behind ? 1 : 0)
            .padding(.horizontal, Self.tuck)
            .padding(.top, Self.peek)
            .padding(.bottom, Self.below)
            .animation(Motion.fade, value: behind)
            .readerHidden(true)
    }

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

    private var floats: Bool { reduceMotion }

    private func follow(animated: Bool) {
        guard let next = current else {
            guard shown != nil else { return }
            guard animated else { return leave() }
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
    private func swipes(_ pick: CueWaitPick, toward velocity: CGFloat) -> Bool {
        pick.neighbor(by: velocity < 0 ? 1 : -1) != nil
    }

    private func track(_ translation: CGFloat, on pick: CueWaitPick) {
        let open = pick.neighbor(by: translation < 0 ? 1 : -1) != nil
        drag = open ? translation : translation * 0.2
        if !reduceMotion { exit = translation < 0 ? -Self.flyOut : Self.flyOut }
    }

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

    private static let commit: CGFloat = 80
    private static let flyOut: CGFloat = 480
    #endif
}
