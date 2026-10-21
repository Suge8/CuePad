import CueStore
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
        private static func place(of end: RelayEnd, among anchors: [RelayAnchorView], in root: CALayer, near cue: CGPoint?) -> CGPoint? {
            anchors.compactMap { anchor -> (rank: Int, point: CGPoint)? in
                guard case .end(let spot) = anchor.role, let rank = spot.rank(for: end),
                      let frame = anchor.frame(in: root, seesThrough: end.opens && rank == EndSpot.Row.own.rawValue) else { return nil }
                return (rank, frame.center)
            }
            .min { ($0.rank, RelayFlight.distance($0.point, cue)) < ($1.rank, RelayFlight.distance($1.point, cue)) }?.point
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

/// 接力的一头：会话 id 与它的任务（请求带着的那张卡）；`opens` 是这次交给开出了这个会话（start）。
nonisolated struct RelayEnd: Equatable, Sendable {
    var session: String
    var task: UUID?
    var opens = false
}

/// Cue 那一头落在哪：同时在屏上几处时取排在前面的。三端的规则就是这个顺序——
/// Mac 与 iPad 有侧栏时总落在侧栏的 Cue 一行（在不在 Cue 页都一样），侧栏收起时退到 Cue 页页头；
/// iPhone 没有侧栏：在 Cue 页落在页头的头像（从底部往上飞一长段，最看得出），在三页上落在底部那一排的 Cue 钮。
enum CueSpot: Int {
    /// 侧栏最上面的 Cue（Mac 是名片 `CueSidebarCard`、iPad 是那一行，头像都是 `CueEntryAvatar`；菜单栏面板、输入条在别的窗口，不参与）。
    case entry
    /// Cue 页的页头。
    case header
    /// iPhone 三页底部那一排的 Cue 钮。
    case dock
}

/// 会话那一头落在哪：屏上有它的几处时取最具体的（`rank` 小的）。只有此刻在接力的珠子、会话与任务挂锚。
enum EndSpot: Equatable {
    /// Cue 那一行里代表这份活的珠子，一个珠子可对应几个会话。
    case bead([String])
    /// 会话的状态标，按它所在的那一行分级（`Row`）。
    case session(String, Row)
    /// 任务圈与正在开会话的空心点：带着这件任务、或交给的会话就是它绑着的那个时算。
    case task(UUID, session: String?)
    /// "会话"那一格：iPhone 展开的三格、Mac 侧栏的会话磁贴；Cue 页收起的去处钮不接力。
    case dock

    /// 状态标所在的行，越具体越前。
    enum Row: Int {
        /// 会话自己那一行：会话列表、菜单栏面板、会话页的页头卡片。
        case own = 1
        /// 它的任务行（任务行、任务卡、任务页上代表它的那一格）。
        case task
        /// 项目行上的状态：Mac 侧栏行尾的状态标、iPad 与手机的此刻一行（`ProjectNowLine`）。
        case project
    }

    /// 对 `end` 来说有多具体；不是它的为 nil。
    func rank(for end: RelayEnd) -> Int? {
        switch self {
        case .bead(let sessions): sessions.contains(end.session) ? 0 : nil
        case .session(let session, let row): session == end.session ? row.rawValue : nil
        case .task(let task, let session): task == end.task || session == end.session ? Row.task.rawValue : nil
        case .dock: Row.project.rawValue + 1
        }
    }
}

extension View {
    /// Cue 那一行里这份活的珠子：它对应的会话正在接力时才挂锚，优先于所有会话、任务与去处落点。
    func relaySpot(bead sessions: [String]) -> some View { modifier(BeadSpot(sessions: sessions)) }

    /// 会话的状态标：接力的会话那一头，`row` 是它在哪种行里。只有此刻在接力的会话挂锚，平时什么都不加。
    /// 这次交给刚开出这个会话时，状态标先透明着，光落下时才亮出来（同 `relayArrival`）。
    func relaySpot(session: String?, row: EndSpot.Row = .own) -> some View { modifier(SessionSpot(session: session, row: row)) }

    /// 任务行（任务圈、正在开会话的那个空心点）：任务交给的会话在接力、或这件任务就是接力带着的那件时，接力落在这里。
    func relaySpot(task: UUID) -> some View { modifier(TaskSpot(task: task)) }

    /// Cue 的头像：接力的 Cue 那一头，环在这里亮起。
    func relaySpot(cue spot: CueSpot) -> some View { background { RelayAnchor(role: .cue(spot)) } }

    /// "会话"那一格（`EndSpot.dock`，`dock` 为真的那处）：会话哪一行都不在屏上时接力落在这里。一直挂着。
    func relaySpot(dock: Bool) -> some View { background { if dock { RelayAnchor(role: .end(.dock)) } } }

    /// 会话自己那一行：这次交给刚开出这个会话时，行先占着位置、透明，光落下时淡出来（`Stage.arriving`）。
    func relayArrival(session: String) -> some View { modifier(Arrival(session: session)) }
}

extension EnvironmentValues {
    /// 本窗口的接力舞台（`CueRelayStage` 放进来，引用不变）；不在主窗口里的（菜单栏面板、输入条）没有。
    @Entry var relayStage: CueRelayStage.Stage?
}

/// 珠子与会话状态标只读 `LiveSessions.flight`，不在窗口根上改环境值，避免每次接力让整棵视图树重算。
private struct BeadSpot: ViewModifier {
    let sessions: [String]
    @Environment(Workspace.self) private var workspace

    func body(content: Content) -> some View {
        let flying = sessions.filter { workspace.services.liveSessions.relays(session: $0) }
        content.background {
            if !flying.isEmpty { RelayAnchor(role: .end(.bead(flying))).transition(.identity) }
        }
    }
}

private struct SessionSpot: ViewModifier {
    let session: String?
    let row: EndSpot.Row
    @Environment(Workspace.self) private var workspace

    func body(content: Content) -> some View {
        let flying = session.flatMap { workspace.services.liveSessions.relays(session: $0) ? $0 : nil }
        content.modifier(Arrival(session: session)).background {
            if let flying { RelayAnchor(role: .end(.session(flying, row))).transition(.identity) }
        }
    }
}

/// 任务交给的会话从窗口那一份里取（`cardAgents`，行本来就读它）：会话在接力、或这张卡就是接力的那件任务时挂锚。
private struct TaskSpot: ViewModifier {
    let task: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(\.cardAgents) private var agents

    func body(content: Content) -> some View {
        let live = workspace.services.liveSessions
        let session = agents.items[task]?.state.sessionID
        let flying = live.relays(task: task) || session.map(live.relays(session:)) == true
        content.background {
            if flying { RelayAnchor(role: .end(.task(task, session: session))).transition(.identity) }
        }
    }
}

/// 新开出的会话那一行或它的状态标：舞台说它还在等光（`Stage.arriving`）时透明，光落下那一刻淡出来；藏起来是当场的，不淡出。
private struct Arrival: ViewModifier {
    let session: String?
    @Environment(\.relayStage) private var stage

    func body(content: Content) -> some View {
        let waits = session.map { stage?.arriving.contains($0) == true } == true
        content
            .opacity(waits ? 0 : 1)
            .animation(waits ? nil : Motion.quick, value: waits)
    }
}

private struct RelayAnchor {
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

/// 一次接力的画（样子与时长见 `CueRelayStage`）：在窗口根层最上面铺一层画布，所有动画一次交给 Core Animation，全部播完画布拿掉。
/// 画布上每一层的模型值都是透明的：动画之前、之后都看不见，只在动画里出现。
struct RelayFlight {
    let color: CGColor
    let reduceMotion: Bool

    /// 一次最多飞几道。
    static let most = 3
    /// 相邻两道起飞的间隔。
    private static let stagger = 0.09
    /// 起飞那圈环外扩之后多久光离开状态标（叫醒）。
    private static let liftoff = 0.08
    /// 头像的环亮起之后多久小环离开头像（交给）：先看清是 Cue 发出的。
    private static let release = 0.16
    /// 飞着的那颗点（叫醒）与那个小环（交给）的直径。
    private static let head: CGFloat = 8
    private static let ring: CGFloat = 11
    /// 另一头不在屏上时光飘多远。
    private static let drift: CGFloat = 24
    /// 先加速、后长长地减速：落下时已经很慢。
    private static let glide = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.22, 1)
    private static let flight = 0.78...1.08
    private static let pointsPerSecond = 1800.0
    private static let bend: CGFloat = 48
    private static let mostBend: CGFloat = 160
    private static let arrival = 0.92
    private static let ripple = 0.14
    private static let depart = 0.58
    private static let reception = 0.82
    private static let avatar = 0.78
    private static let easeOut = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)

    static func distance(_ a: CGPoint, _ b: CGPoint?) -> CGFloat {
        guard let b else { return 0 }
        return hypot(a.x - b.x, a.y - b.y)
    }

    /// `cue` 是头像在屏上的那块，`ends` 是会话那头在屏上的几处（都可能不在）。交给的光落到第几处时调 `landed`（落点那圈环开始扩的那一刻）。
    func play(_ direction: CueFlight.Direction, cue: CGRect?, ends: [CGPoint], in root: CALayer, landed: @escaping (Int) -> Void) {
        guard !ends.isEmpty || cue != nil else { return }
        stage(in: root) { scene in
            if reduceMotion {
                if let cue { scene.glow(ring: cue) }
                for end in ends { scene.glow(dot: end) }
                ends.indices.forEach(landed)
            } else {
                switch direction {
                case .wake: wake(scene, from: ends, to: cue)
                case .relay: relay(scene, from: cue, to: ends, landed: landed)
                }
            }
        }
    }

    /// 发出（输入框的发送钮 → Cue 的头像）：钮上纸飞机的机头就是那点光，从机头处（`head`，根层坐标）当场起飞——满大、不透明，
    /// 不在钮上外扩起飞环、也不从半大淡入：钮在这一刻换成发送中，起飞环与淡入的光叠在正飞走的飞机上，录屏里是一团糊。
    /// 落进头像同叫醒；头像不在屏上时往上飘一小段淡去。减弱动态效果：只有头像的环淡亮一下（起点的钮自己已换成发送中，不再压一层光）。
    func launch(from head: CGPoint, to cue: CGRect?, in root: CALayer) {
        stage(in: root) { scene in
            if reduceMotion {
                if let cue { scene.glow(ring: cue) }
            } else if let cue {
                let duration = scene.fly(from: head, to: cue.center, head: .dot, delay: 0, launches: true)
                scene.land(on: cue, delay: duration * Self.arrival)
            } else {
                scene.drift(from: head, rise: scene.up * Self.drift, head: .dot, delay: 0, launches: true)
            }
        }
    }

    /// 在窗口根层最上面铺一层画布交给 `draw` 画，所有动画一次提交给 Core Animation，播完画布拿掉。
    private func stage(in root: CALayer, _ draw: (Scene) -> Void) {
        let canvas = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { canvas.removeFromSuperlayer() }
        canvas.frame = root.bounds
        canvas.zPosition = 10_000
        root.addSublayer(canvas)
        draw(Scene(canvas: canvas, color: color, now: canvas.convertTime(CACurrentMediaTime(), from: nil), up: Self.up(in: root)))
        CATransaction.commit()
    }

    private func wake(_ scene: Scene, from sources: [CGPoint], to target: CGRect?) {
        for (index, source) in sources.enumerated() {
            let start = Double(index) * Self.stagger
            scene.depart(at: source, delay: start)
            if let target {
                let duration = scene.fly(from: source, to: target.center, head: .dot, delay: start + Self.liftoff)
                // 光还差最后一点到时环就亮：落点与亮起连成一下
                scene.land(on: target, delay: start + Self.liftoff + duration * Self.arrival)
            } else {
                scene.drift(from: source, rise: scene.up * Self.drift, head: .dot, delay: start + Self.liftoff)
            }
        }
        if sources.isEmpty, let target { scene.land(on: target, delay: 0) }
    }

    private func relay(_ scene: Scene, from source: CGRect?, to targets: [CGPoint], landed: @escaping (Int) -> Void) {
        guard let source else {
            for (index, target) in targets.enumerated() {
                scene.depart(at: target, delay: Double(index) * Self.stagger, fills: true) { landed(index) }
            }
            return
        }
        scene.send(from: source)
        for (index, target) in targets.enumerated() {
            let start = Self.release + Double(index) * Self.stagger
            let duration = scene.fly(from: source.center, to: target, head: .ring, delay: start)
            scene.depart(at: target, delay: start + duration * Self.arrival, fills: true) { landed(index) }
        }
        // 会话不在屏上：从头像朝窗口中间那侧的边上飘出一段（从页头往下、从窗口下沿的头像往上）——从脸的中心起飘，还没出头像就淡了
        if targets.isEmpty {
            let inward: CGFloat = scene.canvas.bounds.midY > source.midY ? 1 : -1
            let edge = CGPoint(x: source.midX, y: source.midY + inward * source.height / 2)
            scene.drift(from: edge, rise: inward * Self.drift * 1.5, head: .ring, delay: Self.release)
        }
    }

    /// 屏幕上的"上"在这层坐标里是 y 的哪个方向（iOS 的层 y 朝下；Mac 的层默认 y 朝上）。
    static func up(in root: CALayer) -> CGFloat {
        #if os(iOS)
        -1
        #else
        root.contentsAreFlipped() ? -1 : 1
        #endif
    }

    /// 飞的是什么：会话的状态标（实心点）或 Cue 的环（空心小环）。
    private enum Head { case dot, ring }

    private struct Scene {
        let canvas: CALayer
        let color: CGColor
        let now: CFTimeInterval
        let up: CGFloat

        /// 起飞时只漾一圈；接住时珠心先亮、停住，再随外圈淡下去。只叠画光，不改珠子本身的视图与布局。
        func depart(at point: CGPoint, delay: Double, fills: Bool = false, started: (@MainActor () -> Void)? = nil) {
            animate(circle(at: point, radius: 6, line: 1.5, glows: true), delay: delay, duration: RelayFlight.depart,
                    timing: RelayFlight.easeOut, started: started, [
                        Self.keyframes("transform.scale", [0.8, 2.6]), Self.keyframes("opacity", [1, 0]),
                    ])
            if fills {
                animate(circle(at: point, radius: 4, fill: 0.95, glows: true), delay: delay, duration: RelayFlight.reception, [
                    Self.keyframes("opacity", [0, 1, 1, 0], times: [0, 0.1, 0.42, 1]),
                    Self.keyframes("transform.scale", [0.9, 1.25, 1, 1], times: [0, 0.18, 0.42, 1]),
                ])
                animate(circle(at: point, radius: 11, fill: 0.18), delay: delay, duration: RelayFlight.reception, [Self.hold()])
            }
        }

        /// 沿弧飞到 `end`，返回飞了多久。弧向窗口的竖中线那边鼓：从侧栏、屏边起飞时弧在屏内；几乎横着飞时往上鼓。
        func fly(from start: CGPoint, to end: CGPoint, head: Head, delay: Double, launches: Bool = false) -> Double {
            let length = RelayFlight.distance(start, end)
            let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            var normal = CGPoint(x: -(end.y - start.y) / max(length, 1), y: (end.x - start.x) / max(length, 1))
            let outward = abs(normal.x) < 0.2 ? normal.y * up < 0 : normal.x * (canvas.bounds.midX - mid.x) < 0
            if outward { normal = CGPoint(x: -normal.x, y: -normal.y) }
            let bend = min(max(length * 0.32, RelayFlight.bend), RelayFlight.mostBend)
            let path = CGMutablePath()
            path.move(to: start)
            path.addQuadCurve(to: end, control: CGPoint(x: mid.x + normal.x * bend, y: mid.y + normal.y * bend))
            let duration = min(RelayFlight.flight.lowerBound + Double(length) / RelayFlight.pointsPerSecond, RelayFlight.flight.upperBound)
            streak(path, head: head, delay: delay, duration: duration, timing: RelayFlight.glide, launches: launches)
            return duration
        }

        /// 另一头不在屏上：从 `start` 沿 `rise`（层坐标里的竖直位移）飘一小段淡去。
        func drift(from start: CGPoint, rise: CGFloat, head: Head, delay: Double, launches: Bool = false) {
            let path = CGMutablePath()
            path.move(to: start)
            path.addQuadCurve(to: CGPoint(x: start.x + 6, y: start.y + rise), control: CGPoint(x: start.x, y: start.y + rise * 0.6))
            streak(path, head: head, delay: delay, duration: 0.55, timing: RelayFlight.easeOut, fades: true, launches: launches)
        }

        /// 一道光加它的尾巴：尾巴是同一条弧上的描边，终点跟着光走、起点晚一点出发、到终点时追上——尾巴越飞越短，落下时被收进去。
        /// 三层叠出由亮到暗的尾巴：短而亮的芯、长而淡的身子、宽而很淡的光晕（描边上不能铺沿着弧走的渐变）。
        /// `launches`：光是从钮上的机头变来的，第一帧就满大、不透明（不从半大淡入）。
        private func streak(_ path: CGPath, head: Head, delay: Double, duration: Double, timing: CAMediaTimingFunction, fades: Bool = false, launches: Bool = false) {
            for (width, alpha, lag) in [(CGFloat(10), 0.12, 0.36), (4, 0.36, 0.25), (1.8, 0.95, 0.16)] {
                let trail = CAShapeLayer()
                // 描边只占轨迹的包围盒，不让三层拖尾都保持整窗大小的合成边界。
                let bounds = path.boundingBoxOfPath.insetBy(dx: -width, dy: -width)
                trail.frame = bounds
                var local = CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
                trail.path = path.copy(using: &local)
                trail.fillColor = nil
                trail.strokeColor = color
                trail.lineWidth = width
                trail.lineCap = .round
                trail.opacity = 0
                canvas.addSublayer(trail)
                animate(trail, delay: delay, duration: duration, timing: timing, [
                    Self.keyframes("strokeEnd", [0, 1]),
                    Self.keyframes("strokeStart", [0, 0, 1], times: [0, NSNumber(value: lag), 1]),
                    Self.keyframes("opacity", [alpha, alpha, 0], times: [0, fades ? 0.4 : 0.75, 1]),
                ])
            }
            let dot = self.head(head)
            let move = CAKeyframeAnimation(keyPath: "position")
            move.path = path
            move.calculationMode = .paced
            animate(dot, delay: delay, duration: duration, timing: timing, [
                move,
                Self.keyframes("transform.scale", [launches ? 1 : 0.5, 1.15, 1, fades ? 0.6 : 0.4], times: [0, 0.2, 0.85, 1]),
                Self.keyframes("opacity", [launches ? 1 : 0, 1, 1, 0], times: [0, 0.12, fades ? 0.5 : 0.88, 1]),
            ])
        }

        /// 飞着的那颗：实心点或空心小环，外带一圈同色光晕（形状给定，不让渲染服务每帧从内容里另算）。
        private func head(_ head: Head) -> CALayer {
            let layer: CALayer
            switch head {
            case .dot:
                let side = RelayFlight.head
                layer = CALayer()
                layer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
                layer.cornerRadius = side / 2
                layer.backgroundColor = color
                layer.shadowPath = CGPath(ellipseIn: layer.bounds, transform: nil)
                layer.shadowRadius = side * 0.8
            case .ring:
                let side = RelayFlight.ring, line: CGFloat = 2
                let shape = CAShapeLayer()
                shape.bounds = CGRect(x: 0, y: 0, width: side, height: side)
                let path = CGPath(ellipseIn: shape.bounds.insetBy(dx: line / 2, dy: line / 2), transform: nil)
                shape.path = path
                shape.fillColor = nil
                shape.strokeColor = color
                shape.lineWidth = line
                shape.shadowPath = path.copy(strokingWithWidth: line, lineCap: .round, lineJoin: .round, miterLimit: 0)
                shape.shadowRadius = side * 0.5
                layer = shape
            }
            layer.shadowColor = color
            layer.shadowOpacity = 1
            layer.shadowOffset = .zero
            layer.opacity = 0
            canvas.addSublayer(layer)
            return layer
        }

        /// 叫醒落下：头像的环亮起（带一圈光晕），停一下再外扩到 1.6 倍淡去；稍后一圈细的涟漪扩得更远。不盖住它的脸。
        func land(on target: CGRect, delay: Double) {
            let (radius, line) = Self.ring(of: target)
            animate(circle(at: target.center, radius: radius, line: line, glows: true), delay: delay, duration: RelayFlight.avatar, [
                Self.keyframes("opacity", [0, 1, 1, 0], times: [0, 0.12, 0.3, 1], timing: RelayFlight.easeOut),
                Self.keyframes("transform.scale", [1, 1, 1, 1.6], times: [0, 0.12, 0.3, 1], timing: RelayFlight.easeOut),
            ])
            animate(circle(at: target.center, radius: radius, line: max(1, line / 2)), delay: delay + RelayFlight.ripple, duration: RelayFlight.avatar, timing: RelayFlight.easeOut, [
                Self.keyframes("opacity", [0.7, 0]), Self.keyframes("transform.scale", [1, 2.1]),
            ])
        }

        /// 交给发出：头像的环亮一下（带光晕），外扩到 1.25 倍淡去；比叫醒落下的那一下短、扩得近——发出是一拍，接住才漾开。
        func send(from source: CGRect) {
            let (radius, line) = Self.ring(of: source)
            animate(circle(at: source.center, radius: radius, line: line, glows: true), delay: 0, duration: 0.6, [
                Self.keyframes("opacity", [0, 1, 1, 0], times: [0, 0.15, 0.35, 1], timing: RelayFlight.easeOut),
                Self.keyframes("transform.scale", [1, 1, 1, 1.25], times: [0, 0.15, 0.35, 1], timing: RelayFlight.easeOut),
            ])
        }

        /// 减弱动态效果：头像的环原地淡入高亮再淡出。
        func glow(ring target: CGRect) {
            let (radius, line) = Self.ring(of: target)
            animate(circle(at: target.center, radius: radius, line: line, glows: true), delay: 0, duration: 1, [Self.hold()])
        }

        /// 减弱动态效果：会话那头的状态标垫一层淡光，与头像同时亮、同时暗。
        func glow(dot point: CGPoint) {
            animate(circle(at: point, radius: 9, fill: 0.3), delay: 0, duration: 1, [Self.hold()])
        }

        private static func hold() -> CAAnimation {
            keyframes("opacity", [0, 1, 1, 0], times: [0, 0.2, 0.55, 1], timing: CAMediaTimingFunction(name: .easeInEaseOut))
        }

        /// 头像外那圈环的半径与线宽（`CueAvatar`：环宽约是外框的 7%）。
        private static func ring(of target: CGRect) -> (radius: CGFloat, line: CGFloat) {
            let side = min(target.width, target.height)
            let line = max(1.5, side * 0.07)
            return (side / 2 - line / 2, line)
        }

        /// 以 `point` 为心的一个圆：给了线宽是描边（`glows` 时描边外带一圈同色的光晕），否则按 `fill` 的透明度填色。
        private func circle(at point: CGPoint, radius: CGFloat, line: CGFloat? = nil, fill: CGFloat = 0, glows: Bool = false) -> CAShapeLayer {
            let shape = CAShapeLayer()
            shape.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
            shape.position = point
            shape.path = CGPath(ellipseIn: shape.bounds, transform: nil)
            if let line {
                shape.fillColor = nil
                shape.strokeColor = color
                shape.lineWidth = line
            } else {
                shape.fillColor = color.copy(alpha: color.alpha * fill)
            }
            if glows, let path = shape.path {
                shape.shadowPath = line.map { path.copy(strokingWithWidth: $0, lineCap: .round, lineJoin: .round, miterLimit: 0) } ?? path
                shape.shadowColor = color
                shape.shadowOpacity = 0.9
                shape.shadowRadius = max(4, (line ?? radius) * 1.6)
                shape.shadowOffset = .zero
            }
            shape.opacity = 0
            canvas.addSublayer(shape)
            return shape
        }

        /// 一组动画在 `delay` 之后开始；之前之后都是层的模型值（透明）。不往前填（`fillMode` 留默认）：往前填时晚开始的那几层
        /// 在开始前就停在第一帧上——落下时才该外扩的环、稍晚的涟漪会在光还没到时就亮着。
        private func animate(
            _ layer: CALayer, delay: Double, duration: Double, timing: CAMediaTimingFunction? = nil, started: (@MainActor () -> Void)? = nil,
            _ animations: [CAAnimation]
        ) {
            let group = CAAnimationGroup()
            group.animations = animations
            group.duration = duration
            group.beginTime = now + delay
            group.timingFunction = timing
            group.delegate = started.map(Started.init)
            layer.add(group, forKey: nil)
        }

        private static func keyframes(_ key: String, _ values: [Double], times: [NSNumber]? = nil, timing: CAMediaTimingFunction? = nil) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: key)
            animation.values = values
            animation.keyTimes = times
            if let timing { animation.timingFunctions = Array(repeating: timing, count: values.count - 1) }
            return animation
        }
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

/// 动画真的开始（过了 `beginTime`、渲染服务开播）时回调一次：落点那圈环的开始就是光落下的那一刻。
private final class Started: NSObject, CAAnimationDelegate {
    private let run: @MainActor () -> Void

    init(_ run: @escaping @MainActor () -> Void) { self.run = run }

    nonisolated func animationDidStart(_ animation: CAAnimation) { MainActor.assumeIsolated { run() } }
}
