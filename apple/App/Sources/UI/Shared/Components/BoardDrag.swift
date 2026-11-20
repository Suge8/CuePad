import CueStore
import SwiftUI

/// 看板上拖一张卡。两种来路进同一份状态（`BoardMoves`）：
/// - 系统拖放（Mac 的鼠标；触屏上按住半秒、菜单出来之后再挪）：卡由系统画着跟手，能拖出看板（并排的会话格、别的窗口）。
/// - 触屏按住即拖（`BoardLift`）：按住 0.2 秒卡就浮在手里（`BoardFloat`），不等菜单；只在看板里放。
/// 拖着时原处留一个空位；在待办上空位跟着指针走、别的卡当场让开，松手就落在空位里，写库在后面跟。
/// 放到别的列上的卡先停在松手的地方，等看板读到它换了列，从那里飞进去（`BoardMoves.read`）；要先问一句的（`asking`）问着时一直停在那儿；
/// 等不到（不接、问了没答应）就滑回原处。系统拖放松手时系统画的那张就没了，换一张自己画的停着（`drop`）：不然卡先闪回原处、答应了再从原处飞。
/// 否决过：一条插入线——线只说"这里"，卡落下前后别的卡各跳一次。
extension BoardMoves {
    struct Held: Equatable {
        enum Phase { case dragging, settling, pending }

        let card: DraggedCard
        let id: String
        let size: CGSize
        var phase = Phase.dragging
    }

    /// 浮在手里的那张：`grab` 是按下的那一点离卡心多远，拖着时卡不往指尖下面跳。
    struct Float {
        let face: AnyView
        let row: Bool
        let grab: CGSize
    }

    /// 待办里的空位：`task` 那张排在第 `slot` 张之前（`TaskBoard.slots`）。
    struct Placed: Equatable {
        let task: UUID
        let slot: Int
    }

    /// 拖到了待办的边上：往这边滚，够得着没露出来的格。手机的行左右翻一小列（`BoardRowLane`），列上下滚（`LaneAnchor`）。
    struct Pull: Equatable {
        let column: TaskBoard.Column
        let edge: Edge
    }

    /// 空位此刻在哪：放下后、库还没写完时是放下的那一处，拖着时是指针指的那一处。
    var making: Placed? {
        if let placed { return placed }
        guard over == .todo, let slot, let task = held?.card.task else { return nil }
        return Placed(task: task, slot: slot)
    }

    private static let grace = Duration.milliseconds(600)
    private static let relayout = Duration.milliseconds(50)
    /// 指针离待办的边这么近就算到了边上（`pull`）。
    private static let reach: CGFloat = 36
    /// 从推进中拖回待办的卡在待办里垫的那一格空位，记它的框用的身份。
    static let well = "well"

    /// 卡在它那一列滚动区里的框；没排出来的没有（`shown`）。
    private func laid(of id: String) -> (lane: TaskBoard.Column, frame: CGRect)? { shown[id].flatMap { frames[$0] } }

    func frame(of id: String) -> CGRect? {
        guard let card = laid(of: id), let lane = lanes[card.lane] else { return nil }
        return card.frame.offsetBy(dx: lane.minX, dy: lane.minY)
    }

    /// 上一张放下后还悬着（等库、正落回去）就拖下一张：上一张当场收掉，不挡这一张。
    private func retire() {
        if let held, held.phase != .dragging { clear() }
    }

    func card(at point: CGPoint, among cards: [(flight: String, card: DraggedCard)]) -> (flight: String, card: DraggedCard)? {
        cards.first { frame(of: $0.flight)?.contains(point) == true }
    }

    // MARK: 系统拖放

    /// `local` 在那一列自己的坐标里（`DropInfo.location`）。
    func hover(_ card: DraggedCard, at local: CGPoint, in column: TaskBoard.Column, on board: TaskBoard, row: Bool) {
        retire()
        guard float == nil, let area = areas[column] else { return }
        if held == nil {
            let id = board.flight(of: card) ?? ""
            held = Held(card: card, id: id, size: laid(of: id)?.frame.size ?? .zero)
        }
        guard held?.card == card, held?.phase == .dragging else { return }
        let point = CGPoint(x: area.minX + local.x, y: area.minY + local.y)
        aim(card, at: point, in: column, on: board, row: row)
        // 触屏上系统拖放到了滚动区的边自己会滚；Mac 不会
        #if os(macOS)
        aimed = (point, board, row)
        pull(card, at: point, on: board, row: row)
        #endif
    }

    func leave(_ column: TaskBoard.Column) {
        guard float == nil, over == column else { return }
        over = nil
        slot = nil
        pull = nil
        aimed = nil
    }

