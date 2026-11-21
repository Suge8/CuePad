import CueStore
import SwiftUI

/// 回复到了没有：最新一条回复的时刻，Mac 上是不是已经在出字。变了就是到了，角色碎开让位（`LiveFigure`）。
nonisolated struct FigureHandoff: Equatable {
    var reply: Date?
    var speaking = false
}

/// 此刻在做什么：姿势，以及旁边三层字——动作（大字，一道亮带扫过）、这一轮用了多久、作用在哪（等宽小字）。
nonisolated struct FigureLive: Equatable {
    var pose: FigurePose
    var verb: String
    var detail: String?
    /// 这一轮从何时起，计时从这里数；没有（你的话还在路上）就从角色出现那一刻数。
    var since: Date?
}

extension FigureLive {
    /// `now`：这一轮从何时算与实时活动同一处（`CueNow.Brain.working`）。
    init?(cue presence: CuePresence, now: CueNow) {
        guard let shown = presence.shown else { return nil }
        switch presence {
        case .working(let state, let detail, let step):
            let parts = detail.flatMap(SessionProgress.parts)
            let since: Date? = if case .working(_, _, let since) = now.cue { since } else { nil }
            self.init(pose: FigurePose(state), verb: step.flatMap { CueActivity.verb($0.kind) } ?? parts?.verb ?? shown.label,
                      detail: step?.name ?? parts?.target.map(SessionProgress.gist), since: since)
        default:
            self.init(pose: .listening, verb: shown.label)
        }
    }

    init?(session: SessionState) {
        let working = session.runtimeState.isWorking
        // 交回了的子代理还列在会话上，不算在忙
        guard working || session.runtimeSubagents.contains(where: \.isRunning) else { return nil }
        let shown = SessionShown(session)
        let pose = working ? FigurePose(session.runtimeState.known ?? .thinking) : .delegating
        let parts = pose == .delegating ? nil : session.detail.flatMap(SessionProgress.parts)
        self.init(pose: pose, verb: parts?.verb ?? shown.label,
                  detail: pose == .delegating ? SubagentLine.of(session.runtimeSubagents) : parts?.target,
                  since: session.turnStartedAt ?? session.busySince)
    }
}

extension FigurePose {
    nonisolated init(_ state: WorkState) {
        self = switch state {
        case .tool: .tool
        case .compacting: .compacting
        case .delegating: .delegating
        default: .thinking
        }
    }
}

/// 一轮在跑时对话末尾的 Cue 角色与旁边的字（Cue 页是 Cue 本人，会话里替 Agent 出场）。
/// 来：格子从下面飞上来拼成角色，同时这一块从一行长到角色那么高；打开页面时一轮已在跑就本来在那，不拼。
/// 中途换状态只换动作，每个状态至少停 `dwell`：Agent 一秒里能在想与用工具之间来回好几次，每次都换的话动作字浮上来、对象解码、
/// 角色蹲一下迸火星一秒五遍，读作在抖；中间的不丢，到点换成最新的那份。
/// 走：回复一落下（`handoff` 变了），这一块在插进回复的同一次排版里收回（在 body 里比，不等 onChange 再排一遍），角色改成从这一块往上悬着、
/// 正压在回复长出来的地方碎开——对话净高几乎不变、不滑，回复像是从角色身上长出来的。收回要是动画或晚一拍，回复先把角色挤到回复框底下、
/// 对话再被拉回来，跳两下。一轮停下了回复还没到（同步晚一步）就轻轻一跳等着（`lingering`），最多等 `lingerLimit`，没有回复接上就连同这一块一起收。
/// 碎开与之后的 `restLimit` 里不理状态变化：说完一句接着干活的，歇一下再拼回来，不在回复刚落下时又顶出来。
/// 停在一帧时（`LoopsPlay` 为假）不拼不碎，整块淡入淡出。
struct LiveFigure: View {
    let live: FigureLive?
    let handoff: FigureHandoff
    @State private var stage = Stage.absent
    @State private var arrives = false
    @State private var arrivedAt = Date.now
    /// 眼下这份状态是何时换上的（`dwell` 从这里数）。
    @State private var shownAt = Date.now
    /// 角色这次出现时的那份；与眼下的不同就是回复已经到了。
    @State private var arrivedWith = FigureHandoff()
    @State private var visible = true
    @LoopsPlay private var plays
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated enum Stage: Equatable {
        case absent, here(FigureLive), lingering(FigureLive), leaving(FigureLive), resting

        var shown: FigureLive? {
            switch self {
            case .absent, .resting: nil
            case .here(let live), .lingering(let live), .leaving(let live): live
            }
        }
    }

    static let dwell: TimeInterval = 0.6
    static let lingerLimit: Duration = .seconds(1)
    static let restLimit: Duration = .milliseconds(800)

