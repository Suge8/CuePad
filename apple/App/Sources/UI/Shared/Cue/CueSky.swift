import CueStore
import SwiftUI

/// Cue 页一直铺着的底：按时段的天空，小人（随 `CueBeat` 换姿势）歇在回复框上方那朵云上。它是背景，对话从它上面滑过，不接点击、读屏不读。
/// 有对话时小人沉进云里：对话贴着回复框往上排（`ChatScroll` 的底部对齐），一条就压在它身上；对话空了再冒出来。
/// 云与小人按页的大小定位，不跟回复框的高：回复框长高或卡升起时盖住它，不挪云——天空换一次位置就要整张重新抖动一遍（`DitherImage`）。
struct CueSky: View {
    let beat: CueBeat
    let perched: Bool
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { room in
            let inset = room.safeAreaInsets
            let size = CGSize(width: room.size.width + inset.leading + inset.trailing, height: room.size.height + inset.top + inset.bottom)
            let sky = Sky(size, floor: Sky.floor + inset.bottom, period: Period(at: .now, dark: palette.dark))
            ZStack(alignment: .topLeading) {
                DitherImage(asset: sky.asset, placement: sky.placement, size: size)
                if beat == .away { palette.backdrop }
                figure(sky)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .offset(x: -inset.leading, y: -inset.top)
        }
        .allowsHitTesting(false)
        .readerHidden(true)
    }

    private func figure(_ sky: Sky) -> some View {
        let height = Pose.size.height * sky.scale, ground = sky.perch + Pose.footing * sky.scale
        return Jelly(value: beat, look: { Pose($0) }, move: JellyMove.cue) { beat, _ in
            Image(decorative: Pose(beat).asset).resizable().frame(width: Pose.size.width * sky.scale, height: height)
        }
        .position(x: sky.size.width / 2, y: ground - height / 2)
        .offset(y: perched || reduceMotion ? 0 : height)
        .opacity(perched || !reduceMotion ? 1 : 0)
        .mask(alignment: .top) { Rectangle().frame(height: ground) }
        .animation(Motion.fading(Motion.travel, reduceMotion: reduceMotion), value: perched)
    }
}

extension CueSky {
    /// 页底到云面（小人脚下）的距离、小人头顶到云面的高：欢迎页的字排在这之上。
    static var reach: CGFloat { Sky.floor + Pose.size.height }

    struct Sky {
        /// 页底到云面：一只空着的回复框加上它下面的边。
        static let floor: CGFloat = 112
        /// 云面在图里的高度（占图高的几成），两种图同一处。
        private static let line: CGFloat = 0.35

        let asset: String
        let size: CGSize
        let placement: CGRect
        let perch: CGFloat
        let scale: CGFloat

        init(_ size: CGSize, floor: CGFloat, period: Period) {
            self.size = size
            let wide = size.width > size.height
            asset = "cue-stage-sky-\(period.rawValue)-\(wide ? "wide" : "tall")"
            let aspect: CGFloat = wide ? 941 / 1672 : 1.5
            perch = max(Pose.size.height, size.height - floor)
            scale = min(1, size.width / 320)
            let height = max(size.width * aspect, perch / Self.line, (size.height - perch) / (1 - Self.line))
            let width = height / aspect
            placement = CGRect(x: (size.width - width) / 2, y: perch - height * Self.line, width: width, height: height)
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
