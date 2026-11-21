import SwiftUI

extension EnvironmentValues {
    /// 这一块里的钮长出的气泡，两侧比平常多让这么多。回复框设成它那排圆钮离框边的距离：手机上框贴着页边，气泡盖着框的上沿，
    /// 边再同框的边重合，两个圆角就叠成一道缺口；让进去，落在圆钮的外沿上。
    @Entry var bubbleInset: CGFloat = 0
}

nonisolated enum BubbleSource: Equatable {
    /// `inset`：所在那一块要气泡两侧多让的（`bubbleInset`）。
    case control(CGRect, inset: CGFloat = 0)
    /// 从一行里点的那一下（任务行这类）：行成百上千，不给每行挂几何读数，只知道点不知道行，按半个列表行高（`BubblePlacement.reach`）让开整行；
    /// 尾巴靠左角对着那一下，气泡往右铺（顺着读的方向，不往回盖住侧栏）。
    /// `left`：按在一栏清单里时气泡的左沿（`PressPoint.lane`）——同一栏里点哪一条、点在标题的哪个字上，气泡都落在同一条竖线上。
    case press(CGPoint, left: CGFloat? = nil)
    case unanchored
    case bottom
}

/// 不摆左右：摆在旁边会盖住被点的那一行、尾巴落在字上。
/// 不量自己的高：摆在上面时按底边对齐（`bottom`）——摆法从不读回排版的结果，没有几何读数回写的环。
nonisolated struct BubblePlacement: Equatable {
    /// 内容会翻页、会换的（任务气泡、"更多"）或自己排几栏的（额度明细）给定宽（`fixed`），翻页、换一条时宽不跳；随内容（`fitting`）的一两行说明不铺成一大块。都不超过容器。
    enum Width: Equatable {
        case fitting
        case fixed(CGFloat)
    }

    static let minWidth: CGFloat = 220
    static let maxWidth: CGFloat = 400

    var top: CGFloat?
    var bottom: CGFloat?
    var maxHeight: CGFloat
    var tailEdge: VerticalEdge?
    var side: CGFloat = -1
    var sheet = false
    var radius: CGFloat { sheet ? Radius.screen : Self.radius }
    var minX: CGFloat
    var maxX: CGFloat
    var width: BubblePlacement.Width
    var anchor: CGFloat?
    var leads = false
    var left: CGFloat?

    /// `container`：气泡那一层在窗口里的框（与来源同一套坐标）；`insets`：容器四周不放气泡的那一圈（安全区、工具栏与页边）。
    /// 横向摆法要等量出内容的宽（`frame(ideal:)`，`BubbleStage` 排的时候算），竖向这里就定。
    init(source: BubbleSource, container: CGRect, insets: EdgeInsets, width: BubblePlacement.Width = .fitting) {
        let bounds = CGRect(
            x: insets.leading, y: insets.top,
            width: max(container.width - insets.leading - insets.trailing, 0), height: max(container.height - insets.top - insets.bottom, 0))
        minX = bounds.minX
        maxX = bounds.maxX
        self.width = width
        let target: CGRect
        switch source {
        case .unanchored:
            top = bounds.minY + Self.unanchoredTop
            maxHeight = bounds.height - Self.unanchoredTop
            return
        case .bottom:
            bottom = bounds.maxY
            maxHeight = bounds.height - Self.unanchoredTop
            side = 1
            sheet = true
            return
        case .control(let frame, let inset):
            target = frame.offsetBy(dx: -container.minX, dy: -container.minY)
            minX += inset
            maxX -= inset
        case .press(let point, let lane):
            target = CGRect(x: point.x - container.minX, y: point.y - container.minY - Self.reach, width: 0, height: Self.reach * 2)
            leads = true
            left = lane.map { $0 - container.minX }
        }
        anchor = target.midX
        let gap = BubbleTail.length
        let below = bounds.maxY - target.maxY - gap, above = target.minY - gap - bounds.minY
        if below >= Self.roomy || below >= above {
            top = target.maxY + gap
            maxHeight = below
            tailEdge = .top
        } else {
            bottom = target.minY - gap
            maxHeight = above
            tailEdge = .bottom
            side = 1
        }
    }

    var narrowest: CGFloat {
        let room = maxX - minX
        if sheet { return room }
        return switch width {
        case .fitting: min(BubblePlacement.minWidth, room)
        case .fixed(let fixed): min(fixed, room)
        }
    }

    var widest: CGFloat {
        let room = maxX - minX
        return switch width {
        case .fitting: min(BubblePlacement.maxWidth, room)
        case .fixed(let fixed): min(fixed, room)
        }
    }

    func frame(ideal: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let room = maxX - minX
        if sheet { return (minX, room) }
        let wanted = switch width {
        case .fitting: min(max(ideal, BubblePlacement.minWidth), BubblePlacement.maxWidth)
        case .fixed(let fixed): fixed
        }
        let width = min(wanted, room)
        return (x(width: width), width)
    }

    /// 左沿只由宽定：气泡的形状（`BubbleShape`）拿到自己的宽就画得出尾巴，不读回摆的位置。
    private func x(width: CGFloat) -> CGFloat {
        if sheet { return minX }
        guard let anchor else { return (minX + maxX - width) / 2 }
        let left = left ?? (leads ? anchor - Self.lead : anchor - width / 2)
        return min(max(left, minX), maxX - width)
    }

    func tail(width: CGFloat) -> BubbleTail? {
        guard let tailEdge, let anchor else { return nil }
        return BubbleTail(edge: tailEdge, offset: min(max(anchor - x(width: width), Self.tailInset), width - Self.tailInset))
    }

    func lifted(_ lifted: Bool) -> BubblePlacement {
        var placement = self
        if lifted { placement.tailEdge = nil }
        return placement
    }

    /// 不缩放（实测，Instruments）：缩放时每一帧字都按新的大小重画一遍（字形重新栅格化），开合各约 400ms 里主线程三成在重画字，掉帧；
    /// 平移不改字的大小，一次画好跟着走，开合的指令数降到原来的三成。缩放铺满整窗的一层更糟：AppKit 每帧重排整窗、重算鼠标跟踪区。
    func transition(reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .opacity }
        return sheet ? .move(edge: .bottom) : .offset(y: side * Self.rise).combined(with: .opacity)
    }

    static let rise: CGFloat = 8
    /// 同新会话、记任务的输入卡。
    static let radius = Radius.field
    static let reach: CGFloat = RowMetrics.height / 2
    // 尾巴根离圆角起弧处再让一点，尾巴不骑在弧上
    static let tailInset: CGFloat = radius + BubbleTail.base / 2 + 4
    static let lead: CGFloat = tailInset + 20
    static let roomy: CGFloat = 360
    static let unanchoredTop: CGFloat = 40
    static let margin = Spacing.group
}

