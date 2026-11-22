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
    private static let height = FigureLayout.size - FigureLayout.headroom
    static let lingerLimit: Duration = .seconds(1)
    static let restLimit: Duration = .milliseconds(800)

    var body: some View {
        let handed = stage.shown != nil && handoff != arrivedWith
        let holds = switch stage {
        case .here, .lingering: !handed
        case .absent, .leaving, .resting: false
        }
        ZStack(alignment: .topLeading) {
            if let shown = stage.shown { row(shown, fading: handed || stage == .leaving(shown)).offset(y: holds ? -FigureLayout.headroom : 0) }
        }
        .frame(maxWidth: .infinity, minHeight: holds ? Self.height : 0, maxHeight: holds ? Self.height : 0, alignment: handed ? .bottomLeading : .topLeading)
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
        withAnimation(plays ? (handed ? nil : grow) : Motion.fade) { stage = .leaving(last) }
    }

    private func wait(_ duration: Duration) async -> Bool { (try? await Task.sleep(for: duration)) != nil }

    private var grow: Animation { Motion.spatial(Motion.travel, reduceMotion: reduceMotion) ?? Motion.fade }
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
