import SwiftUI

/// Cue 页的舞台：新来访时（`CueStage.opens`）对话先让给这一幕：云上的 Cue 摆着此刻那一拍的姿势（`Pose`），云下一句它此刻最该让你知道的事（`Line`）。
/// 天空是一张图，浅色画白天、深色画夜里（按外观，不按钟点）；窄的用竖图、宽的用横图。Cue 站的那朵云在图里的高度是图高的一个比例（`Sky.perch`），
/// 图只等比铺开，人与字都从那一线往下排；图下沿以下铺图底的颜色（`palette.sky`），输入框与拍板卡浮在上面。
/// 进场只放一次（天空从近处拉远落定，Cue 与字随后浮上来），之后整幕静止：Cue 页在静置测量的范围里，不放常驻动效。换拍子是 Cue 跳一下换姿势（`Jelly`，同头像）。
/// 自己收起（回到对话）只有两处：往下拉过头、点"看对话"；输入框聚焦与发出由页收（`CuePage`）。
struct CueStage: View {
    let beat: CueBeat
    let now: CueNow
    /// 左边让给常驻会话条的宽（手机）：天空照样铺满整页，Cue 与字在让出之后的那块里居中。
    var leading: CGFloat = 0
    let close: () -> Void
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    /// 进场放完：截图的就绪等它（`debugSettling`），进场里的字与 Cue 还没到位。
    @State private var settled = false
    @GestureState private var pull: CGFloat = 0

    /// 离开 Cue 页超过这么久再回来算一次新来访，舞台重开；短暂离开回来原样。30 分钟是网站统计切分来访的常见默认。
    static let revisit: TimeInterval = 30 * 60

    /// 头一回来（没记过离开）也算新来访。
    static func opens(left: Date?, at moment: Date) -> Bool {
        left.map { moment.timeIntervalSince($0) > revisit } ?? true
    }

    /// 往下拉过这么多就收起；拉的时候整幕只跟手走三成，读作有阻力的一拉，不是拖走一张纸。
    private static let pullToClose: CGFloat = 72
    private static let pullFollow: CGFloat = 0.3