    /// `face`：那张卡的面（按飞行身份取）。
    func drop(
        _ card: DraggedCard, at local: CGPoint, in column: TaskBoard.Column, on board: TaskBoard, row: Bool, face: (String) -> AnyView?
    ) -> TaskBoard.Drop? {
        hover(card, at: local, in: column, on: board, row: row)
        guard let held, held.card == card, held.phase == .dragging, let area = areas[column] else { return nil }
        let drop = board.drop(card, into: column, at: slot)
        let spot = CGPoint(x: area.minX + local.x, y: area.minY + local.y)
        hand = CGRect(x: spot.x - held.size.width / 2, y: spot.y - held.size.height / 2, width: held.size.width, height: held.size.height)
        if Self.waits(drop), let face = face(held.id) {
            point = spot
            float = Float(face: face, row: row, grab: .zero)
        }
        land(drop)
        return drop
    }

    /// 拖到看板外放下或取消了：落点收不到这一下，由拖的那一头报（`CardDrags`）。
    func systemEnded() {
        if float == nil, held?.phase == .dragging { clear() }
    }

    // MARK: 按住即拖

    /// 拎不起来为假：别的手指（或系统拖放）正拖着一张。
    func lift(_ card: DraggedCard, id: String, at finger: CGPoint, face: AnyView, row: Bool) -> Bool {
        retire()
        guard held == nil, let frame = frame(of: id) else { return false }
        point = CGPoint(x: frame.midX, y: frame.midY)
        float = Float(face: face, row: row, grab: CGSize(width: finger.x - frame.midX, height: finger.y - frame.midY))
        held = Held(card: card, id: id, size: frame.size)
        return true
    }

    func drag(to finger: CGPoint, on board: TaskBoard, row: Bool) {
        guard let held, held.phase == .dragging, let float else { return }
        point = CGPoint(x: finger.x - float.grab.width, y: finger.y - float.grab.height)
        aimed = (finger, board, row)
        aim(held.card, at: finger, in: areas.first { $0.value.contains(finger) }?.key, on: board, row: row)
        pull(held.card, at: finger, on: board, row: row)
    }

    /// 只在待办滚、只往空位还能去的那边滚：别的列放下就是，不看落在第几张。
    private func pull(_ card: DraggedCard, at point: CGPoint, on board: TaskBoard, row: Bool) {
        var edge: Edge?
        if over == .todo, let slot, let id = card.task, let lane = lanes[.todo] {
            let allowed = board.slots(for: id)
            let ahead = allowed.contains { $0 > slot }, behind = allowed.contains { $0 < slot }
            if row {
                edge = point.x > lane.maxX - Self.reach && ahead ? .trailing : point.x < lane.minX + Self.reach && behind ? .leading : nil
            } else {
                // 列头浮在滚动区顶上，顶边从它下面算
                let top = lane.minY + BoardColumnHeader.height + 2 * BoardCardMetrics.inset
                edge = point.y > lane.maxY - Self.reach && ahead ? .bottom : point.y < top + Self.reach && behind ? .top : nil
            }
        }
        let pull = edge.map { Pull(column: .todo, edge: $0) }
        if self.pull != pull { self.pull = pull }
    }

    /// 指针没动、底下的格动了（行翻了一小列、列滚了）：按原来那一点重算落在哪。
    func reaim() {
        guard let held, held.phase == .dragging, let aimed else { return }
        shifted = nil
        aim(held.card, at: aimed.finger, in: areas.first { $0.value.contains(aimed.finger) }?.key, on: aimed.board, row: aimed.row)
        // 空位滚到了能去的最后一处就停：不重算的话指针不动它一直滚到头
        pull(held.card, at: aimed.finger, on: aimed.board, row: aimed.row)
    }

    func release(on board: TaskBoard) -> TaskBoard.Drop? {
        guard let held, held.phase == .dragging, float != nil else { return nil }
        let drop = over.flatMap { board.drop(held.card, into: $0, at: slot) }
        land(drop)
        return drop
    }

    /// 系统收走了这一下（长按菜单出来、来电）：回原处。
    func cancel() {
        guard float != nil, held?.phase == .dragging else { return }
        land(nil)
    }

    // MARK: 落下

    private func aim(_ card: DraggedCard, at point: CGPoint, in column: TaskBoard.Column?, on board: TaskBoard, row: Bool) {
        let column = column.flatMap { board.drop(card, into: $0, at: nil) == nil ? nil : $0 }
        let slot = column == .todo ? slot(for: card, at: point, on: board, row: row) : nil
        if over != column { over = column }
        if self.slot != slot { self.slot = slot }
    }

