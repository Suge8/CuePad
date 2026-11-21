import CueStore
import SwiftUI

/// Cue 页的舞台：新来访时（`CueStage.opens`）对话先让给这一幕：云上的 Cue 摆着此刻那一拍的姿势（`Pose`），云下一句它此刻最该让你知道的那一件（`Focus`）。
/// 那一件是 Cue 说出来的一个气泡（`CueBalloon`），尾巴指着云上的它：来由、那一句、正文与去处在同一块玻璃里，整块点得动。不另起卡：拍板时底下已有拍板卡，一屏只一张卡。
/// 天空是一张图，浅色画白天、深色画夜里（按外观，不按钟点）；窄的用竖图、宽的用横图。Cue 站的那朵云在图里的高度是图高的一个比例（`Sky.perch`），
/// 图只等比铺开，人与字都从那一线往下排。图抖成三种墨的网点（`DitherImage`、`palette.skyInks`）再铺满整块，图下沿以下接着抖图边上的颜色：
/// Cue 是软的立体，天是平的网点，一前一后分得开。输入框与拍板卡浮在上面。
/// 进场只放一次（天空从近处拉远落定，Cue 与字随后浮上来），之后整幕静止：Cue 页在静置测量的范围里，不放常驻动效。换拍子是 Cue 跳一下换姿势（`Jelly`，同头像）。
/// 自己收起（回到对话）在往下拉过头、点气泡时；输入框聚焦与发出由页收（`CuePage`）。
struct CueStage: View {
    let beat: CueBeat
    let focus: Focus
    /// 字两侧在 `CuePage.inset` 之外再让的宽（手机让给常驻会话条，同对话）：天空照样铺满整页，Cue 与字按整屏居中。
    var sides: CGFloat = 0
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
            let sky = Sky(room.size, top: room.safeAreaInsets.top)
            ZStack(alignment: .top) {
                palette.sky
                DitherImage(
                    asset: sky.asset, placement: CGRect(x: sky.mid - sky.width / 2, y: sky.top, width: sky.width, height: sky.height),
                    size: room.size, inks: palette.skyInks, tone: palette.dark ? Sky.nightTone : Sky.dayTone)
                    .scaleEffect(shown || reduceMotion ? 1 : Sky.approach, anchor: UnitPoint(x: sky.mid / room.size.width, y: sky.perch / room.size.height))
                if beat == .away { palette.backdrop.transition(.opacity) }
                glow(sky)
                figure(sky)
                words(sky)
                    .padding(.horizontal, sides)
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
        CueBalloon(focus: focus, close: close)
            .frame(maxWidth: CueBalloon.width)
            .padding(.horizontal, CuePage.inset)
            .padding(.top, sky.perch + Sky.wordsGap - CueBalloon.tail)
            .offset(y: shown || reduceMotion ? 0 : Sky.wordsRise)
            .opacity(shown ? 1 : 0)
            .animation(Motion.fading(Motion.Stage.rise, reduceMotion: reduceMotion).delay(Motion.Stage.wordsDelay), value: shown)
            .animation(Motion.fade, value: focus)
    }
}

extension CueStage {
    /// 天空图怎么铺：图是生成的，云的高度量自图本身（竖图 30%、横图 35.5%，白天与夜里两张对齐过）。
    /// 竖图的高在可见高的八成与宽的 1.62～1.75 倍之间：手机上云落在三成高处，高瘦的屏不把云推到太下面；
    /// 横图铺满宽与高、再上移到云落在可见高的 30%（至少 230 点：Mac 栏头浮在内容上、不进安全区，Cue 的头要低过它）；矮的栏里图本身的云低不到那里，就放大到够。两种都以 Cue 所在那块的中线为中线，宽要盖住离中线远的那一边。
    /// 云不高过安全区（状态栏、页头）往下 Cue 身高的六成：Cue 的头低于状态栏，页头两侧的圆钮在它左右（名牌这时让开，`CueHeader`）。
    struct Sky {
        static let approach: CGFloat = 1.12
        static let glow = CGSize(width: 360, height: 170)
        static let glowStrength = 0.55
        /// 云下沿到第一行字：云本身的厚度。
        static let wordsGap: CGFloat = 40
        static let wordsRise: CGFloat = 14

