import SwiftUI

/// 气泡从哪长出来（窗口坐标）。摆法只认这一份，两端同一套（`BubblePlacement`）。
nonisolated enum BubbleSource: Equatable {
    /// 从一个控件（按钮、圆钮、胶囊）长出来：它的框。气泡横向对着它居中。
    case control(CGRect)
    /// 从一行里点的那一下（任务行）：行成百上千，不给每行挂几何读数，只知道点不知道行，按半行高（`BubblePlacement.reach`）让开整行；
    /// 尾巴靠左角对着那一下，气泡往右铺（顺着读的方向，不往回盖住侧栏）。
    case press(CGPoint)
    /// 没有来源（键盘、⌘K 里按 ↩、小组件链接）：没有尾巴，在窗口上方居中。
    case unanchored
    /// 贴在底部的一张纸（手机的任务气泡，`TaskBubbleSlot`）：横向铺满、留出同样的边，从底边升起，拖它的把手往下关（`BubbleDrag`）。
    case bottom
}

/// 长出来的气泡（`PanelStyle.bubble`：任务气泡、Mac 侧栏的额度明细）：纸色的底、一根指着来源的尾巴，不压暗、点外面或 Esc 关。
/// 摆在来源下面、让开它（控件的框，或那一下所在的整行），尾巴尖贴着它的下沿；下面放不下摆上面、尾巴在下沿。
/// 不摆左右：摆在旁边会盖住被点的那一行、尾巴落在字上。气泡的高贴着内容，放不下就在里面滚。
/// 不量自己的高：摆在上面时按底边对齐（`bottom`）——摆法从不读回排版的结果，没有几何读数回写的环（docs/layout.md）。
nonisolated struct BubblePlacement: Equatable {
    /// 气泡多宽：多数随内容（`fitting`，在 `minWidth`～`maxWidth` 之间，一两行说明不铺成一大块）；内容会翻页、会换的
    /// （任务气泡、"更多"）或自己排几栏的（额度明细）给定宽（`fixed`），翻页、换一条时宽不跳。都不超过容器。
    enum Width: Equatable {
        case fitting
        case fixed(CGFloat)
    }

    static let minWidth: CGFloat = 220
    static let maxWidth: CGFloat = 400

    /// 竖向摆法：上沿（摆在下面时）或下沿（摆在上面时）的 y，二选一。
    var top: CGFloat?
    var bottom: CGFloat?
    var maxHeight: CGFloat
    /// 尾巴长在哪条沿；尖离左边多远等横向摆好了才算（`tail(x:width:)`）。
    var tailEdge: VerticalEdge?
    /// 进出场从哪边来：朝着来源（尾巴尖）那一侧，-1 是上面、1 是下面。
    var side: CGFloat = -1
    /// 贴在底部的纸（`BubbleSource.bottom`）：圆角与屏幕同心、整张从底边升起。
    var sheet = false
    var radius: CGFloat { sheet ? Radius.screen : Self.radius }
    /// 横向：能放的范围（容器里的坐标）、宽的规则、对着哪儿（尾巴尖的 x；没有来源为 nil）、从哪儿起铺（控件居中，那一下靠左）。
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

    /// 气泡至少多宽：随内容的是最小宽，定宽的就是那个宽，贴底的纸铺满；不超过容器。
    var narrowest: CGFloat {
        let room = maxX - minX
        if sheet { return room }
        return switch width {
        case .fitting: min(BubblePlacement.minWidth, room)
        case .fixed(let fixed): min(fixed, room)
        }
    }

    /// 量内容时给的宽：规则允许的最宽，不超过容器。
    var widest: CGFloat {
        let room = maxX - minX
        return switch width {
        case .fitting: min(BubblePlacement.maxWidth, room)
        case .fixed(let fixed): min(fixed, room)
        }
    }

    /// 内容想要 `ideal` 宽时气泡的左边与宽：宽按规则、不超过容器；对着来源居中（那一下靠左起铺），推回容器里。
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

    /// 摆在 `x`、宽 `width` 时的尾巴：尖对着来源，不画到圆角上。
    func tail(x: CGFloat, width: CGFloat) -> BubbleTail? {
        guard let tailEdge, let anchor else { return nil }
        return BubbleTail(edge: tailEdge, offset: min(max(anchor - x, Self.tailInset), width - Self.tailInset))
    }

    /// 键盘升起、整块挪到键盘之上时（手机）：尾巴不再对着来源，收起。
    func lifted(_ lifted: Bool) -> BubblePlacement {
        var placement = self
        if lifted { placement.tailEdge = nil }
        return placement
    }

    /// 从来源那一侧浮出来：朝尾巴尖挪一小段加淡入；减弱动态效果时只淡入淡出。挂在气泡自己（只有气泡那么大）上。
    /// 不缩放（实测，Instruments）：缩放时每一帧字都按新的大小重画一遍（字形重新栅格化），开合各约 400ms 里主线程三成在重画字，掉帧；
    /// 平移不改字的大小，一次画好跟着走，开合的指令数降到原来的三成。缩放铺满整窗的一层更糟：AppKit 每帧重排整窗、重算鼠标跟踪区。
    /// 贴在底部的纸整张从底边升起、落回底边（同系统的纸页）。
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
    /// 那一下离所在那一行上下沿的距离（半行高）：气泡让开整行，尾巴尖贴着行沿。
    static let reach: CGFloat = TaskMetrics.rowHeight / 2
    /// 尾巴离气泡角的最小距离：不画到圆角上。
    static let tailInset: CGFloat = radius + BubbleTail.base / 2 + 4
    /// 尾巴尖离气泡左边多远（放得下时）。
    static let lead: CGFloat = tailInset + 20
    /// 下面至少留这么高就摆在下面（否则摆到空间大的那一侧）。
    static let roomy: CGFloat = 360
    static let unanchoredTop: CGFloat = 40
    static let margin: CGFloat = 12
}