    /// 空位该在第几张之前；只落在这张卡能落的位置里最近的一处（`TaskBoard.slots`）。
    /// 列里卡高不一，按别的卡的中线数（指针之前有几张，空位就在它们之后）：按格算的话空位一挪开，指针又落回刚让开的那张卡上，来回跳。
    /// 手机的行里各格一样大，指针进了谁的格空位就换到谁那儿：一格有大半屏宽，等指针过中线的话第二格的中线在屏幕外。
    private func slot(for card: DraggedCard, at point: CGPoint, on board: TaskBoard, row: Bool) -> Int? {
        guard let id = card.task, let lane = lanes[.todo] else { return nil }
        let allowed = board.slots(for: id)
        guard !allowed.isEmpty else { return nil }
        // 空位刚挪过、各格还没按新的排好：这时的框是旧的，照它算会把空位挪回去
        if let slot, let shifted, ContinuousClock.now - shifted < Self.relayout { return slot }
        let pointer = CGPoint(x: point.x - lane.minX, y: point.y - lane.minY)
        let home = board.todo.firstIndex { $0.id == id }
        let others = board.todo.enumerated().compactMap { index, item in item.id == id ? nil : laid(of: item.flight).map { (index: index, frame: $0.frame) } }
        func far(_ frame: CGRect) -> CGFloat {
            hypot(max(frame.minX - pointer.x, 0, pointer.x - frame.maxX), max(frame.minY - pointer.y, 0, pointer.y - frame.maxY))
        }
        let wanted: Int
        if !row {
            wanted = others.last { $0.frame.midY < pointer.y }.map { $0.index + 1 } ?? others.first?.index ?? 0
        } else if let near = others.min(by: { far($0.frame) < far($1.frame) }) {
            let well = laid(of: home == nil ? Self.well : "task/\(id)")?.frame
            // 空位在它前面就换到它后面，在它后面就换到它前面；指针还在空位里不动。从推进中刚拖进待办时还没有空位，看指针在它的前半还是后半
            if let current = slot ?? home {
                if let well, far(well) <= far(near.frame) { return current }
                wanted = current <= near.index ? near.index + 1 : near.index
            } else {
                wanted = pointer.x < near.frame.midX || pointer.y < near.frame.minY ? near.index : near.index + 1
            }
        } else {
            wanted = 0
        }
        let next = allowed.min { abs($0 - wanted) < abs($1 - wanted) }
        if next != slot { shifted = .now }
        return next
    }

    private func land(_ drop: TaskBoard.Drop?) {
        let slot = slot
        switch drop {
        case .place(let id, _?), .backToTodo(let id, _?): place(slot.map { Placed(task: id, slot: $0) })
        default: break
        }
        over = nil
        self.slot = nil
        pull = nil
        aimed = nil
        if Self.waits(drop) { pend() } else { settle() }
    }

    /// 放下后要等库才知道卡去哪：待办里排序的落在空位里，不等。
    private static func waits(_ drop: TaskBoard.Drop?) -> Bool {
        switch drop {
        case nil, .place: false
        default: true
        }
    }

    /// 写库失败、或写了也没换位置（别处同时改了）时不一直占着：过一会儿按库里的排。
    private func place(_ placed: Placed?) {
        self.placed = placed
        guard let placed else { return }
        Task {
            try? await Task.sleep(for: .seconds(1))
            if self.placed == placed { withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { self.placed = nil } }
        }
    }

    /// 浮着的卡落回它的空位。
    private func settle() {
        guard let held else { return }
        guard float != nil, !reduceMotion, let home = frame(of: held.id) else { return clear() }
        self.held?.phase = .settling
        withAnimation(Motion.release) { point = CGPoint(x: home.midX, y: home.midY) } completion: {
            if self.held?.id == held.id, self.held?.phase == .settling { self.clear() }
        }
    }

    func pend() {
        guard let held else { return }
        self.held?.phase = .pending
        Task {
            try? await Task.sleep(for: Self.grace)
            guard !asking, self.held?.id == held.id, self.held?.phase == .pending else { return }
            if placed != nil { withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { placed = nil } }
            settle()
        }
    }

    /// 放下后悬着的那张换了列：它从手里（松手的地方）起飞，不从原处。
    func takeoff(_ moved: [String: TaskBoard.Column]) -> (id: String, frame: CGRect)? {
        guard let held, held.phase == .pending, moved[held.id] != nil else { return nil }
        let frame = float == nil ? hand : CGRect(x: point.x - held.size.width / 2, y: point.y - held.size.height / 2, width: held.size.width, height: held.size.height)
        clear()
        return frame.map { (held.id, $0) }
    }

    private func clear() {
        held = nil
        float = nil
        hand = nil
        aimed = nil
        if over != nil { over = nil }
        if slot != nil { slot = nil }
        if pull != nil { pull = nil }
    }
}
