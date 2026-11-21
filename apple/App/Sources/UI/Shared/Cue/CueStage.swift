import CueStore
import SwiftUI

/// Cue 页对话的尽头。新来访时（`CueStage.opens`）对话末尾不是那一行小 Cue（`CueEnding`），而是铺满一屏的这一幕：网点的天上，云上的 Cue 摆着此刻那一拍的姿势（`Pose`），
/// 云下一个气泡说它此刻的样子，下面是你不在时攒下的几件（`CueBrief`），一行一件、点了就到。打开时停在最新处就是它；往上滑是历史，滑回来它还在（"回到最新"同会话页）。
/// 你开口（输入框聚焦、发出）它才收成那一行（`CuePage`）。它是对话里的最后一格：在屏上时最后几条话在它上面、不在可见区，不算读过（`CueEndProbe`）。
/// 天空是一张照片抖成网点（`DitherImage`、`palette.skyInks`），横着铺满整栏（伸出读宽，`chatMargin`），往下伸到回复框底下；上沿那一截散成透明，融进对话的底，不画一条边。
/// Cue 是软的立体、天是平的网点，一前一后分得开。进场只放一次（Cue 与字浮上来），之后整幕静止：Cue 页在静置测量的范围里，不放常驻动效。换拍子是 Cue 跳一下换姿势（`Jelly`，同头像）。
/// 否决过：舞台盖在对话上、往下拉收起（拉一下就看历史去了，这一趟回不来）；气泡里只挑一件说（常与拍板卡重复）；没事时列几件灵感请你点头（App 按规则挑的，不是 Cue 想做的，没人点）。
struct CueStage: View {
    let beat: CueBeat
    let status: String
    let brief: [CueBrief.Line]
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
            .frame(height: max(visible - below, 0))
            .overlay {
                GeometryReader { room in
                    let side = margin
                    let lines = Array(brief.prefix(Sky.rows(in: room.size.height, base: base, row: row)))
                    let sky = Sky(CGSize(width: room.size.width + 2 * side, height: room.size.height), bubble: base + CGFloat(lines.count) * row)
                    ZStack(alignment: .top) {
                        figure(sky)
                        words(sky, lines: lines)
                    }
                    .frame(width: sky.size.width, height: room.size.height, alignment: .top)
                    .offset(x: -side)
                    .background(alignment: .top) { backdrop(sky).offset(x: -side) }
                }
            }
            .debugSettling(!settled)
            .task {
                shown = true
                try? await Task.sleep(for: .seconds(Motion.Stage.wordsDelay + Motion.Stage.riseDuration))
                settled = true
            }
    }

    /// 往下伸过回复框、再多一截：贴底回弹时底下不露出对话的底。高按一段一段取整，回复框长高一点不重算。
    private func backdrop(_ sky: Sky) -> some View {
        let height = ((sky.size.height + below + Sky.overscroll) / Sky.step).rounded(.up) * Sky.step
        return DitherImage(
            asset: sky.asset, placement: sky.placement, size: CGSize(width: sky.size.width, height: height),
            inks: palette.skyInks, tone: Sky.tone, fade: Sky.fade)
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
    /// 这一格就是可见区里回复框以上那一截。Cue 站的那朵云（`perch`）先照图排：竖图的高在格高的八成与宽的 1.62～1.75 倍之间、云在图高的 37%；
    /// 横图铺满宽与高、云落在格高的 30%（至少 230 点：Mac 栏头浮在内容上，Cue 的头要低过它）。云下放不下气泡时（手机上拍板卡升着）云往上提到放得下；
    /// 提到云上只放得下八成五的 Cue 时，气泡少列几行（排在后面的先不列，至少留那一句），Cue 再缩也不小过六成。图跟着云走：Cue 站的那朵云在图里的高度量自图本身（`line`：竖图 37%、横图 38%）。
    struct Sky {
        static let tone = 0.1...0.96
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
        let placement: CGRect
        let perch: CGFloat
        let figureScale: CGFloat

        /// 这一格里气泡能列几行：云上至少留八成五的 Cue。
        static func rows(in height: CGFloat, base: CGFloat, row: CGFloat) -> Int {
            let perch = headroom - Pose.footing + Pose.size.height * 0.85
            return max(0, Int(((height - floor - wordsGap + SpeechShape.tail - perch - base) / row).rounded(.down)))
        }

        init(_ size: CGSize, bubble: CGFloat) {
            self.size = size
            let wide = size.width > size.height
            let line: CGFloat = wide ? 0.38 : 0.37
            asset = wide ? "cue-stage-sky-wide" : "cue-stage-sky-tall"
            let width: CGFloat, height: CGFloat
            if wide {
                let scale = max(size.width / 1672, size.height / 941, max(size.height * 0.3, 230) / (941 * line))
                (width, height) = (1672 * scale, 941 * scale)
            } else {
                height = max(min(max(size.height * 0.8, size.width * 1.62), size.width * 1.75), size.width * 1.5)
                width = height / 1.5
            }
            let room = size.height - Self.floor - bubble - Self.wordsGap + SpeechShape.tail
            perch = min(wide ? max(size.height * 0.3, 230) : height * line, room)
            figureScale = min(size.width > 700 ? 1.15 : 1, max(0.6, (perch + Pose.footing - Self.headroom) / Pose.size.height))
            placement = CGRect(x: (size.width - width) / 2, y: perch - height * line, width: width, height: height)
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
