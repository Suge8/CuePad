import CueStore
import SwiftUI

/// Pi 会话状态的颜色与文字：要你注意的用状态色（等你确认赭黄、出错胭脂），工作中是签名色朱砂，空闲与已结束是灰，再靠形状分开。
/// 空闲叫"待你回复"：Pi 做完这一轮、在等你的下一句；与弹窗问题的"等你确认"是两回事。做完了你还没看的另有"有新回复"（`PiShown`）。
nonisolated extension PiWorkState {
    var label: String {
        switch self {
        case .thinking: "思考中"
        case .outputting: "输出中"
        case .tool: "运行工具"
        case .delegating: "子代理工作中"
        case .waitingForUser: "等你确认"
        case .settled: "待你回复"
        case .error: "出错"
        case .ended: "已结束"
        }
    }

    /// 会话列表的先后：等你确认 → 出错 → 工作中 → 空闲 → 已结束。
    var listRank: Int {
        switch self {
        case .waitingForUser: 0
        case .error: 1
        case .thinking, .outputting, .tool, .delegating: 2
        case .settled: 3
        case .ended: 4
        }
    }

    /// 同一项目有多个会话时，状态点显示最需要注意的那个。
    var urgency: Int {
        switch self {
        case .waitingForUser: 4
        case .error: 3
        case .thinking, .outputting, .tool, .delegating: 2
        case .settled: 1
        case .ended: 0
        }
    }
}

/// 子代理的粗状态借会话状态的图标、颜色与文字（工作中朱砂圈点、等你确认赭黄、空闲灰勾、出错胭脂叹号）。
nonisolated extension PiSubagentState {
    var workState: Open<PiWorkState> {
        switch activity.known {
        case .working: .known(.thinking)
        case .waitingForUser: .known(.waitingForUser)
        case .idle: .known(.settled)
        case .error: .known(.error)
        case nil: .unknown(activity.rawValue)
        }
    }

    var activityLabel: String {
        switch activity.known {
        case .working: "工作中"
        case .idle: "空闲"
        default: workState.label
        }
    }
}

/// 其他版本写入的、本版本不认识的状态：灰色、最低优先。
nonisolated extension Open<PiWorkState> {
    var label: String { known?.label ?? "未知状态" }
    var urgency: Int { known?.urgency ?? 1 }
    var listRank: Int { known?.listRank ?? 3 }

    /// 项目旁的状态点说的是什么（读屏标签、悬停提示、长按菜单的标题）：只分要你注意的与在忙的。
    var presence: String {
        switch known {
        case .thinking, .outputting, .tool, .delegating: "Agent 正在工作"
        case .waitingForUser: "Agent 等你确认"
        case .error: "Agent 出错"
        case .settled: "Agent 待你回复"
        case .ended: "Agent 会话已结束"
        case nil: "Agent 状态未知"
        }
    }
}

extension PiWorkState {
    func tint(_ palette: Palette) -> Color {
        switch self {
        case .thinking, .outputting, .tool, .delegating: palette.working
        case .waitingForUser: palette.attention
        case .error: palette.failure
        case .settled: palette.ink3
        case .ended: palette.ink3.opacity(0.6)
        }
    }

    /// 状态标的形状，与颜色一起表达状态（色弱也分得出）：等你确认问号、出错叹号、工作中圈里一个实心点、空闲勾、已结束空心圈。
    var symbol: String {
        switch self {
        case .waitingForUser: "questionmark.circle.fill"
        case .error: "exclamationmark.circle.fill"
        case .thinking, .outputting, .tool, .delegating: "smallcircle.filled.circle"
        case .settled: "checkmark.circle"
        case .ended: "circle"
        }
    }
}

extension Open<PiWorkState> {
    func tint(_ palette: Palette) -> Color { known?.tint(palette) ?? palette.ink3 }
}

