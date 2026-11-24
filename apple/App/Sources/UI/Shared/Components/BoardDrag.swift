import CueStore
import SwiftUI

/// 看板上拖一张卡。两种来路进同一份状态（`BoardMoves`）：
/// - 系统拖放（Mac 的鼠标；触屏上按住半秒、菜单出来之后再挪）：卡由系统画着跟手，能拖出看板（并排的会话格、别的窗口）。
/// - 触屏按住即拖（`BoardLift`）：按住 0.2 秒卡就浮在手里（`BoardFloat`），不等菜单；只在看板里放。
/// 拖着时原处留一个空位；在待办上空位跟着指针走、别的卡当场让开，松手就落在空位里，写库在后面跟。
/// 放到别的列上的卡先停在松手的地方，等看板读到它换了列，从那里飞进去（`BoardMoves.read`）；要先问一句的（`asking`）问着时一直停在那儿；
/// 飞的那一路手里这张陪着、裁成那边的大小、一路淡掉：两列里卡的样子不一样（手机的已完成是一行高的薄条），看起来是一张卡边走边变样，不是这张没了、那张冒出来。
/// 等不到（不接、问了没答应）就滑回原处。系统拖放松手时系统画的那张就没了，换一张自己画的停着（`drop`）：不然卡先闪回原处、答应了再从原处飞。
/// 否决过：一条插入线——线只说"这里"，卡落下前后别的卡各跳一次。
extension BoardMoves {
    struct Held: Equatable {
        enum Phase { case dragging, settling, pending, landing, leaving }

        let card: DraggedCard
        var id: TaskBoard.Flight
        let size: CGSize
        var phase = Phase.dragging
        var lane: TaskBoard.Column?
        var home: CGRect?
    }

    struct Float {
        let face: AnyView
        let row: Bool
        let grab: CGSize
    }

    struct Placed: Equatable {
        let task: UUID
        let slot: Int
    }

    struct Pull: Equatable {
        let column: TaskBoard.Column
        let edge: Edge
    }

    var making: Placed? {
        if let placed { return placed }
        guard over == .todo, let slot, let task = held?.card.task else { return nil }
        return Placed(task: task, slot: slot)
    }

    private static let grace = Duration.milliseconds(600)
    private static let relayout = Duration.milliseconds(50)
    private static let patience = 6
    private static let reach: CGFloat = 36

    private func laid(of id: TaskBoard.Flight) -> (lane: TaskBoard.Column, frame: CGRect)? {
        if shown[id] != nil { return frames[id] }
        for stack in stacks.values where !stack.frame.isNull {
            guard let cell = stack.ids.firstIndex(of: id) else { continue }
            return (stack.lane, CGRect(x: stack.frame.minX, y: stack.frame.minY + CGFloat(cell) * stack.pitch, width: stack.frame.width, height: stack.height))
        }
        return nil
    }

    func frame(of id: TaskBoard.Flight) -> CGRect? {
        guard let card = laid(of: id), let lane = lanes[card.lane] else { return nil }
        return card.frame.offsetBy(dx: lane.minX, dy: lane.minY)
    }

    private func retire() {
        if let held, held.phase != .dragging { clear() }
    }

    func card(at point: CGPoint, among cards: [(flight: TaskBoard.Flight, card: DraggedCard)]) -> (flight: TaskBoard.Flight, card: DraggedCard)? {
        cards.first { frame(of: $0.flight)?.contains(point) == true }
    }

    // MARK: 系统拖放

