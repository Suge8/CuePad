import CueStore
import SwiftUI

nonisolated struct FigureHandoff: Equatable {
    var reply: Date?
    var speaking = false
}

nonisolated struct FigureLive: Equatable {
    var pose: FigurePose
    var verb: String
    var detail: String?
    var since: Date?
}

extension FigureLive {
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

struct LiveFigure: View {
    let live: FigureLive?
    let handoff: FigureHandoff
    @State private var stage = Stage.absent
    @State private var arrives = false
    @State private var arrivedAt = Date.now
    @State private var shownAt = Date.now
    @State private var arrivedWith = FigureHandoff()
    @State private var visible = true
    @State private var speaks = true
    @State private var pin: CGFloat = 0
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
    /// 新来时先聚成形、再开口：字与它一起出现的话，字比还是一团点的它先被看见。
    static let speakAfter: Duration = .milliseconds(350)
    private static let height = FigureLayout.size - FigureLayout.headroom
    static let lingerLimit: Duration = .seconds(1)
    static let restLimit: Duration = .milliseconds(800)

    /// 不占位时（交给回复、一轮做完）原地碎开：画在占位时最后的位置（`pin`），不跟着这一块挪——回复从它头上长出来把这一块往下推，
    /// 对话这时也不动（让出的高留成留白，`ChatScroll.keep`），跟着挪的话它一下跳到字上、再随每一行往下掉。
    /// 位置量在对话内容里（`chatContentSpace`）：对话整段上滑是渲染端的平移，它照样跟着走。此刻的位置在画的这一遍里读（`visualEffect`）：
    /// 经状态回报的话回复长出来的那一帧还按旧位置画，它先跳到字上、下一帧才回来。
    var body: some View {
        let handed = stage.shown != nil && handoff != arrivedWith
        let holds = switch stage {
        case .here, .lingering: !handed
        case .absent, .leaving, .resting: false
        }
        ZStack(alignment: .topLeading) {
            if let shown = stage.shown { row(shown, fading: handed || stage == .leaving(shown)).offset(y: -FigureLayout.headroom) }
        }
        .frame(maxWidth: .infinity, minHeight: holds ? Self.height : 0, maxHeight: holds ? Self.height : 0, alignment: .topLeading)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(chatContentSpace)) } action: { if holds { pin = $0.minY } }
        .visualEffect { [holds, pin] content, place in
            content.offset(y: holds ? 0 : pin - place.frame(in: .named(chatContentSpace)).minY)
        }
        .onAppear {
            FigureGPU.warm()
            if stage == .absent, let live { show(live, arriving: false) }
        }
        .onChange(of: live) { reconcile() }
        .task(id: live) { await follow() }
        .onChange(of: stage) { if stage == .absent { reconcile() } }
        .onChange(of: handoff) {
            guard handoff != arrivedWith else { return }
            switch stage {
            case .here(let last), .lingering(let last): stage = .leaving(last)
            case .absent, .leaving, .resting: break
            }
        }
        .task(id: stage) {
            switch stage {
            case .lingering(let last):
                guard await wait(Self.lingerLimit) else { return }
                stage = .leaving(last)
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
                .animation(Motion.fade, value: fading)
            FigureStatus(live: shown, since: shown.since ?? arrivedAt)
                .opacity(fading || !speaks ? 0 : 1)
        }
        .frame(height: FigureLayout.size)
        // 量角色本身，不量这一块：回复接上时这一块已收成零高、按它量就算不在可见区，画布停在那一帧、碎不开
        .onScrollVisibilityChange(threshold: 0.05) { visible = $0 }
        .task(id: arrivedAt) {
            guard !speaks, await wait(Self.speakAfter) else { return }
            withAnimation(Motion.fade) { speaks = true }
        }
        .transition(.opacity)
    }

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

    /// 来去都不带动画改这一块的高（`stage`）：对话的长高、变矮由滚动区统一滑（`ContentLift`、`ChatScroll.keep`），
    /// 这里再带一段弹簧的话，对话不满一屏时整段的位置是排版算的、也跟着弹，两段相加先往下掉一截再升上来。来是画布里聚成形，去是碎开。
    private func show(_ live: FigureLive, arriving: Bool) {
        arrives = arriving
        speaks = !arriving || reduceMotion
        arrivedAt = .now
        shownAt = .now
        arrivedWith = handoff
        stage = .here(live)
    }

    private func wait(_ duration: Duration) async -> Bool { (try? await Task.sleep(for: duration)) != nil }
}

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
