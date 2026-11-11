import QuartzCore
import SwiftUI

/// 接力的光沿弧交棒，两端同一套尺寸、曲线与时长；全 App 唯一不走 `Motion` 几种 token 的长编排，给低频的交棒留出看清两头的时间。
/// 叫醒（会话 → Cue）：光头到点的那一刻那颗点亮起来，头像这时才醒（光在路上时各处的头像停在起飞那一刻的样子，`CueWatch.beat`），先醒后到读成因果反了。
/// 这次叫醒的时间线归 `CueWatch.wake`，这里照它画、不回报。不在头像外画环：头像外的环是否决过的"加载进度"。
/// 开新会话（start）不在写下请求时飞，等开出的会话有了记录（`CueFlight.Handed`）才飞；新行先占好位置、透明着，光落下的那一刻（落点那圈环的动画真的开始时，Core Animation 回调）才淡出来（`relayArrival`、`Stage.arriving`）。
/// 降级（两个方向同一条规则）：没有一个看得见的东西就不凭空画，也不往屏外飞；两头都不在就什么都不画。同步追赶中（`AppServices.isCatchingUp`）带回来的不播：那是不在眼前时发生过的事。
/// 接力只来自库里的事实，只在变了时才写（打开资料库时已有的不算）；它与在做那一列同一份读到，重排那一列的写入与这次接力在同一次更新里到达，等一帧排好就量（`NextFrame`），不猜时长。页面换来换去也不播（挂在窗口根上，不随页面出现）。
/// 性能：飞行整个交给 Core Animation（渲染服务插值，App 进程不逐帧参与）。不在每一行挂几何读数：只有此刻在接力的会话状态标与任务行挂一个空的锚视图；
/// 空锚不做插入转场：继承到父级动画时，默认淡入会让新锚的宿主层首帧透明，把本来可见的落点误判成不在屏上。
/// 接住的那几圈挂在落点的锚自己的层上（`RelayFlight.Landing`）：量过之后落点又挪了（页头随换句重新居中、列表重排）圈也跟着锚走，且压在锚后面的字底下。
/// 否决了 SwiftUI 的覆盖层加锚点偏好：偏好过不了 Mac 工具栏与 iOS 导航容器的托管边界，覆盖层也盖不住 Mac 的工具栏。
struct CueRelayStage: ViewModifier {
    let workspace: Workspace

    @State private var stage = Stage()

    // 窗口根上只放一个不变的引用：接力只在背景里那个小视图里看（`Watcher`），Cue 的现状怎么变根都不重算
    func body(content: Content) -> some View {
        content.environment(\.relayStage, stage).background(Watcher(workspace: workspace, stage: stage))
    }

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
                .onChange(of: workspace.cue.wake) { _, wake in
                    guard let wake else { return }
                    let flight = CueFlight(direction: .wake, at: wake.at, ends: wake.sessions.map { RelayEnd(session: $0) })
                    stage.play(flight, since: wake.seen, reduceMotion: reduceMotion)
                }
        }
    }

    @Observable
    final class Stage {
        private(set) var arriving: Set<String> = []
        @ObservationIgnored fileprivate weak var host: RelayAnchorView?
        @ObservationIgnored fileprivate var color: CGColor?
        @ObservationIgnored private var flightID = UUID()
        @ObservationIgnored private var playback: Task<Void, Never>?
        @ObservationIgnored private let rails = NSHashTable<SessionRailReveal>.weakObjects()

        func register(_ rail: SessionRailReveal) { rails.add(rail) }

        /// `since`：这次接力的起点（叫醒是 `CueWatch.Wake.seen`），光照它排时刻，晚到的从中途画起；交给从此刻起。
        func play(_ flight: CueFlight, since: Date = .now, reduceMotion: Bool) {
            // 与新会话那一行同一次更新里就藏起来，不先露一帧
            let id = UUID()
            flightID = id
            arriving = Set(flight.ends.filter(\.opens).map(\.session))
            playback?.cancel()
            let readyRails = rails.allObjects.filter(\.canReveal)
            playback = Task {
                if flight.direction == .relay {
                    // 会话条与 flight 来自同一快照；先让新格挂载，再滚入，最后量锚。缺席目标不等待。
                    await NextFrame.drawn()
                    guard !Task.isCancelled else { return }
                    for rail in readyRails { rail.prepare(flight.ends) }
                }
                // 在接力的那几处这一刻才挂上锚：等这一次更新排好、提交了再量
                await NextFrame.drawn()
                guard !Task.isCancelled, self.flightID == id else { return }
                guard let window = host?.window, let root = RelayAnchorView.rootLayer(of: window), let color else {
                    arriving = []
                    return
                }
                let anchors = RelayAnchorView.all(in: window)
                let cue = RelayAnchorView.cue(among: anchors, in: root)
                let placed = Array(
                    flight.ends.compactMap { end in Self.place(of: end, among: anchors, in: root, near: cue?.center).map { (end.session, $0) } }
                        .prefix(RelayFlight.most))
                arriving.formIntersection(placed.map(\.0))
                RelayFlight(color: color, reduceMotion: reduceMotion).play(
                    flight.direction, cue: cue, ends: placed.map(\.1), in: root, since: flight.direction == .relay ? .now : since) { index in
                        if self.flightID == id { self.arriving.remove(placed[index].0) }
                    }
            }
        }

        /// 刚开出的会话那一行正透明着等光落下（`relayArrival`），量它时不看透明度。
        private static func place(of end: RelayEnd, among anchors: [RelayAnchorView], in root: CALayer, near cue: CGPoint?) -> RelayFlight.Landing? {
            anchors.compactMap { anchor -> (rank: Int, landing: RelayFlight.Landing)? in
                guard case .end(let spot) = anchor.role, let rank = spot.rank(for: end),
                      let frame = anchor.frame(in: root, seesThrough: end.opens && rank <= EndSpot.Row.own.rawValue) else { return nil }
                return (rank, RelayFlight.Landing(point: frame.center, host: anchor.layer))
            }
            .min { ($0.rank, RelayFlight.distance($0.landing.point, cue)) < ($1.rank, RelayFlight.distance($1.landing.point, cue)) }?.landing
        }
    }

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

    /// 只画光；头像什么时候露"在听"由 `CueWatch.sent` 按同一个到点时刻推出。
    func fly(since: Date, reduceMotion: Bool) {
        guard let pad, let window = pad.window, let root = RelayAnchorView.rootLayer(of: window), let color,
              let from = pad.frame(in: root) else { return }
        let cue = RelayAnchorView.cue(among: RelayAnchorView.all(in: window), in: root)
        let up: CGFloat = RelayFlight.up(in: root)
        let head = CGPoint(x: from.midX + from.width * Self.nose.width, y: from.midY + up * from.height * Self.nose.height)
        RelayFlight(color: color, reduceMotion: reduceMotion).launch(from: head, to: cue, in: root, since: since)
    }
}

extension View {
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

final class RelayAnchorView: RelayAnchorBase {
    enum Role: Equatable {
        case stage
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
