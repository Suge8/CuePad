import QuartzCore
import SwiftUI

/// Cue 与会话之间的"接力"：一束靛青的光沿弧交棒，两端同一套尺寸、曲线与时长。一次最多三道、错开 90ms。
/// - 叫醒（会话 → Cue）：状态标先漾开，小光点拖着细亮芯与宽淡尾飞向头像；将到时头像的环接亮，停一拍，再向外漾开两圈，不盖脸。
/// - 交给（Cue → 会话）：头像的环先亮，160ms 后一个空心小环带着尾巴离开；落点的珠子亮成实心、停一拍，再随外圈余光淡下去。
/// - 发出（你 → Cue）：发送钮纸飞机的机头当场变成光点，不另叠起飞环（`RelayLaunch`），落进头像同叫醒。
/// 飞行 0.78～1.08s，先提速、后缓缓被接住；拖尾是同一条弧上三截由亮到暗、由细到宽的描边，尾端稍后起步、落下时追上光头。
/// 弧向窗口竖中线鼓，几乎横着时向上鼓；来回同一条弧。短距离也至少鼓出 24pt，珠子与头像挨着仍看得清方向。
/// 起飞、飞行与落点余光总共约 1.7～2.2s（含最多三道错峰）：全 App 唯一超过 300ms 的动效，给低频的交棒留出看清两头的时间。
///
/// 两头各落在屏上哪一处，规则只在两个枚举里：Cue 那头按平台定一处（`CueSpot`），会话那头按具体程度取最具体的那处（`EndSpot`）。
/// Cue 那一行的珠子优先于会话自己那一行，同一级几处时取离头像近的，来回都接同一行的头像。
/// 开新会话（start）不在写下请求时飞，等开出的会话有了记录（`CueFlight.Handed`）才飞：优先珠子、否则新会话那一行；新行先占好位置、透明着，
/// 光落下的那一刻（落点那圈环的动画真的开始时，Core Animation 回调）才淡出来（`relayArrival`、`Stage.arriving`）。
///
/// 降级（两个方向同一条规则：没有一个看得见的东西就不凭空画，也不往屏外飞）：
/// - 会话那头连同"会话"那一格都不在屏上（推入的页、Mac 侧栏收起、iPad）：叫醒只在头像上亮环、漾开；交给是头像亮一下、环离开头像朝窗口中间飘一小段就淡去——"它把事交出去了"。
/// - 头像不在屏上（Mac 侧栏收起且不在 Cue 页，iPhone 推入的页，iPad 不在 Cue 页与侧栏收起时）：叫醒是起飞的环照样扩开、光从状态标升起一小段就淡去；
///   交给是只在会话那头外扩一圈、垫一层淡光。
/// - 两头都不在就什么都不画：Cue 的头像回到屏幕上时自己就在转环，会话的状态标自己会变。
/// - 同步追赶中（`AppServices.isCatchingUp`：启动、回到前台、下拉刷新那一拉，积压的一页页）带回来的不播：那是不在眼前时发生过的事。
/// - 减弱动态效果：不飞、不扩，头像的环与会话那头的状态标同时淡入一层高亮再淡出（1s），同 `Motion` 的约定只留透明度。
///
/// 接力只来自库里的事实，经 `LiveSessions.flight`（两个方向一个值，规则在 `CueFlight`）投影成只在变了时才写的值（打开资料库时已有的不算）；
/// 它与在做那一列同一份读到，重排那一列的写入与这次接力在同一次更新里到达，等一帧排好就量（`NextFrame`），不猜时长。
/// 页面换来换去也不播（挂在窗口根上，不随页面出现）。舞台只另记一件事：哪几个新会话还在等光落下（`Stage.arriving`）。
///
/// 性能：飞行整个交给 Core Animation（渲染服务插值，App 进程不逐帧参与），只在播时把一层画布挂到窗口的根层最上面，播完拿掉。
/// 不在每一行挂几何读数：只有此刻在接力的珠子、会话状态标与任务行挂一个空的锚视图，Cue 的几处头像各挂一个；
/// 空锚不做插入转场：继承到父级动画时，默认淡入会让新锚的宿主层首帧透明，把本来可见的落点误判成不在屏上。
/// 播的那一刻沿层树把锚换算到窗口根层的坐标，一并算进父层的裁切、隐藏与透明（滚出屏的、被盖住的页、开合到 0 的都算不在），
/// 工具栏、导航容器、分栏这些各自托管的视图都在同一棵层树里，不需要逐层换算。
/// 接住的那几圈挂在落点的锚自己的层上（`RelayFlight.Landing`）：量过之后落点又挪了（页头随换句重新居中、列表重排）圈也跟着锚走，
/// 且压在锚后面的字底下；飞的那道光仍沿播的那一刻量出的弧，落下那一下由渲染服务按锚此刻的位置画，不另量、不逐帧读几何。
/// 否决了 SwiftUI 的覆盖层加锚点偏好：偏好过不了 Mac 工具栏与 iOS 导航容器的托管边界，覆盖层也盖不住 Mac 的工具栏。
struct CueRelayStage: ViewModifier {
    let workspace: Workspace