    var body: some View {
        GeometryReader { room in
            let sky = Sky(room.size, leading: leading, top: room.safeAreaInsets.top)
            ZStack(alignment: .top) {
                palette.sky
                Image(decorative: sky.asset)
                    .resizable()
                    .frame(width: sky.width, height: sky.height)
                    .scaleEffect(shown || reduceMotion ? 1 : Sky.approach, anchor: UnitPoint(x: 0.5, y: sky.perchUnit))
                    .position(x: sky.mid, y: sky.top + sky.height / 2)
                if beat == .away { palette.backdrop.transition(.opacity) }
                glow(sky)
                figure(sky)
                words(sky)
                    .padding(.leading, leading)
                    .frame(width: room.size.width, height: room.size.height, alignment: .top)
            }
            .offset(y: pull * Self.pullFollow)
            .opacity(shown ? 1 : 0)
            // 在铺开安全区之后的框里裁：裁在外面就裁回安全区里，页头底下空一截；不裁的话宽的天空画进旁边的栏
            .frame(width: room.size.width, height: room.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .contentShape(.rect)
        .gesture(DragGesture(minimumDistance: Spacing.group).updating($pull) { drag, pull, _ in pull = max(0, drag.translation.height) }
            .onEnded { if $0.translation.height > Self.pullToClose { close() } })
        .animation(Motion.spatial(Motion.release, reduceMotion: reduceMotion), value: pull == 0)
        .animation(Motion.fade, value: beat)
        .debugSettling(!settled)
        .onAppear {
            withAnimation(Motion.fading(Motion.Stage.unveil, reduceMotion: reduceMotion)) { shown = true } completion: { settled = true }
        }
    }

    /// 对话在舞台"上面"（更早的话），往下拉、点它都是把对话拉下来。挨着那一句放：底下是拍板卡与输入框，高低随卡变，放那里会被卡压住。
    private var more: some View {
        Button(action: close) {
            Label("看对话", icon: .collapse).font(Typography.secondary).foregroundStyle(palette.ink2)
        }
        .buttonStyle(PressStyle(.inline))
    }

    /// 脚下那团光随拍子换色（等你是赭黄、做完是绿、在动是靛蓝），不在的时候灭了。叠加着画：天亮的地方亮一点，天暗的地方像云被照着。
    private func glow(_ sky: Sky) -> some View {
        let color = beat == .failed ? palette.failure : beat.tone.color(palette)
        return Ellipse()
            .fill(EllipticalGradient(colors: [color, color.opacity(0)], center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5))
            .frame(width: Sky.glow.width, height: Sky.glow.height)
            .blendMode(.plusLighter)
            .opacity(beat == .away ? 0 : Sky.glowStrength)
            .position(x: sky.mid, y: sky.perch - Sky.glow.height / 4)
            .readerHidden(true)
    }

    private func figure(_ sky: Sky) -> some View {
        Jelly(value: beat, look: { Pose($0) }, move: JellyMove.cue) { beat, _ in
            Image(decorative: Pose(beat).asset).resizable().frame(width: Pose.size.width * sky.figureScale, height: Pose.size.height * sky.figureScale)
        }
        .opacity(shown ? 1 : 0)
        .scaleEffect(shown || reduceMotion ? 1 : Sky.approach, anchor: .bottom)
        .animation(Motion.fading(Motion.Stage.rise, reduceMotion: reduceMotion).delay(Motion.Stage.figureDelay), value: shown)
        .position(x: sky.mid, y: sky.perch + Pose.footing - Pose.size.height * sky.figureScale / 2)
        .readerHidden(true)
    }

    private func words(_ sky: Sky) -> some View {
        let line = Line(beat: beat, now: now)
        return VStack(spacing: Spacing.item) {
            if let brow = line.brow {
                Text(brow.text).font(Typography.label).foregroundStyle(brow.tone.color(palette))
            }
            Text(line.head).font(Typography.heading).foregroundStyle(palette.ink)
                .multilineTextAlignment(.center).lineLimit(3)
                .contentTransition(.opacity)
            more.padding(.top, Spacing.item)
        }
        .frame(maxWidth: CuePage.readingWidth)
        .padding(.horizontal, CuePage.inset)
        .padding(.top, sky.perch + Sky.wordsGap)
        .offset(y: shown || reduceMotion ? 0 : Sky.wordsRise)
        .opacity(shown ? 1 : 0)
        .animation(Motion.fading(Motion.Stage.rise, reduceMotion: reduceMotion).delay(Motion.Stage.wordsDelay), value: shown)
        .animation(Motion.fade, value: line)
    }
}

extension CueStage {
    /// 天空图怎么铺：图是生成的，云的高度量自图本身（竖图 30%、横图 35.5%，白天与夜里两张对齐过）。
    /// 竖图的高在可见高的八成与宽的 1.62～1.75 倍之间：手机上云落在三成高处，高瘦的屏不把云推到太下面；
    /// 横图铺满宽与高、再上移到云落在可见高的 30%（至少 230 点：Mac 栏头浮在内容上、不进安全区，Cue 的头要低过它）。两种都以 Cue 所在那块的中线为中线，宽要盖住离中线远的那一边。
    /// 云不高过安全区（状态栏、页头）往下 Cue 身高的六成：Cue 的头低于状态栏，页头两侧的圆钮在它左右（名牌这时让开，`CueHeader`）。
    struct Sky {
        static let approach: CGFloat = 1.12
        static let glow = CGSize(width: 360, height: 170)
        static let glowStrength = 0.55
        /// 云下沿到第一行字：云本身的厚度。
        static let wordsGap: CGFloat = 34
        static let wordsRise: CGFloat = 14

        let asset: String
        let width: CGFloat
        let height: CGFloat
        let top: CGFloat
        let mid: CGFloat
        let perch: CGFloat
        let figureScale: CGFloat
        var perchUnit: CGFloat { (perch - top) / height }

        init(_ size: CGSize, leading: CGFloat, top inset: CGFloat) {
            mid = leading + (size.width - leading) / 2
            let span = 2 * max(mid, size.width - mid)
            figureScale = size.width - leading > 700 ? 1.15 : 1
            let lowest = inset + Pose.size.height * figureScale * 0.6
            if size.width > size.height {
                asset = "cue-stage-sky-wide"
                let scale = max(span / 1672, size.height / 941)
                (width, height) = (1672 * scale, 941 * scale)
                let line = height * 0.355
                top = min(0, max(size.height * 0.3, 230, lowest) - line)
                perch = top + line
            } else {
                asset = "cue-stage-sky-tall"
                height = max(min(max(size.height * 0.8, size.width * 1.62), size.width * 1.75), span * 1.5, lowest / 0.3)
                width = height / 1.5
                top = 0
                perch = height * 0.3
            }
        }
    }

    /// 六张姿势图同一块画布（200×190 点），身子的中线对在画布正中、脚底贴着下沿：换姿势时 Cue 不横跳。
    /// 站在云上那一下：脚底压进云顶这么深，像踩在软的上面。
    struct Pose: Hashable {
        static let size = CGSize(width: 200, height: 190)
        static let footing: CGFloat = 12

        let asset: String

        init(_ beat: CueBeat) {
            asset = switch beat {
            case .resting, .hearing: "cue-stage-idle"
            case .thinking, .failed: "cue-stage-think"
            case .delegating: "cue-stage-wave"
            case .waiting: "cue-stage-offer"
            case .done: "cue-stage-jump"
            case .away: "cue-stage-sleep"
            }
        }
    }

    /// 云下那一句：等你时说有几件（是哪一件由下面的拍板卡说，`CueWaitDock`，这里不另挑一件），做完是做完的那件，等子代理是在等的那件，
    /// 其余是此刻那一句（`CueNow.quietLine`）。上面一行小字只在有一件具体的事时写它是哪种（做完、等子代理），颜色同各处的数字账。
    struct Line: Equatable {
        struct Brow: Equatable {
            let text: String
            let tone: CueNow.Tone
        }

        let brow: Brow?
        let head: String

        init(beat: CueBeat, now: CueNow) {
            let item = now.items.first { item in
                switch beat {
                case .done: item.kind == .done
                case .delegating: item.kind == .delegating
                default: false
                }
            }
            brow = item.map { Brow(text: $0.kind.label, tone: $0.kind.tone) }
            head = beat == .waiting ? String(localized: "有 \(now.tally.needsYou) 件等你") : item?.name ?? now.quietLine
        }
    }
}

private extension CueBeat {
    var tone: CueNow.Tone {
        switch self {
        case .waiting: .asks
        case .done: .done
        case .thinking, .hearing, .delegating: .moving
        case .resting, .away, .failed: .quiet
        }
    }
}