/// 尾巴：长在上沿还是下沿、尖离左边多远。
nonisolated struct BubbleTail: Equatable {
    var edge: VerticalEdge
    var offset: CGFloat

    static let length: CGFloat = 11
    static let base: CGFloat = 26
}

/// 气泡的外形：圆角矩形加一根尖头微圆的尾巴，一笔画完（填色、描边、投影都是这一个形状）。
nonisolated struct BubbleShape: Shape {
    var tail: BubbleTail?
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.width / 2, rect.height / 2)
        let (minX, minY, maxX, maxY) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
        // 顺时针一笔：上沿向右、下沿向左，尾巴在哪条沿上就在那里拐出去
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

    /// 在横向的一条沿上、以 `center` 为中点拐出尾巴（`out` 是朝外的方向：上沿 -1、下沿 1）；沿着当前行进方向画，底与沿相切地收进去。
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

/// 一个气泡：纸底与尾巴（`BubbleShape`），内容放不下就在里面滚。`area` 垫在气泡下面（量它占的地方：Mac 认点在外面、手机认手指落在外面）。
/// 摆在哪由 `BubbleStage` 按 `BubblePlacement` 排；进出场（`BubblePlacement.transition`）挂在它上面。
struct BubbleFrame<Content: View, Area: View>: View {
    let placement: BubblePlacement
    @ViewBuilder let content: Content
    @ViewBuilder var area: Area
    @Environment(\.palette) private var palette

    var body: some View {
        let card = RoundedRectangle(cornerRadius: placement.radius)
        // 滚动区贴着内容的宽；不到最小宽（定宽的不到那个宽）时撑到它，内容靠左上
        ScrollView { content }
            .scrollBounceBehavior(.basedOnSize)
            .frame(minWidth: placement.narrowest, alignment: .topLeading)
            .clipShape(card)
            .rowContainer(card)
            .background { area }
            .background {
                // 尾巴尖对着来源：横向摆在哪由 `BubbleStage` 按内容的宽定，这里按摆好的位置画（只画图形，不回写排版）
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

    /// 轮廓线：Retina 上一个像素。
    private static var edge: CGFloat { 0.5 }
}

/// 气泡那一层的排法：铺满容器，每个气泡（`BubbleSpot` 带着它的摆法）先量内容想要多宽、按摆法定左边与宽（`BubblePlacement.frame`），再贴着内容的高、最高到摆法给的上限，
/// 按上沿或下沿放到摆法给的位置。给了 `floor`（手机键盘的上沿）时整块挪到它之上、不改高；高过 `floor` 到 `ceiling` 才矮下去。
/// 只排一次，不读回排版结果。
struct BubbleStage: Layout {
    /// 气泡那一层的坐标（挂 `BubbleStage` 的地方给 `coordinateSpace`）：气泡按它画尾巴（`BubbleFrame`）。
    nonisolated static let space = "bubble-stage"

    var floor: CGFloat?
    var ceiling: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            guard let spot = subview[BubbleSpot.self] else { continue }
            // 量内容在最宽时要多宽（长段落按最宽折行、短句就是自己那么宽）
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