    var body: some View {
        let handed = stage.shown != nil && handoff != arrivedWith
        let holds = switch stage {
        case .here, .lingering: !handed
        case .absent, .leaving, .resting: false
        }
        ZStack(alignment: .topLeading) {
            if let shown = stage.shown { row(shown, fading: handed || stage == .leaving(shown)) }
        }
        .frame(maxWidth: .infinity, minHeight: holds ? FigureLayout.size : 0, maxHeight: holds ? FigureLayout.size : 0, alignment: handed ? .bottomLeading : .topLeading)
        .onAppear {
            FigureGPU.warm()
            if stage == .absent, let live { show(live, arriving: false) }
        }
        .onChange(of: live) { reconcile() }
        // 换下一份在这里：live 一变就重开，拿到的总是最新那份
        .task(id: live) { await follow() }
        .onChange(of: stage) { if stage == .absent { reconcile() } }
        // 只认相对出场时那份变了：草稿清掉转回干活时 live 与 handoff 同一次更新里变，角色先按新的那份出场，这里不能再把它当回复送走
        .onChange(of: handoff) {
            guard handoff != arrivedWith else { return }
            switch stage {
            case .here(let last), .lingering(let last): leave(last, handed: true)
            case .absent, .leaving, .resting: break
            }
        }
        .task(id: stage) {
            switch stage {
            case .lingering(let last):
                guard await wait(Self.lingerLimit) else { return }
                leave(last, handed: false)
            case .leaving:
                guard await wait(.seconds(FigureMotion.leaveDuration)) else { return }
                stage = .resting
            case .resting:
                guard await wait(Self.restLimit) else { return }
                stage = .absent
            case .absent, .here:
                return
            }
        }
    }

    private func row(_ shown: FigureLive, fading: Bool) -> some View {
        let pose: FigurePose = if case .lingering = stage { .done } else { shown.pose }
        return HStack(alignment: .center, spacing: Spacing.group) {
            Color.clear.frame(width: FigureLayout.size, height: FigureLayout.size)
                .overlay(alignment: .topLeading) {
                    FigureCanvas(pose: pose, arrives: arrives, leaving: fading, running: plays && visible)
                        .offset(x: -FigureLayout.origin.x, y: -FigureLayout.origin.y)
                }
                .opacity(plays || !fading ? 1 : 0)
            FigureStatus(live: shown, since: shown.since ?? arrivedAt)
                .opacity(fading ? 0 : 1)
        }
        .frame(height: FigureLayout.size)
        // 量角色本身，不量这一块：回复接上时这一块已收成零高、按它量就算不在可见区，画布停在那一帧、碎不开
        .onScrollVisibilityChange(threshold: 0.05) { visible = $0 }
        .transition(.opacity)
    }

    /// 来、走与等回复。在场时换状态归 `follow`；碎开、歇着时不理（`leaving`、`resting` 到点后回到 `absent` 再对一次）。
    private func reconcile() {
        switch (stage, live) {
        case (.absent, let next?):
            show(next, arriving: true)
        case (.lingering, let next?):
            shownAt = .now
            stage = .here(next)
        case (.here(let last), nil):
            stage = .lingering(last)
        default:
            break
        }
    }

    private func follow() async {
        guard case .here(let last) = stage, let live, live != last else { return }
        let left = shownAt.addingTimeInterval(Self.dwell).timeIntervalSinceNow
        if left > 0 {
            guard await wait(.seconds(left)) else { return }
        }
        guard case .here = stage else { return }
        shownAt = .now
        stage = .here(live)
    }

    private func show(_ live: FigureLive, arriving: Bool) {
        arrives = arriving
        arrivedAt = .now
        shownAt = .now
        arrivedWith = handoff
        withAnimation(arriving ? grow : nil) { stage = .here(live) }
    }

    private func leave(_ last: FigureLive, handed: Bool) {
        // 回复接上的那次这一块已经在 body 里收了，只剩角色碎开
        withAnimation(plays ? (handed ? nil : grow) : Motion.fade) { stage = .leaving(last) }
    }

    private func wait(_ duration: Duration) async -> Bool { (try? await Task.sleep(for: duration)) != nil }

    /// 这一块长出、收回：与角色拼起、碎开同一拍，挪一百多点，用远距离那一档。
    private var grow: Animation { Motion.spatial(Motion.travel, reduceMotion: reduceMotion) ?? Motion.fade }
}

/// 角色旁边的三层字。动作换了从下面浮上来（`DoingLine`），对象先闪几帧像素块再从左往右解出来，和角色的格子是一个调子。
private struct FigureStatus: View {
    let live: FigureLive
    let since: Date
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.hair) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.item) {
                DoingLine(text: live.verb).font(Typography.bodyStrong).lineLimit(1)
                Text(timerInterval: since...Date.distantFuture, countsDown: false)
                    .font(Typography.secondary.monospacedDigit()).foregroundStyle(palette.ink3).fixedSize()
            }
            // 对象那一行没有时也占着：整块跟角色竖着居中，行数一变动作那行就上下跳半行（在想与用工具交替时一步一跳）
            ZStack(alignment: .leading) {
                Text(verbatim: " ").hidden()
                if let detail = live.detail { DecodingText(text: detail).lineLimit(1).truncationMode(.middle) }
            }
            .font(Typography.codeNote).foregroundStyle(palette.ink3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([live.verb, live.detail].compactMap(\.self).joined(separator: " "))
    }
}

private struct DecodingText: View {
    let text: String
    @State private var shown: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let glyphs = Array("▖▗▘▝▚▞▙▟▛▜░▒")
    /// 整句至多这么多帧（每帧 30ms）解完：路径长时一帧多解几个字。Agent 换步可以快到零点几秒一步，解得慢就一直在闪、读不出字。
    private static let frames = 8

    var body: some View {
        Text(shown ?? text)
            .task(id: text) {
                guard !reduceMotion else { shown = nil; return }
                let letters = Array(text), pace = max(1.4, Double(letters.count) / Double(Self.frames - 4))
                for frame in 0... {
                    let revealed = Double(frame) * pace - 4 * pace
                    guard revealed < Double(letters.count) else { break }
                    shown = String(letters.enumerated().map { i, c in Double(i) < revealed || c == " " ? c : Self.glyphs.randomElement()! })
                    guard (try? await Task.sleep(for: .milliseconds(30))) != nil else { return }
                }
                shown = nil
            }
    }
}