    func hover(_ card: DraggedCard, flight: TaskBoard.Flight, at local: CGPoint, in column: TaskBoard.Column, on board: TaskBoard, row: Bool) {
        retire()
        guard float == nil, let area = areas[column] else { return }
        if held == nil { held = Held(card: card, id: flight, size: laid(of: flight)?.frame.size ?? .zero) }
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

    func drop(
        _ card: DraggedCard, flight: TaskBoard.Flight, at local: CGPoint, in column: TaskBoard.Column, on board: TaskBoard, row: Bool,
        face: (TaskBoard.Flight) -> AnyView?
    ) -> TaskBoard.Drop? {
        hover(card, flight: flight, at: local, in: column, on: board, row: row)
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

    func lift(_ card: DraggedCard, id: TaskBoard.Flight, at finger: CGPoint, face: AnyView, row: Bool) -> Bool {
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

    private func pull(_ card: DraggedCard, at point: CGPoint, on board: TaskBoard, row: Bool) {
        var edge: Edge?
        if over == .todo, let slot, let id = card.task, let lane = lanes[.todo] {
            let allowed = board.slots(for: id)
            let ahead = allowed.contains { $0 > slot }, behind = allowed.contains { $0 < slot }
            if row {
                edge = point.x > lane.maxX - Self.reach && ahead ? .trailing : point.x < lane.minX + Self.reach && behind ? .leading : nil
            } else {
                let top = lane.minY + BoardColumnHeader.height + 2 * BoardCardMetrics.inset
                edge = point.y > lane.maxY - Self.reach && ahead ? .bottom : point.y < top + Self.reach && behind ? .top : nil
            }
        }
        let pull = edge.map { Pull(column: .todo, edge: $0) }
        if self.pull != pull { self.pull = pull }
    }

    func reaim() {
        guard let held, held.phase == .dragging, let aimed else { return }
        shifted = nil
        aim(held.card, at: aimed.finger, in: areas.first { $0.value.contains(aimed.finger) }?.key, on: aimed.board, row: aimed.row)
        pull(held.card, at: aimed.finger, on: aimed.board, row: aimed.row)
    }

    func release(on board: TaskBoard) -> TaskBoard.Drop? {
        guard let held, held.phase == .dragging, float != nil else { return nil }
        let drop = over.flatMap { board.drop(held.card, into: $0, at: slot) }
        land(drop)
        return drop
    }

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

    private func slot(for card: DraggedCard, at point: CGPoint, on board: TaskBoard, row: Bool) -> Int? {
        guard let id = card.task, let lane = lanes[.todo] else { return nil }
        let allowed = board.slots(for: id)
        guard !allowed.isEmpty else { return nil }
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
            let well = laid(of: home == nil ? .well : .task(id))?.frame
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

    private static func waits(_ drop: TaskBoard.Drop?) -> Bool {
        switch drop {
        case nil, .place: false
        default: true
        }
    }

    private func place(_ placed: Placed?) {
        self.placed = placed
        guard let placed else { return }
        Task {
            try? await Task.sleep(for: .seconds(1))
            if self.placed == placed { withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { self.placed = nil } }
        }
    }

    private func settle() {
        guard let held else { return }
        guard float != nil, !reduceMotion, let home = frame(of: held.id) else { return clear() }
        self.held?.phase = .settling
        withAnimation(Motion.release) { point = CGPoint(x: home.midX, y: home.midY) } completion: {
            if self.held?.id == held.id, self.held?.phase == .settling { self.clear() }
        }
    }

    func pend() {
        guard held != nil else { return }
        held?.phase = .pending
        waiting?.cancel()
        waiting = Task {
            try? await Task.sleep(for: Self.grace)
            guard !Task.isCancelled, !asking else { return }
            giveUp()
        }
    }

    func decline() {
        guard held?.phase == .pending else { return }
        waiting?.cancel()
        giveUp()
    }

    func leave() {
        guard let id = held?.id, held?.phase == .pending else { return }
        waiting?.cancel()
        guard float != nil else { return clear() }
        withAnimation(Motion.fade) { held?.phase = .leaving } completion: {
            if self.held?.id == id, self.held?.phase == .leaving { self.clear() }
        }
    }

    private func giveUp() {
        if placed != nil { withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { placed = nil } }
        settle()
    }

    func takeoff(_ moved: [TaskBoard.Flight: TaskBoard.Column], lands: (TaskBoard.Flight) -> TaskBoard.Column?) -> (id: TaskBoard.Flight, frame: CGRect)? {
        guard let held, held.phase == .pending, moved[held.id] != nil else { return nil }
        guard float != nil, !reduceMotion, let column = lands(held.id) else {
            let frame = hand
            clear()
            return frame.map { (held.id, $0) }
        }
        waiting?.cancel()
        self.held?.phase = .landing
        self.held?.lane = column
        waiting = Task {
            for _ in 0..<Self.patience where self.held?.home == nil {
                await NextFrame.wait()
                if Task.isCancelled { return }
                land()
            }
            if self.held?.home == nil { clear() }
        }
        return (held.id, CGRect(x: point.x - held.size.width / 2, y: point.y - held.size.height / 2, width: held.size.width, height: held.size.height))
    }

    func land() {
        guard let held, held.phase == .landing, laid(of: held.id)?.lane == held.lane, let home = frame(of: held.id), home != held.home else { return }
        withAnimation(Motion.travel) {
            self.held?.home = home
            point = CGPoint(x: home.midX, y: home.midY)
        } completion: {
            if self.held?.id == held.id, self.held?.phase == .landing, self.held?.home == home { self.clear() }
        }
    }

    private func clear() {
        waiting?.cancel()
        held = nil
        float = nil
        hand = nil
        aimed = nil
        if over != nil { over = nil }
        if slot != nil { slot = nil }
        if pull != nil { pull = nil }
    }
}
