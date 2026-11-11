import SwiftUI

nonisolated enum BubbleSource: Equatable {
    case control(CGRect)
    /// 从一行里点的那一下（任务行）：行成百上千，不给每行挂几何读数，只知道点不知道行，按半行高（`BubblePlacement.reach`）让开整行；
    /// 尾巴靠左角对着那一下，气泡往右铺（顺着读的方向，不往回盖住侧栏）。
    case press(CGPoint)
    case unanchored
    case bottom
}

/// 不摆左右：摆在旁边会盖住被点的那一行、尾巴落在字上。
/// 不量自己的高：摆在上面时按底边对齐（`bottom`）——摆法从不读回排版的结果，没有几何读数回写的环（docs/layout.md）。
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
        case .control(let frame):
            target = frame.offsetBy(dx: -container.minX, dy: -container.minY)
        case .press(let point):
            target = CGRect(x: point.x - container.minX, y: point.y - container.minY - Self.reach, width: 0, height: Self.reach * 2)
            leads = true
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
        guard let anchor else { return ((minX + maxX - width) / 2, width) }
        let left = leads ? anchor - Self.lead : anchor - width / 2
        return (min(max(left, minX), maxX - width), width)
    }

    func tail(x: CGFloat, width: CGFloat) -> BubbleTail? {
        guard let tailEdge, let anchor else { return nil }
        return BubbleTail(edge: tailEdge, offset: min(max(anchor - x, Self.tailInset), width - Self.tailInset))
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
    #if os(macOS)
    static let radius = Radius.card
    #else
    static let radius = Radius.field
    #endif
    static let reach: CGFloat = TaskMetrics.rowHeight / 2
    static let tailInset: CGFloat = radius + BubbleTail.base / 2 + 4
    static let lead: CGFloat = tailInset + 20
    static let roomy: CGFloat = 360
    static let unanchoredTop: CGFloat = 40
    static let margin: CGFloat = 12
}

nonisolated struct BubbleTail: Equatable {
    var edge: VerticalEdge
    var offset: CGFloat

    static let length: CGFloat = 11
    static let base: CGFloat = 26
}

nonisolated struct BubbleShape: Shape {
    var tail: BubbleTail?
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.width / 2, rect.height / 2)
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

struct BubbleFrame<Content: View, Area: View>: View {
    let placement: BubblePlacement
    @ViewBuilder let content: Content
    @ViewBuilder var area: Area
    @Environment(\.palette) private var palette

    var body: some View {
        let card = RoundedRectangle(cornerRadius: placement.radius)
        ScrollView { content }
            .scrollBounceBehavior(.basedOnSize)
            .frame(minWidth: placement.narrowest, alignment: .topLeading)
            .clipShape(card)
            .rowContainer(card)
            .background { area }
            .background {
                GeometryReader { proxy in
                    let frame = proxy.frame(in: .named(BubbleStage.space))
                    let shape = BubbleShape(tail: placement.tail(x: frame.minX, width: frame.width), radius: placement.radius)
                    // 一根发丝粗的实线勾出轮廓与尾巴：气泡常落在同色的纸上，只靠投影时尾巴看不出（贴边再叠一层细影也行，但开合每帧多画一层影，掉帧）
                    shape.fill(palette.paper)
                        .elevation(.panel)
                        .overlay { shape.stroke(palette.track, lineWidth: Self.edge) }
                }
            }
            .layoutValue(key: BubbleSpot.self, value: placement)
    }

    private static var edge: CGFloat { 0.5 }
}

/// 只排一次，不读回排版结果。
struct BubbleStage: Layout {
    /// 挂 `BubbleStage` 的地方给 `coordinateSpace`，气泡按它画尾巴。
    nonisolated static let space = "bubble-stage"

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

