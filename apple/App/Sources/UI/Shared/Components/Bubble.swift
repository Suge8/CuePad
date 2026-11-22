import SwiftUI

extension EnvironmentValues {
    @Entry var bubbleInset: CGFloat = 0
}

nonisolated enum BubbleSource: Equatable {
    case control(CGRect, inset: CGFloat = 0)
    case press(CGPoint, left: CGFloat? = nil)
    case unanchored
    case bottom
}

nonisolated struct BubblePlacement: Equatable {
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

struct BubbleSwitch {
    var open: Bool { didSet { if oldValue, !open { closedAt = .now } } }
    private var closedAt: ContinuousClock.Instant?

    init(open: Bool = false) { self.open = open }

    mutating func toggle() { open = !open && !PressPoint.reopens(closedAt: closedAt) }
}
