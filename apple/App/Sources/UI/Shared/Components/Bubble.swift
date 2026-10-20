import SwiftUI

/// 从被点的那一下长出来的气泡（任务气泡用它，`PanelStyle.bubble`）：纸色的底、一根指着那一下的尾巴，不压暗、点外面或 Esc 关。
/// 摆法只在 `BubblePlacement` 算一次，两端同一套：Mac 摆在那一下的右边（右边放不下摆左边），手机摆在下面（下面放不下摆上面）；
/// 不知道点在哪（键盘、⌘K 里按 ↩、小组件链接）时没有尾巴、在窗口上方居中。气泡的高贴着内容，放不下就在里面滚。
/// 不量自己的高：摆在上面时按底边对齐（`bottom`），尾巴从底边量起——摆法从不读回排版的结果，没有几何读数回写的环（ui.md）。
nonisolated struct BubblePlacement: Equatable {
    var x: CGFloat
    /// 上沿（摆在下面、旁边时）或下沿（摆在上面时）的 y，二选一。
    var top: CGFloat?
    var bottom: CGFloat?
    var width: CGFloat
    var maxHeight: CGFloat
    var tail: BubbleTail?
    /// 长出来的那个点（气泡自己的坐标）：尾巴尖。左右摆、靠上角时当作在上角（尾巴离上角不到一个圆角加半个尾巴宽，气泡的真高不量）。
    var growth: UnitPoint = .top

    /// `anchor`：那一下在容器里的位置；`insets`：容器四周不放气泡的那一圈（安全区、工具栏与页边）。
    init(anchor: CGPoint?, container: CGSize, insets: EdgeInsets) {
        let bounds = CGRect(
            x: insets.leading, y: insets.top,
            width: max(container.width - insets.leading - insets.trailing, 0), height: max(container.height - insets.top - insets.bottom, 0))
        self.init(anchor: anchor, in: bounds)
    }

    /// 贴在容器下沿（键盘上沿）、横向居中，没有尾巴：手机上在气泡里写正文、键盘升起时。
    init(dockedIn container: CGSize, insets: EdgeInsets) {
        width = min(Self.width, container.width - insets.leading - insets.trailing)
        x = (container.width - width) / 2
        bottom = container.height - insets.bottom
        maxHeight = container.height - insets.top - insets.bottom
        growth = .bottom
    }

    private init(anchor: CGPoint?, in bounds: CGRect) {
        guard let anchor else {
            self.init(unanchoredIn: bounds)
            return
        }
        #if os(macOS)
        let width = min(Self.width, bounds.width)
        let right = bounds.maxX - anchor.x - Self.gap >= width
        let left = anchor.x - Self.gap - bounds.minX >= width
        if right || left {
            self.init(beside: anchor, right: right, in: bounds)
            return
        }
        #endif
        self.init(over: anchor, in: bounds)
    }

    private init(unanchoredIn bounds: CGRect) {
        width = min(Self.width, bounds.width)
        x = bounds.midX - width / 2
        top = bounds.minY + Self.unanchoredTop
        maxHeight = bounds.height - Self.unanchoredTop
    }

    /// 上下摆：尾巴在上沿或下沿，横向对着那一下。
    private init(over anchor: CGPoint, in bounds: CGRect) {
        width = min(Self.width, bounds.width)
        x = min(max(anchor.x - width / 2, bounds.minX), bounds.maxX - width)
        let along = min(max(anchor.x - x, Self.tailInset), width - Self.tailInset)
        let below = bounds.maxY - anchor.y - Self.gap, above = anchor.y - Self.gap - bounds.minY
        if below >= Self.roomy || below >= above {
            top = anchor.y + Self.gap
            maxHeight = below
            tail = BubbleTail(edge: .top, offset: along, fromEnd: false)
            growth = UnitPoint(x: along / width, y: 0)
        } else {
            bottom = anchor.y - Self.gap
            maxHeight = above
            tail = BubbleTail(edge: .bottom, offset: along, fromEnd: false)
            growth = UnitPoint(x: along / width, y: 1)
        }
    }

    #if os(macOS)
    /// 左右摆：尾巴在左沿或右沿、靠近上角对着那一下；下面放不下时改成靠近下角、按底边对齐。
    private init(beside anchor: CGPoint, right: Bool, in bounds: CGRect) {
        width = min(Self.width, bounds.width)
        x = right ? anchor.x + Self.gap : anchor.x - Self.gap - width
        let edge: Edge = right ? .leading : .trailing
        let top = max(anchor.y - Self.tailInset, bounds.minY)
        if bounds.maxY - top >= Self.roomy {
            self.top = top
            maxHeight = bounds.maxY - top
            tail = BubbleTail(edge: edge, offset: anchor.y - top, fromEnd: false)
            growth = UnitPoint(x: right ? 0 : 1, y: 0)
        } else {
            let bottom = min(anchor.y + Self.tailInset, bounds.maxY)
            self.bottom = bottom
            maxHeight = bottom - bounds.minY
            tail = BubbleTail(edge: edge, offset: bottom - anchor.y, fromEnd: true)
            growth = UnitPoint(x: right ? 0 : 1, y: 1)
        }
    }
    #endif

    /// 从尾巴尖长出来：缩放加淡入；减弱动态效果时只淡入淡出。挂在气泡自己（只有气泡那么大）上：
    /// 缩放铺满整窗的一层时 AppKit 每帧重排整窗、重算鼠标跟踪区，开合各掉十来帧（实测）。
    func transition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.86, anchor: growth).combined(with: .opacity)
    }

    #if os(macOS)
    static let width: CGFloat = 400
    static let radius: CGFloat = 18
    #else
    static let width: CGFloat = 400
    static let radius: CGFloat = 26
    #endif
    /// 尾巴离那一下留的缝加尾巴自己的高。
    static let gap: CGFloat = BubbleTail.length + 4
    /// 尾巴离气泡角的最小距离：不画到圆角上。
    static let tailInset: CGFloat = radius + BubbleTail.base / 2 + 4
    /// 这一侧至少留这么高才摆在这一侧（否则摆到空间大的另一侧）。
    static let roomy: CGFloat = 360
    /// 没有落点时离可用区上沿的距离。
    static let unanchoredTop: CGFloat = 40
    /// 气泡离窗口边与安全区的距离。
    static let margin: CGFloat = 12
}