    @State private var stage = Stage()

    // 窗口根上只放一个不变的引用：接力只在背景里那个小视图里看（`Watcher`），Cue 的现状怎么变根都不重算
    func body(content: Content) -> some View {
        content.environment(\.relayStage, stage).background(Watcher(workspace: workspace, stage: stage))
    }

    /// 只读 `LiveSessions.flight`（只在变了时才写）：又有一次就播。
    private struct Watcher: View {
        let workspace: Workspace
        let stage: Stage
        @Environment(\.palette) private var palette
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let live = workspace.services.liveSessions
            Probe(stage: stage, color: palette.signature)
                .onChange(of: live.flight?.at) {
                    guard let flight = live.flight, !workspace.services.isCatchingUp(on: workspace.cue.hostID) else { return }
                    stage.play(flight, reduceMotion: reduceMotion)
                }
        }
    }

    /// 本窗口的舞台：认得窗口（`Probe`），播时找锚、交给 `RelayFlight`；记着哪几个新开的会话还在等光落下。
    @Observable
    final class Stage {
        /// 这次交给开出的、光还没落下的会话（`relayArrival` 让它们的行与状态标透明着）。
        private(set) var arriving: Set<String> = []
        @ObservationIgnored fileprivate weak var host: RelayAnchorView?
        @ObservationIgnored fileprivate var color: CGColor?

        func play(_ flight: CueFlight, reduceMotion: Bool) {
            // 与新会话那一行同一次更新里就藏起来，不先露一帧
            arriving = Set(flight.ends.filter(\.opens).map(\.session))
            Task {
                // 在接力的那几处这一刻才挂上锚：等这一次更新排好、提交了再量
                await NextFrame.wait()
                guard let window = host?.window, let root = RelayAnchorView.rootLayer(of: window), let color else { return arriving = [] }
                let anchors = RelayAnchorView.all(in: window)
                let cue = RelayAnchorView.cue(among: anchors, in: root)
                let placed = Array(
                    flight.ends.compactMap { end in Self.place(of: end, among: anchors, in: root, near: cue?.center).map { (end.session, $0) } }
                        .prefix(RelayFlight.most))
                // 没有落点的不等
                arriving.formIntersection(placed.map(\.0))
                RelayFlight(color: color, reduceMotion: reduceMotion).play(flight.direction, cue: cue, ends: placed.map(\.1), in: root) { index in
                    self.arriving.remove(placed[index].0)
                }
            }
        }

        /// 会话那头在屏上的位置：最具体的那一级（`EndSpot.rank`），同一级几处都在时取离头像近的。
        /// 刚开出的会话那一行正透明着等光落下（`relayArrival`），量它时不看透明度。
        private static func place(of end: RelayEnd, among anchors: [RelayAnchorView], in root: CALayer, near cue: CGPoint?) -> RelayFlight.Landing? {
            anchors.compactMap { anchor -> (rank: Int, landing: RelayFlight.Landing)? in
                guard case .end(let spot) = anchor.role, let rank = spot.rank(for: end),
                      let frame = anchor.frame(in: root, seesThrough: end.opens && rank == EndSpot.Row.own.rawValue) else { return nil }
                return (rank, RelayFlight.Landing(point: frame.center, host: anchor.layer))
            }
            .min { ($0.rank, RelayFlight.distance($0.landing.point, cue)) < ($1.rank, RelayFlight.distance($1.landing.point, cue)) }?.landing
        }
    }

    /// 窗口根上一个空视图：让舞台认得自己在哪个窗口，并取当下配色里的靛青。
    fileprivate struct Probe {
        let stage: Stage
        let color: Color

        func make() -> RelayAnchorView {
            let view = RelayAnchorView(role: .stage)
            stage.host = view
            return view
        }
    }
}

/// 发出（"对 Cue 说"的发送钮 → Cue 的头像）：钮上挂一个锚（`relayLaunch`），发出的那一刻量出机头与头像在窗口里的位置，
/// 交给 `RelayFlight.launch` 当场起飞（不等下一帧：钮在这一帧换成发送中，光要接上正飞走的机头）。头像落在哪处同接力（`CueSpot`）。
final class RelayLaunch {
    fileprivate weak var pad: RelayAnchorView?
    fileprivate var color: CGColor?

    /// 机头在钮心右上方多远（钮宽、钮高的比例）：对着录屏逐帧对准，光的第一帧正落在正飞走的机头上。
    private static let nose = CGSize(width: 0.2, height: 0.2)

    func fly(reduceMotion: Bool) {
        guard let pad, let window = pad.window, let root = RelayAnchorView.rootLayer(of: window), let color,
              let from = pad.frame(in: root) else { return }
        let cue = RelayAnchorView.cue(among: RelayAnchorView.all(in: window), in: root)
        let up: CGFloat = RelayFlight.up(in: root)
        let head = CGPoint(x: from.midX + from.width * Self.nose.width, y: from.midY + up * from.height * Self.nose.height)
        RelayFlight(color: color, reduceMotion: reduceMotion).launch(from: head, to: cue, in: root)
    }
}