nonisolated extension PiSessionState {
    /// 会话列表的顺序（Agent 页、Mac 侧栏）：要你注意的在前，同一档保持原来的先后（最近进入当前状态的在前）。
    /// `deliveries` 是发给各会话（按 Pi 的会话 id）的最近一条投送请求：话在路上的与工作中同档，发出那一刻就挪到位，
    /// 之后会话进入处理中不再挪；没能送达与出错同档。
    static func inListOrder(_ sessions: [PiSessionState], deliveries: [String: DeliveryRequest] = [:]) -> [PiSessionState] {
        func rank(_ session: PiSessionState) -> Int {
            switch PiDelivery.phase(of: deliveries[session.sessionID], for: session) {
            case .failed: PiWorkState.error.listRank
            case .some: PiWorkState.thinking.listRank
            case nil: session.state.listRank
            }
        }
        return sessions.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    /// 详情是工具命令（等宽显示）。
    var detailIsCode: Bool { state == .known(.tool) }

    /// 在处理中（思考、输出、运行工具、子代理）。
    var isWorking: Bool { state.isWorking }
}

nonisolated extension PiSessionListItem {
    /// 每个项目最需要注意的会话状态（书架与侧栏的状态点）：没能送达与等你确认、出错 → 有新回复 → 工作中与发送中 → 待你回复。
    static func byProject(_ items: [PiSessionListItem], shown: (PiSessionListItem) -> PiShown) -> [UUID: PiShown] {
        var result: [UUID: PiShown] = [:]
        for item in items {
            guard let project = item.state.projectID else { continue }
            let shown = shown(item)
            if (result[project]?.urgency ?? -1) < shown.urgency { result[project] = shown }
        }
        return result
    }
}

/// 发给会话、还没被它的状态吸收的那条投送请求此刻在哪一步。会话状态只来自 Mac 同步回来的记录，发出后要等 Mac 执行、写回、
/// 再同步过来才变；投送请求是本机当场写出的，所以显示状态把它算进去：发出即"发送中"，会话进入处理中后让位给会话状态。
nonisolated enum PiDelivery: Equatable, Sendable {
    /// 写出了，Mac 还没接手。
    case sending
    /// Mac 正在送达。
    case delivering
    /// 发给已结束的会话：Mac 先在后台唤醒它。
    case waking
    /// 送到了，会话状态还没跟上。
    case delivered
    case failed

    /// `request` 是发给 `session` 的最近一条（`DeliveryMode.toSession` 的方式）。会话状态的时间（`stateSince`）与送达时间
    /// （`completedAt`）都是 Mac 的钟；发出时间是发起设备的钟，只拿来判断"发出之后会话动起来了"，跨设备的钟差最多让"发送中"早一点让位。
    /// 完成的请求过一会儿就被执行它的 Mac 清理，所以"已送达""没能送达"不会一直挂着。
    static func phase(of request: DeliveryRequest?, for session: PiSessionState) -> PiDelivery? {
        guard let request, let mode = request.mode.known, DeliveryMode.toSession.contains(mode) else { return nil }
        let ended = session.state == .known(.ended)
        switch request.status.known {
        case .pending, .executing:
            if session.isWorking && session.stateSince >= request.createdAt { return nil }
            if ended { return .waking }
            return request.status == .known(.pending) ? .sending : .delivering
        case .succeeded:
            // 放进输入框不会让 Pi 动起来；其余等会话状态跟上（进入处理中，或在送达之后变过）就让位
            let caughtUp = session.isWorking || session.stateSince > (request.completedAt ?? request.createdAt)
            return mode == .paste || caughtUp ? nil : .delivered
        case .failed:
            // "之后变过"取严格晚于：时间存到毫秒，会话状态与结果同一毫秒写下是常事，同刻算作没变，结果照样显示
            return session.stateSince > (request.completedAt ?? request.modifiedAt) ? nil : .failed
        case nil:
            return nil
        }
    }

    var label: String {
        switch self {
        case .sending: "发送中"
        case .delivering: "送达中"
        case .waking: "正在唤醒"
        case .delivered: "已送达"
        case .failed: "没能送达"
        }
    }

    var presence: String {
        switch self {
        case .sending, .delivering, .delivered: "正在发给 Agent"
        case .waking: "正在唤醒 Agent"
        case .failed: "没能送达 Agent"
        }
    }
}

/// 做完了但你还没看：Pi 停在空闲（这一轮做完了），且停下的时间晚于本机最后一次看这个会话；
/// 没看过的从 `since`（启用这条规则的时刻）起算，之前就停下的不算。看的时刻记在本机偏好（`AppSettings.markSeen`）。
nonisolated enum PiUnread {
    static func isUnread(_ session: PiSessionState, seen: Date?, since: Date) -> Bool {
        session.state == .known(.settled) && session.stateSince > max(seen ?? since, since)
    }
}

extension AppSettings {
    /// 这个会话在本机界面上显示的状态；`delivery` 是发给它的最近一条投送请求（`PiSessionListItem.delivery`）。
    func shown(_ session: PiSessionState, delivery: DeliveryRequest?) -> PiShown {
        PiShown(state: session.state, unread: isUnread(session), delivery: PiDelivery.phase(of: delivery, for: session))
    }

    func shown(_ item: PiSessionListItem) -> PiShown { shown(item.state, delivery: item.delivery) }
}

/// 界面上一个会话（或一个项目）显示的状态：Pi 报的状态，停在空闲时再分你看没看过（`PiUnread`），发给它的话还在路上时
/// 先说路上到哪了（`PiDelivery`）。有新回复：墨色实心点、"有新回复"、名字加粗；看过是灰勾"待你回复"。
/// 全 App 的会话行、项目状态点、会话页顶栏、Mac 侧栏都经它。
nonisolated struct PiShown: Equatable, Sendable {
    var state: Open<PiWorkState>
    var unread = false
    var delivery: PiDelivery?

    var label: String { delivery?.label ?? (unread ? "有新回复" : state.label) }
    var presence: String { delivery?.presence ?? (unread ? "Agent 有新回复" : state.presence) }
    /// 有新回复排在出错之后、工作中之前；没能送达与出错同级，路上的与工作中同级。
    var urgency: Int {
        switch delivery {
        case .failed: PiWorkState.error.urgency * 2
        case .some: PiWorkState.thinking.urgency * 2
        case nil: state.urgency * 2 + (unread ? 3 : 0)
        }
    }
}

extension PiShown {
    func tint(_ palette: Palette) -> Color {
        switch delivery {
        case .failed: palette.failure
        case .some: palette.working
        case nil: unread ? palette.ink : state.tint(palette)
        }
    }

    /// 状态标的形状：路上的是向上的箭头，没能送达同出错的叹号，其余按会话状态。
    var symbol: String {
        switch delivery {
        case .failed: PiWorkState.error.symbol
        case .some: "arrow.up.circle"
        case nil: state.known?.symbol ?? "circle.dashed"
        }
    }
}

/// 会话状态标（全 App 只此一份：Agent 页、近况、书架、侧栏、Mac 侧栏与菜单栏）：颜色 + 形状表达状态——
/// 等你确认赭黄问号、出错胭脂叹号、工作中朱砂圈点、有新回复墨色实心点、待你回复灰勾、已结束更淡的空心圈、话在路上朱砂向上箭头、
/// 没能送达胭脂叹号。`size` 是点的直径，符号按它放大到同样的视觉分量。
/// 工作中（与话在路上）的标在呼吸——全 App 唯一常驻的循环动效：只动缩放与透明度，标不在屏幕上时随视图一起停；
/// 一轮做完（工作中 → 停下）时放一圈朱砂涟漪、点弹一下，只这一次。减弱动态效果时都不做。
/// 旁边有状态文字时读屏跳过它；`announces` 用在只有一个标的地方（书架、侧栏的项目旁），标自己带读屏标签与悬停提示。
struct PiStateDot: View {
    let shown: PiShown
    var size: CGFloat = 8
    var announces = false
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 跟着旁边的字随辅助字号放大
    @ScaledMetric private var scale: CGFloat = 1
    /// 每做完一轮加一：放一次涟漪。
    @State private var finished = 0

    private var box: CGFloat { size * 1.8 * scale }

    init(state: Open<PiWorkState>, unread: Bool = false, size: CGFloat = 8, announces: Bool = false) {
        self.init(shown: PiShown(state: state, unread: unread), size: size, announces: announces)
    }

    init(shown: PiShown, size: CGFloat = 8, announces: Bool = false) {
        self.shown = shown
        self.size = size
        self.announces = announces
    }

    /// 在工作或话在路上：身后呼吸。
    private var live: Bool {
        switch shown.delivery {
        case .failed: false
        case .some: true
        case nil: shown.state.known?.isWorking == true
        }
    }

    var body: some View {
        let tint = shown.tint(palette)
        let mark = Group {
            if shown.unread && shown.delivery == nil {
                Circle().frame(width: size * scale, height: size * scale)
            } else {
                Image(systemName: shown.symbol).font(.system(size: box, weight: .semibold))
            }
        }
        .foregroundStyle(tint)
        .frame(width: box, height: box)
        .background { if live && !reduceMotion { Halo(color: tint) } }
        .keyframeAnimator(initialValue: Ripple(), trigger: finished) { content, ripple in
            content
                .scaleEffect(ripple.pop)
                .background { Circle().stroke(palette.working, lineWidth: 1.5).scaleEffect(ripple.ring).opacity(ripple.ringOpacity) }
        } keyframes: { _ in
            KeyframeTrack(\.pop) {
                SpringKeyframe(1.35, duration: 0.14, spring: .snappy)
                SpringKeyframe(1, duration: 0.4, spring: .bouncy)
            }
            KeyframeTrack(\.ring) { CubicKeyframe(2.6, duration: 0.6) }
            KeyframeTrack(\.ringOpacity) {
                LinearKeyframe(0.9, duration: 0.05)
                CubicKeyframe(0, duration: 0.55)
            }
        }
        .animation(Motion.quick, value: shown)
        .onChange(of: shown.state) { old, new in
            if !reduceMotion, old.known?.isWorking == true, new == .known(.settled) { finished += 1 }
        }
        if announces {
            mark.accessibilityLabel(shown.presence).help(shown.presence)
        } else {
            mark.accessibilityHidden(true)
        }
    }

    private struct Ripple {
        var pop: CGFloat = 1
        var ring: CGFloat = 1
        var ringOpacity: Double = 0
    }
}

/// 状态标身后呼吸的一圈：从 0.7 倍呼到 1.6 倍、淡到看不见，再回来，一呼一吸 2.4s。
/// 用 Core Animation 而不是 SwiftUI 的 repeatForever 或符号动效：后两者每帧都在 App 进程里重算，
/// 列表里有几个在工作的会话时，静止不动也要占约 9% CPU；CA 的动画交给渲染服务，App 进程不参与，离屏不画。
private struct Halo {
    let color: Color

    private static func makeLayer() -> CAShapeLayer {
        let layer = CAShapeLayer()
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.7
        grow.toValue = 1.6
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let breath = CAAnimationGroup()
        breath.animations = [grow, fade]
        breath.duration = 1.2
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // 退到后台再回来时不被系统摘掉
        breath.isRemovedOnCompletion = false
        layer.add(breath, forKey: "breath")
        return layer
    }

    fileprivate static func update(_ layer: CAShapeLayer, bounds: CGRect, color: CGColor?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = bounds
        layer.path = CGPath(ellipseIn: bounds, transform: nil)
        layer.fillColor = color
        CATransaction.commit()
    }

    final class HaloView: PlatformView {
        let halo = Halo.makeLayer()
        var color: CGColor? { didSet { layoutHalo() } }

        #if os(iOS)
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            layer.addSublayer(halo)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            layoutHalo()
        }
        #else
        override init(frame: CGRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(halo)
        }

        override func layout() {
            super.layout()
            layoutHalo()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        #endif

        required init?(coder: NSCoder) { fatalError() }

        private func layoutHalo() { Halo.update(halo, bounds: bounds, color: color) }
    }
}

#if os(iOS)
private typealias PlatformView = UIView
extension Halo: UIViewRepresentable {
    func makeUIView(context: Context) -> HaloView { HaloView(frame: .zero) }
    func updateUIView(_ view: HaloView, context: Context) { view.color = color.opacity(0.28).resolve(in: context.environment).cgColor }
}
#else
private typealias PlatformView = NSView
extension Halo: NSViewRepresentable {
    func makeNSView(context: Context) -> HaloView { HaloView(frame: .zero) }
    func updateNSView(_ view: HaloView, context: Context) { view.color = color.opacity(0.28).resolve(in: context.environment).cgColor }
}
#endif

nonisolated extension PiQuestion {
    /// 只读地显示问题（只能在 Pi 里答的、或列表里的预览）：文案，下面每个选项一行。能作答的问题卡用 `options` 做成按钮。
    var displayText: String {
        ([text] + options.map { "· \($0)" }).joined(separator: "\n")
    }
}

nonisolated extension PiAnswerValue {
    /// 答了什么，一句话："覆盖"、"是"。
    var label: String {
        switch self {
        case .option(let option): option
        case .confirmed(let confirmed): confirmed ? "是" : "否"
        case .text(let text): text
        }
    }
}