/// 尾巴：长在哪条边上、离那条边起点（左、上；`fromEnd` 时从右、下量）多远。
nonisolated struct BubbleTail: Equatable {
    var edge: Edge
    var offset: CGFloat
    var fromEnd: Bool

    static let length: CGFloat = 9
    static let base: CGFloat = 20
}

/// 气泡的外形：圆角矩形加一根圆头的尾巴，一笔画完（填色、描边、投影都是这一个形状）。
nonisolated struct BubbleShape: Shape {
    var tail: BubbleTail?
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.width / 2, rect.height / 2)
        let (minX, minY, maxX, maxY) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
        // 顺时针一笔：每条边经过 `side`，尾巴长在哪条边上就在那条边中间拐出去
        var path = Path()
        path.move(to: CGPoint(x: minX + r, y: minY))
        side(&path, .top, to: CGPoint(x: maxX - r, y: minY), at: tailCenter(.top, rect), outward: CGVector(dx: 0, dy: -1))
        path.addArc(tangent1End: CGPoint(x: maxX, y: minY), tangent2End: CGPoint(x: maxX, y: minY + r), radius: r)
        side(&path, .trailing, to: CGPoint(x: maxX, y: maxY - r), at: tailCenter(.trailing, rect), outward: CGVector(dx: 1, dy: 0))
        path.addArc(tangent1End: CGPoint(x: maxX, y: maxY), tangent2End: CGPoint(x: maxX - r, y: maxY), radius: r)
        side(&path, .bottom, to: CGPoint(x: minX + r, y: maxY), at: tailCenter(.bottom, rect), outward: CGVector(dx: 0, dy: 1))
        path.addArc(tangent1End: CGPoint(x: minX, y: maxY), tangent2End: CGPoint(x: minX, y: maxY - r), radius: r)
        side(&path, .leading, to: CGPoint(x: minX, y: minY + r), at: tailCenter(.leading, rect), outward: CGVector(dx: -1, dy: 0))
        path.addArc(tangent1End: CGPoint(x: minX, y: minY), tangent2End: CGPoint(x: minX + r, y: minY), radius: r)
        path.closeSubpath()
        return path
    }

    /// 尾巴在这条边上时，它的中点（沿边的坐标）。
    private func tailCenter(_ edge: Edge, _ rect: CGRect) -> CGFloat? {
        guard let tail, tail.edge == edge else { return nil }
        switch edge {
        case .top, .bottom: return tail.fromEnd ? rect.maxX - tail.offset : rect.minX + tail.offset
        case .leading, .trailing: return tail.fromEnd ? rect.maxY - tail.offset : rect.minY + tail.offset
        }
    }

    /// 从当前点沿一条边画到 `end`；`center` 给了时在那里拐出一根圆头的尾巴（底宽 `BubbleTail.base`、伸出 `BubbleTail.length`）。
    private func side(_ path: inout Path, _ edge: Edge, to end: CGPoint, at center: CGFloat?, outward: CGVector) {
        guard let center, let from = path.currentPoint else { return path.addLine(to: end) }
        let horizontal = edge == .top || edge == .bottom
        // 沿边前进的方向（顺时针：上边向右、右边向下、下边向左、左边向上）
        let forward: CGFloat = (horizontal ? end.x - from.x : end.y - from.y) >= 0 ? 1 : -1
        func point(_ along: CGFloat, out: CGFloat) -> CGPoint {
            horizontal
                ? CGPoint(x: along, y: from.y + outward.dy * out)
                : CGPoint(x: from.x + outward.dx * out, y: along)
        }
        let half = BubbleTail.base / 2, length = BubbleTail.length
        path.addLine(to: point(center - forward * half, out: 0))
        path.addQuadCurve(to: point(center, out: length), control: point(center - forward * half * 0.3, out: length * 0.9))
        path.addQuadCurve(to: point(center + forward * half, out: 0), control: point(center + forward * half * 0.3, out: length * 0.9))
        path.addLine(to: end)
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
                shape.fill(palette.paper)
                    .shadow(color: palette.panelShadow, radius: 26, y: 10)
                    .overlay { shape.stroke(palette.hair, lineWidth: 1) }
            }
            .layoutValue(key: BubbleSpot.self, value: placement)
    }
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