nonisolated struct BubbleTail: Equatable {
    var edge: VerticalEdge
    var offset: CGFloat

    static let length: CGFloat = 11
    static let base: CGFloat = 26
}

nonisolated struct BubbleShape: Shape {
    var placement: BubblePlacement

    func path(in rect: CGRect) -> Path {
        let tail = placement.tail(width: rect.width)
        let r = min(placement.radius, rect.width / 2, rect.height / 2)
        let (minX, minY, maxX, maxY) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
        var path = Path()
        path.move(to: CGPoint(x: minX + r, y: minY))
        if let tail, tail.edge == .top { spike(&path, at: minX + tail.offset, edgeY: minY, out: -1) }
        path.addLine(to: CGPoint(x: maxX - r, y: minY))
        path.addArc(tangent1End: CGPoint(x: maxX, y: minY), tangent2End: CGPoint(x: maxX, y: minY + r), radius: r)
        path.addLine(to: CGPoint(x: maxX, y: maxY - r))
        path.addArc(tangent1End: CGPoint(x: maxX, y: maxY), tangent2End: CGPoint(x: maxX - r, y: maxY), radius: r)
        if let tail, tail.edge == .bottom { spike(&path, at: minX + tail.offset, edgeY: maxY, out: 1) }
        path.addLine(to: CGPoint(x: minX + r, y: maxY))
        path.addArc(tangent1End: CGPoint(x: minX, y: maxY), tangent2End: CGPoint(x: minX, y: maxY - r), radius: r)
        path.addLine(to: CGPoint(x: minX, y: minY + r))
        path.addArc(tangent1End: CGPoint(x: minX, y: minY), tangent2End: CGPoint(x: minX + r, y: minY), radius: r)
        path.closeSubpath()
        return path
    }

    private func spike(_ path: inout Path, at center: CGFloat, edgeY: CGFloat, out: CGFloat) {
        let forward: CGFloat = -out
        let half = BubbleTail.base / 2, tip = edgeY + out * BubbleTail.length
        path.addLine(to: CGPoint(x: center - forward * half, y: edgeY))
        path.addCurve(
            to: CGPoint(x: center - forward * 2, y: tip + -out * 0.6),
            control1: CGPoint(x: center - forward * half * 0.55, y: edgeY),
            control2: CGPoint(x: center - forward * 4, y: tip))
        path.addQuadCurve(to: CGPoint(x: center + forward * 2, y: tip + -out * 0.6), control: CGPoint(x: center, y: tip + out * 0.4))
        path.addCurve(
            to: CGPoint(x: center + forward * half, y: edgeY),
            control1: CGPoint(x: center + forward * 4, y: tip),
            control2: CGPoint(x: center + forward * half * 0.55, y: edgeY))
    }
}

