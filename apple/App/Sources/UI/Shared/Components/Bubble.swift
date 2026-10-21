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
}

/// 长出来的气泡（`PanelStyle.bubble`：任务气泡、Mac 会话页的额度明细）：纸色的底、一根指着来源的尾巴，不压暗、点外面或 Esc 关。
/// 摆在来源下面、让开它（控件的框，或那一下所在的整行），尾巴尖贴着它的下沿；下面放不下摆上面、尾巴在下沿。
/// 不摆左右：摆在旁边会盖住被点的那一行、尾巴落在字上。气泡的高贴着内容，放不下就在里面滚。
/// 不量自己的高：摆在上面时按底边对齐（`bottom`）——摆法从不读回排版的结果，没有几何读数回写的环（ui.md）。
nonisolated struct BubblePlacement: Equatable {
    var x: CGFloat
    /// 上沿（摆在下面时）或下沿（摆在上面时）的 y，二选一。
    var top: CGFloat?
    var bottom: CGFloat?
    var width: CGFloat
    var maxHeight: CGFloat
    var tail: BubbleTail?
    /// 进出场从哪边来：朝着来源（尾巴尖）那一侧，-1 是上面、1 是下面。
    var side: CGFloat = -1

    /// `container`：气泡那一层在窗口里的框（与来源同一套坐标）；`insets`：容器四周不放气泡的那一圈（安全区、工具栏与页边）。
    init(source: BubbleSource, container: CGRect, insets: EdgeInsets) {
        let bounds = CGRect(
            x: insets.leading, y: insets.top,
            width: max(container.width - insets.leading - insets.trailing, 0), height: max(container.height - insets.top - insets.bottom, 0))
        width = min(Self.width, bounds.width)
        // 要让开的那一块（容器里的坐标）与气泡想放的左边
        let target: CGRect, left: CGFloat
        switch source {
        case .unanchored:
            x = bounds.midX - width / 2
            top = bounds.minY + Self.unanchoredTop
            maxHeight = bounds.height - Self.unanchoredTop
            return
        case .control(let frame):
            target = frame.offsetBy(dx: -container.minX, dy: -container.minY)
            left = target.midX - width / 2
        case .press(let point):
            target = CGRect(x: point.x - container.minX, y: point.y - container.minY - Self.reach, width: 0, height: Self.reach * 2)
            left = target.midX - Self.lead
        }
        x = min(max(left, bounds.minX), bounds.maxX - width)
        let along = min(max(target.midX - x, Self.tailInset), width - Self.tailInset)
        let gap = BubbleTail.length
        let below = bounds.maxY - target.maxY - gap, above = target.minY - gap - bounds.minY
        if below >= Self.roomy || below >= above {
            top = target.maxY + gap
            maxHeight = below
            tail = BubbleTail(edge: .top, offset: along)
        } else {
            bottom = target.minY - gap
            maxHeight = above
            tail = BubbleTail(edge: .bottom, offset: along)
            side = 1
        }
    }

    /// 贴在容器下沿（键盘上沿）、横向居中，没有尾巴：手机上在气泡里写正文、键盘升起时。
    init(dockedIn container: CGSize, insets: EdgeInsets) {
        width = min(Self.width, container.width - insets.leading - insets.trailing)
        x = (container.width - width) / 2
        bottom = container.height - insets.bottom
        maxHeight = container.height - insets.top - insets.bottom
        side = 1
    }

    /// 从来源那一侧浮出来：朝尾巴尖挪一小段加淡入；减弱动态效果时只淡入淡出。挂在气泡自己（只有气泡那么大）上。
    /// 不缩放（实测，Instruments）：缩放时每一帧字都按新的大小重画一遍（字形重新栅格化），开合各约 400ms 里主线程三成在重画字，掉帧；
    /// 平移不改字的大小，一次画好跟着走，开合的指令数降到原来的三成。缩放铺满整窗的一层更糟：AppKit 每帧重排整窗、重算鼠标跟踪区。
    func transition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .offset(y: side * Self.rise).combined(with: .opacity)
    }

    static let width: CGFloat = 400
    static let rise: CGFloat = 8
    #if os(macOS)
    static let radius: CGFloat = 18
    #else
    static let radius: CGFloat = 26
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
        let shape = BubbleShape(tail: placement.tail, radius: BubblePlacement.radius)
        let card = RoundedRectangle(cornerRadius: BubblePlacement.radius, style: .continuous)
        ScrollView { content }
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: placement.width)
            .clipShape(card)
            .rowContainer(card)
            .background { area }
            .background {
                // 一根发丝粗的实线勾出轮廓与尾巴：气泡常落在同色的纸上，只靠投影时尾巴看不出（贴边再叠一层细影也行，但开合每帧多画一层影，掉帧）
                shape.fill(palette.paper)
                    .shadow(color: palette.panelShadow, radius: 26, y: 10)
                    .overlay { shape.stroke(palette.track, lineWidth: Self.edge) }
            }
            .layoutValue(key: BubbleSpot.self, value: placement)
    }

    /// 轮廓线：Retina 上一个像素。
    private static var edge: CGFloat { 0.5 }
}

/// 气泡那一层的排法：铺满容器，每个气泡（`BubbleSpot` 带着它的摆法）贴着内容的高、最高到摆法给的上限，
/// 按上沿或下沿放到摆法给的位置。只排一次，不读回排版结果。
struct BubbleStage: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            guard let spot = subview[BubbleSpot.self] else { continue }
            let ideal = subview.sizeThatFits(ProposedViewSize(width: spot.width, height: nil))
            let height = min(ideal.height, spot.maxHeight)
            let y = spot.top ?? ((spot.bottom ?? 0) - height)
            subview.place(at: CGPoint(x: bounds.minX + spot.x, y: bounds.minY + y), proposal: ProposedViewSize(width: spot.width, height: height))
        }
    }
}

nonisolated private struct BubbleSpot: LayoutValueKey {
    static let defaultValue: BubblePlacement? = nil
}
