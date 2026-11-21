import CueStore
import SwiftUI

/// Cue 页对话的尽头。新来访时（`CueStage.opens`）对话末尾不是那一行小 Cue（`CueEnding`），而是铺满一屏的这一幕：网点的天上，云上的 Cue 摆着此刻那一拍的姿势（`Pose`），
/// 云下一个气泡说它此刻的样子，下面是你不在时攒下的几件（`CueBrief`），一行一件、点了就到。打开时停在最新处就是它；往上滑是历史，滑回来它还在（"回到最新"同会话页）。
/// 你开口（输入框聚焦、发出）它才收成那一行（`CuePage`）。它是对话里的最后一格：在屏上时最后几条话在它上面、不在可见区，不算读过（`CueEndProbe`）。
/// 天空是一张照片抖成网点（`DitherImage`），按打开那一刻的时段换一张（`Period`），横着铺满整栏（伸出读宽，`chatMargin`），往下伸到回复框底下；上沿那一截散成透明，融进对话的底，不画一条边。
/// 散开的那一截在这一格的可见区上面：停在舞台上时满屏是天、页头底下不见一层渐变，往上滑才看到它散进上一条话。
/// Cue 是软的立体、天是平的网点，一前一后分得开。进场只放一次（Cue 与字浮上来），之后整幕静止：Cue 页在静置测量的范围里，不放常驻动效。换拍子是 Cue 跳一下换姿势（`Jelly`，同头像）。
/// 否决过：舞台盖在对话上、往下拉收起（拉一下就看历史去了，这一趟回不来）；气泡里只挑一件说（常与拍板卡重复）；没事时列几件灵感请你点头（App 按规则挑的，不是 Cue 想做的，没人点）。
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
    /// 气泡里除去各行的高（那一句与边距），量出来的。
    @State private var base: CGFloat = 0
    /// 各行一样高：放得下几行按它算，不等排出来再删。
    @ScaledMetric(relativeTo: .body) private var row: CGFloat = 56
    /// 进场放完：截图的就绪等它（`debugSettling`）。
    @State private var settled = false

    /// 离开 Cue 页超过这么久再回来算一次新来访，舞台重开；短暂离开回来原样。30 分钟是网站统计切分来访的常见默认。
    static let revisit: TimeInterval = 30 * 60

    /// 头一回来（没记过离开）也算新来访。
    static func opens(left: Date?, at moment: Date) -> Bool {
        left.map { moment.timeIntervalSince($0) > revisit } ?? true
    }

    var body: some View {
        Color.clear
            .frame(height: max(visible - below, 0) + Sky.fade)
            .overlay {
                GeometryReader { room in
                    let side = margin
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
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { base = $0 - CGFloat(lines.count) * row }
            .padding(.horizontal, margin)
            .padding(.top, sky.perch + Sky.wordsGap - SpeechShape.tail)
            .offset(y: shown || reduceMotion ? 0 : Sky.rise)
            .opacity(shown ? 1 : 0)
            .animation(Motion.fading(Motion.Stage.rise, reduceMotion: reduceMotion).delay(Motion.Stage.wordsDelay), value: shown)
            .animation(Motion.fade, value: lines)
    }
}

extension CueStage {
    /// 这一格就是可见区里回复框以上那一截。Cue 站的那朵云（`perch`）先照图排：竖图铺满对话区、云在图高的 `line`；
    /// 横图铺满宽、云落在格高的 30%（至少 230 点：Mac 栏头浮在内容上，Cue 的头要低过它）。云下放不下气泡时（手机上拍板卡升着）云往上提到放得下；
    /// 提到云上只放得下八成五的 Cue 时，气泡少列几行（排在后面的先不列，至少留那一句），Cue 再缩也不小过六成，再放不下就不画 Cue。图跟着云走。
    struct Sky {
        /// 上沿散成透明的那一截。
        static let fade: CGFloat = 96
        static let overscroll: CGFloat = 160
        static let step: CGFloat = 120
        /// 云上留给状态栏与页头圆钮的那一截：Cue 的头低过它。
        static let headroom: CGFloat = 56
        /// 气泡离这一格下沿（回复框上沿）。
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

        /// 这一格里气泡能列几行：云上至少留八成五的 Cue。
        static func rows(in height: CGFloat, base: CGFloat, row: CGFloat) -> Int {
            let perch = headroom - Pose.footing + Pose.size.height * 0.85
            return max(0, Int(((height - floor - wordsGap + SpeechShape.tail - perch - base) / row).rounded(.down)))
        }

        /// Cue 站的那朵云的顶在图里的高度，八张图量过都在这一线（生成时按它摆）。
        static let line: CGFloat = 0.35

        /// `chat`：整个对话区的高（连回复框底下），图的下沿至少到它（照片拉不出下沿，拉出去的只是糊开的竖纹）；天再往下多伸一截（`depth`），贴底回弹时不露出对话的底。
        /// 都按一段一段取整：卡升起时回复框每帧长高，跟着重算网点就每帧一张。
        init(_ size: CGSize, chat: CGFloat, period: Period, bubble: CGFloat) {
            self.size = size
            let cover = (chat / Self.step).rounded(.up) * Self.step
            depth = cover + Self.overscroll
            let wide = size.width > size.height
            asset = "cue-stage-sky-\(period.rawValue)-\(wide ? "wide" : "tall")"
            let line = Self.line
            let aspect: CGFloat = wide ? 941 / 1672 : 1.5
            let goal = wide ? max(size.height * 0.3, 230) : max(cover, size.width * aspect) * line
            let room = size.height - Self.floor - bubble - Self.wordsGap + SpeechShape.tail
            let lowest = Self.headroom - Pose.footing + Pose.size.height * Self.leastScale
            // 连那一句都放不下六成的 Cue 时（横着的手机、拍板卡升着）不画 Cue，气泡顶到页头下面：画了头就出屏
            showsFigure = room >= lowest
            perch = showsFigure ? min(goal, room) : Self.headroom - Self.wordsGap + SpeechShape.tail
            figureScale = min(size.width > 700 ? 1.15 : 1, max(Self.leastScale, (perch + Pose.footing - Self.headroom) / Pose.size.height))
            let height = max(size.width * aspect, perch / line, (cover - perch) / (1 - line))
            let width = height / aspect
            placement = CGRect(x: (size.width - width) / 2, y: perch - height * line, width: width, height: height)
        }
    }

    /// 一天里的四个时段，各一张天（竖横各一）。打开舞台那一刻取一次，看着不变。深色外观一律是夜里：白天的亮天垫在深色的玻璃后面刺眼。
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

    /// 六张姿势图同一块画布（200×190 点），身子的中线对在画布正中、脚底贴着下沿：换姿势时 Cue 不横跳。
    /// 站在云上那一下：脚底压进云顶这么深，像踩在软的上面。
    struct Pose: Hashable {
        static let size = CGSize(width: 200, height: 190)
        static let footing: CGFloat = 12

        let asset: String

        init(_ beat: CueBeat) { asset = "cue-stage-\(beat.pose)" }
    }
}
