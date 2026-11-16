import CueStore
import SwiftUI

/// Cue 页的舞台：新来访时（`CueStage.opens`）对话先让给这一幕：云上的 Cue 摆着此刻那一拍的姿势（`Pose`），云下一句它此刻最该让你知道的那一件（`Focus`）。
/// 那一件有要看的正文、要你点的动作时接着排在那一句下面（`Details`），不另起一张卡：拍板时底下已有拍板卡，一屏只一张卡；没有正文时一张只放一颗钮的卡是空的。
/// 天空是一张图，浅色画白天、深色画夜里（按外观，不按钟点）；窄的用竖图、宽的用横图。Cue 站的那朵云在图里的高度是图高的一个比例（`Sky.perch`），
/// 图只等比铺开，人与字都从那一线往下排；图下沿以下铺图底的颜色（`palette.sky`），输入框与拍板卡浮在上面。
/// 进场只放一次（天空从近处拉远落定，Cue 与字随后浮上来），之后整幕静止：Cue 页在静置测量的范围里，不放常驻动效。换拍子是 Cue 跳一下换姿势（`Jelly`，同头像）。
/// 自己收起（回到对话）在往下拉过头、点"看对话"、点那一件的动作（`Details`）时；输入框聚焦与发出由页收（`CuePage`）。
struct CueStage: View {
    let beat: CueBeat
    let focus: Focus
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
        let line = focus.line
        return VStack(spacing: Spacing.item) {
            if let brow = line.brow {
                Text(brow.text).font(Typography.label).foregroundStyle(brow.mark.color(palette)).lineLimit(1)
            }
            Text(line.head).font(Typography.heading).foregroundStyle(palette.ink)
                .multilineTextAlignment(.center).lineLimit(3)
                .contentTransition(.opacity)
            Details(focus: focus, close: close).id(focus)
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
    /// 横图铺满宽与高、再上移到云落在可见高的 30%（至少 230 点：Mac 栏头浮在内容上、不进安全区，Cue 的头要低过它）；矮的栏里图本身的云低不到那里，就放大到够。两种都以 Cue 所在那块的中线为中线，宽要盖住离中线远的那一边。
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

    /// 舞台上那一件，按先后只挑一件（规则只在这里）：不在、出错最先（别的动作这时都做不成），然后要你动手的（拍板、新回复），
    /// 再是给你看一眼的（新消息、刚做完），都没有时是不用你管的（等子代理、在想、歇着）。姿势照旧跟拍子（`Pose`），这里只定说哪件、点什么。
    enum Focus: Hashable {
        case away(String, failed: Bool)
        case asks(Int)
        case reply(CueNow.Item)
        case said(Said)
        case done(CueNow.Item)
        case delegating(CueNow.Item)
        case quiet(String)

        init(now: CueNow, said: Said?) {
            let item = { (kind: CueNow.Item.Kind) in now.items.first { $0.kind == kind } }
            if case .away(let reason, let failed) = now.cue {
                self = .away(reason, failed: failed)
            } else if now.tally.asks > 0 {
                self = .asks(now.tally.asks)
            } else if let reply = item(.reply) {
                self = .reply(reply)
            } else if let said {
                self = .said(said)
            } else if now.beat == .done, let done = now.justDone {
                self = .done(done)
            } else if now.beat == .delegating, let waiting = item(.delegating) {
                self = .delegating(waiting)
            } else {
                self = .quiet(now.quietLine)
            }
        }

        /// 云下的字：上面一行小字说是哪种（颜色同各处的数字账，出错是玫红、新消息是你那句话的靛青），下面一句大字说是哪件。
        /// 拍板不写小字：哪件、问什么在拍板卡上，这里只说有几件。
        var line: Line {
            switch self {
            case .away(let reason, let failed): Line(brow: failed ? Brow(text: String(localized: "出错了"), mark: .failed) : nil, head: reason)
            case .asks(let count): Line(brow: nil, head: String(localized: "有 \(count) 件等你拍板"))
            case .reply(let item), .done(let item), .delegating(let item): Line(brow: Brow(text: item.kind.label, mark: .tone(item.kind.tone)), head: item.name)
            case .said(let said):
                Line(brow: Brow(text: said.asked.map { String(localized: "你问：\($0)") } ?? String(localized: "新消息"), mark: .said), head: said.head)
            case .quiet(let line): Line(brow: nil, head: line)
            }
        }
    }

    struct Line: Equatable {
        let brow: Brow?
        let head: String
    }

    struct Brow: Equatable {
        let text: String
        let mark: Mark
    }

    enum Mark: Equatable {
        case tone(CueNow.Tone)
        case failed
        case said

        func color(_ palette: Palette) -> Color {
            switch self {
            case .tone(let tone): tone.color(palette)
            case .failed: palette.failure
            case .said: palette.signature
            }
        }
    }

    /// 还没读的头一条 Cue 的话（`CueThread.unread`）：第一句上舞台，其余在卡上；它回的是你哪一句（它之前你说的最后一句）写在小字里。
    struct Said: Hashable {
        let asked: String?
        let head: String
        let rest: String

        init?(_ thread: CueThread) {
            guard let index = thread.messages.firstIndex(where: { thread.unread.contains($0.id) }) else { return nil }
            asked = thread.messages[..<index].last { $0.author == .known(.you) }.flatMap { SessionProgress.firstLine($0.text) }
            let plain = MarkdownBlock.plainText(thread.messages[index].text).trimmingCharacters(in: .whitespacesAndNewlines)
            let end = plain.firstIndex { "。！？!?\n".contains($0) }
            head = end.map { String(plain[...$0]) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? plain
            rest = end.map { plain[plain.index(after: $0)...].trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
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

/// 云下那一句之后的正文与动作：新回复是会话最后说的那段与"去会话里看"，新消息是 Cue 那段话第一句之后的部分与"接着聊"（第一句已在上面）。
/// 点了舞台就收起：接着聊、去会话再回来，都是回到对话。换了一件是另一份（调用方按 `focus` 给身份），读会话的订阅跟着换。
private struct Details: View {
    let focus: CueStage.Focus
    let close: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    /// 会话最后说的那段（新回复）；不是新回复时读成空。
    @State private var reply: String?

    var body: some View {
        let session = sessionID
        VStack(spacing: Spacing.group) {
            if let text, !text.isEmpty {
                Text(verbatim: text).font(Typography.body).foregroundStyle(palette.ink2).multilineTextAlignment(.center).lineLimit(Self.lines)
            }
            if let label {
                Button(action: act) { Text(label) }.buttonStyle(ControlButtonStyle(kind: .primary))
            }
        }
        .padding(.top, Spacing.item)
        .observing(services.store, into: $reply, onError: workspace.fail) { store in try session.flatMap { try store.sessionState($0)?.lastReply } ?? "" }
    }

    private static let lines = 4

    /// 待回复的 id 是 "reply/会话 id"（`CueTally.Reply.id`）。
    private var sessionID: String? {
        if case .reply(let item) = focus { String(item.id.dropFirst("reply/".count)) } else { nil }
    }

    private var text: String? {
        switch focus {
        case .reply: reply.map { MarkdownBlock.plainText($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        case .said(let said): said.rest
        default: nil
        }
    }

    private var label: LocalizedStringKey? {
        switch focus {
        case .reply: "去会话里看"
        case .said: "接着聊"
        default: nil
        }
    }

    private func act() {
        close()
        if let sessionID {
            workspace.openSession(SessionState.recordID(sessionID: sessionID), sessionID: sessionID)
        } else {
            workspace.cueFocusPending = true
        }
    }
}