        let asset: String
        let width: CGFloat
        let height: CGFloat
        /// 图的明暗落在哪一段（量自图本身，竖图横图一样）：白天整张在亮的那半、夜里在暗的那半，拉开再抖。
        static let dayTone = 0.6...0.96
        static let nightTone = 0.06...0.62

        let top: CGFloat
        let mid: CGFloat
        let perch: CGFloat
        let figureScale: CGFloat

        init(_ size: CGSize, top inset: CGFloat) {
            mid = size.width / 2
            let span = 2 * max(mid, size.width - mid)
            figureScale = size.width > 700 ? 1.15 : 1
            let lowest = inset + Pose.size.height * figureScale * 0.6
            if size.width > size.height {
                asset = "cue-stage-sky-wide"
                let line: CGFloat = 0.355
                perch = max(size.height * 0.3, 230, lowest)
                let scale = max(span / 1672, size.height / 941, perch / (941 * line))
                (width, height) = (1672 * scale, 941 * scale)
                top = perch - height * line
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

        init(_ beat: CueBeat) { asset = "cue-stage-\(beat.pose)" }
    }

    /// 舞台上那一件，按先后只挑一件（规则只在这里）：不在、出错最先（别的动作这时都做不成），然后要你动手的（拍板、新回复），
    /// 再是给你看一眼的（新消息、做完没看的），都没有时是不用你管的（等子代理、在想、歇着）。姿势照旧跟拍子（`Pose`），这里只定说哪件、点什么。
    enum Focus: Hashable, Sendable {
        case away(String, failed: Bool)
        case asks(Int)
        case reply(CueNow.Item)
        case said(Said)
        case done(Done)
        case invite([CueInvite])
        case delegating(CueNow.Item)
        case quiet(String)

        init(now: CueNow, said: Said?, read: CueStageRead) {
            let item = { (kind: CueNow.Item.Kind) in now.items.first { $0.kind == kind } }
            if case .away(let reason, let failed) = now.cue {
                self = .away(reason, failed: failed)
            } else if now.tally.asks > 0 {
                self = .asks(now.tally.asks)
            } else if let reply = item(.reply) {
                self = .reply(reply)
            } else if let said {
                self = .said(said)
            } else if let done = read.done {
                self = .done(done)
            } else if !read.invites.isEmpty, !now.isBusy {
                self = .invite(read.invites)
            } else if now.beat == .delegating, let waiting = item(.delegating) {
                self = .delegating(waiting)
            } else {
                self = .quiet(now.quietLine)
            }
        }

    }

    /// 做完了、结果你还没看的那件（`CueStore.unseenDone`）：看结果就是看交给的那个会话，在那里看过它就下台。
    nonisolated struct Done: Hashable, Sendable {
        let task: UUID
        let title: String
        let session: String
    }

    /// 还没读的头一条 Cue 的话（`CueThread.unread`）：第一句是气泡的大字，其余是正文；它回的是你哪一句（它之前你说的最后一句）写在来由那一行。
    struct Said: Hashable, Sendable {
        let asked: String?
        let head: String
        let rest: String

        init?(_ thread: CueThread) {
            guard let index = thread.messages.firstIndex(where: { thread.unread.contains($0.id) }) else { return nil }
            asked = thread.messages[..<index].last { $0.author == .known(.you) }.flatMap { SessionProgress.firstLine($0.text) }
            (head, rest) = Self.split(thread.messages[index].text)
        }

        /// 第一句与其余：气泡里第一句是大字，其余是正文（新消息、新回复同一个截法）。
        static func split(_ text: String) -> (String, String) {
            let plain = MarkdownBlock.plainText(text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let end = plain.firstIndex(where: { "。！？!?\n".contains($0) }) else { return (plain, "") }
            return (String(plain[...end]).trimmingCharacters(in: .whitespacesAndNewlines),
                    plain[plain.index(after: end)...].trimmingCharacters(in: .whitespacesAndNewlines))
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