extension View {
    /// 气泡内容最外层的一块标成钉在底下的：内容放不下、在气泡里滚时它不跟着滚走，别的在它上面滚。
    func bubbleFoot() -> some View { containerValue(\.bubbleFoot, true) }
}

extension ContainerValues {
    @Entry fileprivate var bubbleFoot = false
}

struct BubbleFrame<Content: View, Area: View>: View {
    let placement: BubblePlacement
    @ViewBuilder let content: Content
    @ViewBuilder var area: Area

    var body: some View {
        let card = RoundedRectangle(cornerRadius: placement.radius)
        Group(subviews: content) { parts in
            let feet = parts.filter(\.containerValues.bubbleFoot)
            let scroll = ScrollView { ForEach(parts.filter { !$0.containerValues.bubbleFoot }) { $0 } }
                .scrollBounceBehavior(.basedOnSize)
                .debugScrollsToMiddle()
            if feet.isEmpty {
                scroll
            } else {
                // 钉着的那块排在滚动区下面、不压在它上面；滚着的内容到它跟前那一小截淡出，不被一条直线切断（不滚时这一截是内容自己的下边距）。
                // 否决过：系统的栏（`safeAreaBar`）——滚着的字从钉着的那块后面透出来，叠在它的字上。
                VStack(spacing: 0) {
                    scroll.mask {
                        VStack(spacing: 0) {
                            Rectangle()
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: Spacing.item)
                        }
                    }
                    ForEach(feet) { $0 }
                }
            }
        }
            .frame(minWidth: placement.narrowest, alignment: .topLeading)
            .clipShape(card)
            .rowContainer(card)
            .glass(in: BubbleShape(placement: placement))
            .background { area }
            .layoutValue(key: BubbleSpot.self, value: placement)
    }
}

/// 只排一次，不读回排版结果。
struct BubbleStage: Layout {
    var floor: CGFloat?
    var ceiling: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            guard let spot = subview[BubbleSpot.self] else { continue }
            let (x, width) = spot.frame(ideal: subview.sizeThatFits(ProposedViewSize(width: spot.widest, height: nil)).width)
            let ideal = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            var height = min(ideal.height, spot.maxHeight)
            var y = spot.top ?? ((spot.bottom ?? 0) - height)
            if let floor, y + height > floor {
                height = min(height, floor - ceiling)
                y = floor - height
            }
            subview.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(width: width, height: height))
        }
    }
}

nonisolated private struct BubbleSpot: LayoutValueKey {
    static let defaultValue: BubblePlacement? = nil
}

/// 从控件长出的气泡开没开（`bubble(isPresented:)` 绑 `open`，控件点了 `toggle`）：点气泡外收起时按下的就是开关的话，
/// 松开时开关又要打开它——刚在这一下收起的不再打开（`PressPoint.reopens`）。
struct BubbleSwitch {
    var open: Bool { didSet { if oldValue, !open { closedAt = .now } } }
    private var closedAt: ContinuousClock.Instant?

    init(open: Bool = false) { self.open = open }

    mutating func toggle() { open = !open && !PressPoint.reopens(closedAt: closedAt) }
}
