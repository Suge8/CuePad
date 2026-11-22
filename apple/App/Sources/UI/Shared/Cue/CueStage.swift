import CueStore
import SwiftUI

struct CueStage: View {
    let beat: CueBeat
    let status: String
    let brief: [CueBrief.Line]
    let period: Period
    let open: (CueBrief.Line) -> Void
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chatMargin) private var margin
    @Environment(\.chatBottomInset) private var below
    @Environment(\.chatHeight) private var visible
    @State private var shown = false
    @State private var base: CGFloat = 0
    @ScaledMetric(relativeTo: .body) private var row: CGFloat = 56
    @State private var settled = false

    static let revisit: TimeInterval = 30 * 60

    static func opens(left: Date?, at moment: Date) -> Bool {
        left.map { moment.timeIntervalSince($0) > revisit } ?? true
    }

    var body: some View {
        Color.clear
            .frame(height: max(visible - below, 0) + Sky.fade)
            .overlay {
                GeometryReader { room in
                    let side = max(margin, room.safeAreaInsets.leading, room.safeAreaInsets.trailing)
                    let lines = Array(brief.prefix(Sky.rows(in: room.size.height, base: base, row: row)))
                    let sky = Sky(
                        CGSize(width: room.size.width + 2 * side, height: room.size.height), chat: room.size.height + below, period: period,
                        bubble: base + CGFloat(lines.count) * row)
                    ZStack(alignment: .top) {
                        if sky.showsFigure { figure(sky) }
                        words(sky, lines: lines)
                    }
                    .frame(width: sky.size.width, height: room.size.height, alignment: .top)
                    .offset(x: -side)
                    .background(alignment: .top) { backdrop(sky).offset(x: -side, y: -Sky.fade) }
                }
                .padding(.top, Sky.fade)
            }
            .debugSettling(!settled)
            .task {
                shown = true
                try? await Task.sleep(for: .seconds(Motion.Stage.wordsDelay + Motion.Stage.riseDuration))
                settled = true
            }
    }

    private func backdrop(_ sky: Sky) -> some View {
        DitherImage(
            asset: sky.asset, placement: sky.placement.offsetBy(dx: 0, dy: Sky.fade), size: CGSize(width: sky.size.width, height: Sky.fade + sky.depth),
            fade: Sky.fade)
            .overlay { if beat == .away { palette.backdrop } }
            .readerHidden(true)
    }

    private func figure(_ sky: Sky) -> some View {
        Jelly(value: beat, look: { Pose($0) }, move: JellyMove.cue) { beat, _ in
            Image(decorative: Pose(beat).asset).resizable().frame(width: Pose.size.width * sky.figureScale, height: Pose.size.height * sky.figureScale)
        }
        .opacity(shown ? 1 : 0)
        .offset(y: shown || reduceMotion ? 0 : Sky.rise)
        .animation(Motion.fading(Motion.Stage.rise, reduceMotion: reduceMotion).delay(Motion.Stage.figureDelay), value: shown)
        .position(x: sky.size.width / 2, y: sky.perch + Pose.footing - Pose.size.height * sky.figureScale / 2)
        .readerHidden(true)
    }

    private func words(_ sky: Sky, lines: [CueBrief.Line]) -> some View {
        CueBriefBubble(beat: beat, status: status, lines: lines, row: row, open: open)
            .frame(maxWidth: CueBriefBubble.width)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if !lines.isEmpty { base = $0 - CGFloat(lines.count) * row } }
            .padding(.horizontal, margin)
            .padding(.top, sky.perch + Sky.wordsGap - SpeechShape.tail)
            .offset(y: shown || reduceMotion ? 0 : Sky.rise)
            .opacity(shown ? 1 : 0)
            .animation(Motion.fading(Motion.Stage.rise, reduceMotion: reduceMotion).delay(Motion.Stage.wordsDelay), value: shown)
            .animation(Motion.fade, value: lines)
    }
}

extension CueStage {
    struct Sky {
        static let fade: CGFloat = 96
        static let overscroll: CGFloat = 160
        static let step: CGFloat = 120
        static let headroom: CGFloat = 56
        static let floor: CGFloat = Spacing.block
        /// 云下沿到气泡：云本身的厚度。
        static let wordsGap: CGFloat = 36
        static let rise: CGFloat = 14

        let asset: String
        let size: CGSize
        let depth: CGFloat
        let placement: CGRect
        let perch: CGFloat
        let figureScale: CGFloat
        let showsFigure: Bool
        private static let leastScale: CGFloat = 0.6

        static func rows(in height: CGFloat, base: CGFloat, row: CGFloat) -> Int {
            let perch = headroom - Pose.footing + Pose.size.height * 0.85
            return max(0, Int(((height - floor - wordsGap + SpeechShape.tail - perch - base) / row).rounded(.down)))
        }

        static let line: CGFloat = 0.35

        init(_ size: CGSize, chat: CGFloat, period: Period, bubble: CGFloat) {
            self.size = size
            let cover = (chat / Self.step).rounded(.up) * Self.step
            depth = cover + Self.overscroll
            let wide = size.width > chat
            asset = "cue-stage-sky-\(period.rawValue)-\(wide ? "wide" : "tall")"
            let line = Self.line
            let aspect: CGFloat = wide ? 941 / 1672 : 1.5
            let goal = wide ? max(size.height * 0.3, 230) : max(cover, size.width * aspect) * line
            let room = size.height - Self.floor - bubble - Self.wordsGap + SpeechShape.tail
            let lowest = Self.headroom - Pose.footing + Pose.size.height * Self.leastScale
            showsFigure = room >= lowest
            perch = showsFigure ? min(goal, room) : Self.headroom - Self.wordsGap + SpeechShape.tail
            figureScale = min(size.width > 700 ? 1.15 : 1, max(Self.leastScale, (perch + Pose.footing - Self.headroom) / Pose.size.height))
            let height = max(size.width * aspect, perch / line, (cover - perch) / (1 - line))
            let width = height / aspect
            placement = CGRect(x: (size.width - width) / 2, y: perch - height * line, width: width, height: height)
        }
    }

    enum Period: String {
        case dawn, day, dusk, night

        init(at moment: Date, dark: Bool, calendar: Calendar = .current) {
            if let pinned = DebugHooks.preset.cueSky.flatMap(Period.init(rawValue:)) { self = pinned; return }
            guard !dark else { self = .night; return }
            self = switch calendar.component(.hour, from: moment) {
            case 5..<9: .dawn
            case 9..<17: .day
            case 17..<20: .dusk
            default: .night
            }
        }
    }

    struct Pose: Hashable {
        static let size = CGSize(width: 200, height: 190)
        static let footing: CGFloat = 12

        let asset: String

        init(_ beat: CueBeat) { asset = "cue-stage-\(beat.pose)" }
    }
}