extension View {
    /// 发出的起点：`launch.fly` 从这里起飞（颜色是此刻配色里的 `color`）。
    func relayLaunch(_ launch: RelayLaunch, color: Color) -> some View {
        background(RelayLaunchPad(launch: launch, color: color))
    }
}

private struct RelayLaunchPad {
    let launch: RelayLaunch
    let color: Color

    func make() -> RelayAnchorView {
        let view = RelayAnchorView(role: .launch)
        launch.pad = view
        return view
    }
}

struct RelayAnchor {
    let role: RelayAnchorView.Role
}

/// 锚：一个不接事件、不画东西的空视图，只为播的那一刻能沿层树量出它在窗口里的位置。
final class RelayAnchorView: RelayAnchorBase {
    enum Role: Equatable {
        case stage
        /// 发出的起点（`RelayLaunch`）。
        case launch
        case cue(CueSpot)
        case end(EndSpot)
    }

    var role: Role
    private static let anchors = NSHashTable<RelayAnchorView>.weakObjects()

    init(role: Role) {
        self.role = role
        super.init(frame: .zero)
        #if os(iOS)
        isUserInteractionEnabled = false
        #else
        wantsLayer = true
        #endif
        Self.anchors.add(self)
    }

    required init?(coder: NSCoder) { fatalError() }

    #if os(macOS)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    #endif

    static func all(in window: AnyObject) -> [RelayAnchorView] { anchors.allObjects.filter { $0.window === window } }

    /// Cue 那头在屏上的那块：几处都在时取 `CueSpot` 排在前面的。
    static func cue(among anchors: [RelayAnchorView], in root: CALayer) -> CGRect? {
        anchors.compactMap { anchor -> (spot: CueSpot, frame: CGRect)? in
            guard case .cue(let spot) = anchor.role, let frame = anchor.frame(in: root) else { return nil }
            return (spot, frame)
        }.min { $0.spot.rawValue < $1.spot.rawValue }?.frame
    }

    /// 窗口最底下那一层：Mac 是窗口外框的层（工具栏与内容都在它下面），iOS 是窗口的层。
    #if os(iOS)
    static func rootLayer(of window: UIWindow) -> CALayer? { window.layer }
    #else
    static func rootLayer(of window: NSWindow) -> CALayer? { window.contentView?.superview?.layer }
    #endif

    /// 在 `root` 里看得见的那块：沿层树往上换算，被裁掉、藏起或透明的祖先让它不算在屏上（`seesThrough` 时透明的不算）。
    func frame(in root: CALayer, seesThrough: Bool = false) -> CGRect? {
        #if os(iOS)
        var current = layer
        #else
        guard var current = layer else { return nil }
        #endif
        var rect = current.bounds
        while let parent = current.superlayer {
            guard !current.isHidden, seesThrough || current.opacity > 0.01 else { return nil }
            rect = current.convert(rect, to: parent)
            if parent.masksToBounds || parent === root { rect = rect.intersection(parent.bounds) }
            guard !rect.isEmpty else { return nil }
            if parent === root { return rect }
            current = parent
        }
        return nil
    }
}

#if os(iOS)

typealias RelayAnchorBase = UIView

extension RelayAnchor: UIViewRepresentable {
    func makeUIView(context: Context) -> RelayAnchorView { RelayAnchorView(role: role) }
    func updateUIView(_ view: RelayAnchorView, context: Context) { view.role = role }
}

extension CueRelayStage.Probe: UIViewRepresentable {
    func makeUIView(context: Context) -> RelayAnchorView { make() }
    func updateUIView(_ view: RelayAnchorView, context: Context) { stage.color = color.resolve(in: context.environment).cgColor }
}

extension RelayLaunchPad: UIViewRepresentable {
    func makeUIView(context: Context) -> RelayAnchorView { make() }
    func updateUIView(_ view: RelayAnchorView, context: Context) { launch.color = color.resolve(in: context.environment).cgColor }
}
#else

typealias RelayAnchorBase = NSView

extension RelayAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> RelayAnchorView { RelayAnchorView(role: role) }
    func updateNSView(_ view: RelayAnchorView, context: Context) { view.role = role }
}

extension CueRelayStage.Probe: NSViewRepresentable {
    func makeNSView(context: Context) -> RelayAnchorView { make() }
    func updateNSView(_ view: RelayAnchorView, context: Context) { stage.color = color.resolve(in: context.environment).cgColor }
}

extension RelayLaunchPad: NSViewRepresentable {
    func makeNSView(context: Context) -> RelayAnchorView { make() }
    func updateNSView(_ view: RelayAnchorView, context: Context) { launch.color = color.resolve(in: context.environment).cgColor }
}
#endif
