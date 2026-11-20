import CueStore
import SwiftUI

/// 已完成列末尾的"更早做完的 N"：它们没进归档，跳去归档页看到的是别的，所以就在看板上看——四列并排时原地展开，手机的行里另出一页竖着列。
struct BoardColumn: View {
    let column: TaskBoard.Column
    let board: TaskBoard
    @Binding var adding: Bool
    let newTaskProject: UUID?
    /// 已完成列末尾"更早做完的"原地展开着：由 `BoardColumns` 持有（它展开了已完成就不是空列，列宽跟着变）；手机的行不原地展开（`listsEarlier`）。
    var earlier: Binding<Bool> = .constant(false)
    #if os(iOS)
    var row = false
    #endif
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.boardMoves) private var moves
    @Environment(\.cardDrags) private var drags
    @Environment(\.pageActive) private var active
    @State private var opened: PreviewOpening?
    #if os(iOS)
    /// 手机那一行是横着滑的，更早做完的几百条排不进去：点了另出一页竖着列。
    @State private var listsEarlier = false
    #endif

    var body: some View {
        lane
            #if os(iOS)
            .sheet(isPresented: $listsEarlier) { earlierList }
            #endif
            // 待办里拖着的卡指到哪，空位挪到哪、别的卡让开（`BoardDrag`）
            .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: column == .todo ? moves?.making : nil)
            // 量在垫底的一层上：直接挂在这一列上，手机的行交给 `BoardRows` 的排版值（`BoardRowFlex`）就传不出去（实测）
            .background { Color.clear.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(BoardMoves.space)) } action: { moves?.areas[column] = $0 } }
            // 一列只这一个落点：卡上不另挂（里外两层互相抢，底时有时无）。不接的卡（`accepts`）拖过来不亮，放下也不动
            .cardDrop(isEnabled: drags?.current.map(accepts) == true, hover: { point in
                if let point, let card = drags?.current { moves?.hover(card, at: point, in: column, on: board, row: isRow) } else { moves?.leave(column) }
            }) { card, point in
                // 另一根手指正拎着一张时这一下不进拖动的状态，照样办：系统已经当它接下了，不能放下了没动静
                if let drop = moves?.drop(card, at: point, in: column, on: board, row: isRow) ?? board.drop(card, into: column, at: nil) { workspace.drop(drop) }
            }
            #if os(iOS)
            .background { lift }
            #endif
            .modifier(ShotPresenter(column: column, opened: $opened))
            // 有卡飞进来的那一列（行）排在别的列上面：往左、往上飞的卡不从别的列的卡下面钻过去（`boardFlight`）
            .zIndex(moves?.lands(in: board.flights(column)) == true ? 1 : 0)
    }

    #if os(iOS)
    private var lift: BoardLift {
        let cards = board.draggables(column)
        func stage(_ point: CGPoint) -> CGPoint { moves.map { CGPoint(x: point.x - $0.origin.x, y: point.y - $0.origin.y) } ?? point }
        return BoardLift(enabled: active, hits: { moves?.card(at: stage($0), among: cards) != nil }, began: { point in
            guard let moves, let hit = moves.card(at: stage(point), among: cards), let face = face(hit.flight) else { return false }
            return moves.lift(hit.card, id: hit.flight, at: stage(point), face: face, row: row)
        }, moved: { moves?.drag(to: stage($0), on: board, row: row) }, ended: { released in
            if !released { moves?.cancel() } else if let drop = moves?.release(on: board) { workspace.drop(drop) }
        })
    }
    #endif

    @ViewBuilder private var lane: some View {
        #if os(iOS)
        if row {
            BoardRowLane(column: column, count: board.count(column), archives: archives, targeted: lit, rewind: rewind) {
                if adding && column == .todo { newTask.transition(.opacity) }
            } content: {
                content
            }
        } else {
            columnLane
        }
        #else
        columnLane
        #endif
    }

    /// 列头浮在卡上，卡从它后面滚过，不在它下沿裁掉。
    private var columnLane: some View {
        #if os(macOS)
        ScrollView { cards }
            .scrollBounceBehavior(.basedOnSize)
            .scrollClipDisabled()
            .modifier(LaneAnchor(column, rewind: rewind))
            .boardLane(column)
            .boardTopRow(column: column, count: board.count(column), archives: archives, targeted: lit)
        #else
        ScrollView { cards }
            .scrollBounceBehavior(.basedOnSize)
            .scrollClipDisabled()
            .modifier(LaneAnchor(column, rewind: rewind))
            .boardLane(column)
            .safeAreaPadding(.top, BoardColumnHeader.height + BoardCardMetrics.inset)
            .overlay(alignment: .top) {
                BoardColumnHeader(column: column, count: board.count(column), archives: archives)
                    .padding(.horizontal, TaskMetrics.cardPadding)
                    .glass(in: .rect(cornerRadius: TaskMetrics.cardRadius))
                    .padding([.horizontal, .top], BoardCardMetrics.inset)
            }
            .background { BoardLane(targeted: lit) }
        #endif
    }

    private var archives: Bool { column == .done && !(board.done.isEmpty && board.earlier.isEmpty) }

    /// 打开添加任务时待办回到开头（行滑到首格，列滚回顶）：添加那一行在待办最前，滚过的列要把它带进视野。
    private var rewind: UUID? { adding && column == .todo ? board.todo.first?.id : nil }

    /// 接得住的卡拖到这一列上就亮。
    private var lit: Bool { moves?.over == column }

    private func accepts(_ card: DraggedCard) -> Bool { board.drop(card, into: column, at: nil) != nil }

    /// 待办排出来的各格：拖着的卡的空位在它指着的那一处（`BoardMoves.making`），不在它库里的位置。
    /// 从推进中拖回来的卡在待办里没有格，另垫一格空位。
    private enum TodoCell: Identifiable {
        case card(TaskBoard.Item)
        case well(CGFloat)

        private static let well = UUID()

        var id: UUID {
            switch self {
            case .card(let item): item.id
            case .well: Self.well
            }
        }
    }

    private var todoCells: [TodoCell] {
        guard let making = moves?.making else { return board.todo.map(TodoCell.card) }
        let home = board.todo.firstIndex { $0.id == making.task }
        var cells = board.todo.filter { $0.id != making.task }.map(TodoCell.card)
        let index = home.map { making.slot <= $0 ? making.slot : making.slot - 1 } ?? making.slot
        cells.insert(home.map { .card(board.todo[$0]) } ?? .well(moves?.held?.size.height ?? 0), at: min(index, cells.count))
        return cells
    }

    private var isRow: Bool {
        #if os(iOS)
        row
        #else
        false
        #endif
    }

    private var cards: some View {
        LazyVStack(alignment: .leading, spacing: BoardCardMetrics.gap) { content }
            .scrollTargetLayout()
            .padding(.horizontal, BoardCardMetrics.inset).padding(.vertical, BoardCardMetrics.inset).padding(.bottom, Spacing.section)
    }

    @ViewBuilder private var content: some View {
        switch column {
        case .todo:
            if adding, !isRow {
                newTask.transition(.opacity)
            }
            ForEach(todoCells) { cell in
                switch cell {
                case .card(let item): card(item).boardDraggable(item.id, session: item.agent?.state.sessionID)
                case .well(let height): BoardWell().frame(height: isRow ? nil : height).boardFlight(BoardMoves.well)
                }
            }
            if board.todo.isEmpty && !adding { empty("没有待办") }
        case .advancing:
            // 一个 ForEach 排完各档：卡换档是同一串里换位（让位），不是这一档删一张、那一档添一张（同一个飞行身份一删一添会从栈顶飞过来）
            ForEach(AdvancingSlot.slots(workspace.byAttention(board.advancing), gaps: !isRow)) { slot in
                switch slot {
                case .gap:
                    // 档与档之间多空一截：栈里一格零高的空，前后各一个行距（横着的一行里一格就是一张卡宽，不空）
                    Color.clear.frame(height: 0)
                case .work(let work, let moves):
                    if let item = work.item {
                        card(item, moves: moves).boardDraggable(item.id, session: item.agent?.state.sessionID)
                    } else if let agent = work.loose {
                        sessionFace(agent, of: work, moves: moves).boardDraggable(session: agent.state.sessionID).boardFlight(work.id).benchSpot(work.id)
                    }
                }
            }
            if board.advancing.isEmpty { empty("拖一件待办到这里开始") }
        case .waiting:
            ForEach(board.held) { held in
                let card = waitFace(held).boardFlight(held.id).benchSpot(held.id)
                if let item = held.item { card.boardDraggable(item.id, session: held.session.sessionID) } else { card.boardDraggable(session: held.session.sessionID) }
            }
            if board.count(.waiting) == 0 { empty("没有等你的事") }
        case .done:
            ForEach(board.done) { card($0) }
            // 列头的数只数今天的。今天没有、更早的有时只摆那一叠：再垫一个"今天还没做完的"空框，一列里两样都是空的
            if board.done.isEmpty && board.earlier.isEmpty { empty("今天还没做完的") }
            if !board.earlier.isEmpty {
                if earlier.wrappedValue { earlierToggle } else { BoardPile(count: board.earlier.count, action: toggleEarlier) }
            }
            if earlier.wrappedValue { ForEach(board.earlier) { card($0) } }
        }
    }

    private func card(_ item: TaskBoard.Item, moves: Bool = false) -> some View {
        taskFace(item, moves: moves).boardFlight(item.flight).benchSpot(item.id)
    }

    private func taskFace(_ item: TaskBoard.Item, moves: Bool) -> some View {
        BoardTaskCard(item: item, column: column, project: glyph(item.project), moves: moves) { opened = $0 }.boardDim(project: item.task.projectID)
    }

    private func sessionFace(_ agent: SessionListItem, of work: TaskBoard.Work, moves: Bool) -> some View {
        BoardSessionCard(agent: agent, project: glyph(workspace.catalog?.project(work.project)), moves: moves).boardDim(project: work.project)
    }

    private func waitFace(_ held: TaskBoard.Held) -> some View {
        BoardWaitCard(held: held, project: glyph(workspace.catalog?.project(held.project)))
    }

    #if os(iOS)
    /// 这一列里那张卡的面：按住拎起来时浮在手里的就是它，不带原处那张的飞行身份。
    private func face(_ flight: String) -> AnyView? {
        switch column {
        case .todo: board.todo.first { $0.flight == flight }.map { AnyView(taskFace($0, moves: false)) }
        case .advancing:
            board.advancing.first { $0.id == flight }.flatMap { work in
                work.item.map { AnyView(taskFace($0, moves: false)) } ?? work.loose.map { AnyView(sessionFace($0, of: work, moves: false)) }
            }
        case .waiting: board.held.first { $0.id == flight }.map { AnyView(waitFace($0)) }
        case .done: nil
        }
    }
    #endif

    private func glyph(_ project: Project?) -> Project? { workspace.scopedProject == nil ? project : nil }

    private var newTask: some View {
        NewTaskField(project: newTaskProject, choosesProject: true, stacked: !isRow, autofocus: true) { adding = false }
            .padding(.horizontal, isRow ? Spacing.tight : TaskMetrics.cardPadding)
            .paper(cornerRadius: TaskMetrics.cardRadius, lifted: !isRow)
    }

    /// 能添东西的列空着时，这一格就是添加的入口（列头那颗"+"的同一个动作）；手机的行里添加在行头上，这一格只是说明。
    @ViewBuilder private func empty(_ text: LocalizedStringResource) -> some View {
        if !isRow, let add = LaneAdd.of(column, in: workspace) {
            Button(action: add.action) {
                vacancy(text) { Label(add.title, icon: .add).font(Typography.secondary.weight(.semibold)).foregroundStyle(palette.ink2) }
                    .contentShape(.rect)
            }
            .buttonStyle(PressStyle(.card))
        } else {
            vacancy(text) { EmptyView() }
        }
    }

    private func vacancy(_ text: LocalizedStringResource, @ViewBuilder lead: () -> some View) -> some View {
        VStack(spacing: Spacing.tight) {
            lead()
            Text(text).font(Typography.secondary).foregroundStyle(palette.ink3).multilineTextAlignment(.center)
        }
            .padding(.horizontal, BoardCardMetrics.inset)
            .frame(maxWidth: .infinity, minHeight: isRow ? nil : 64, maxHeight: isRow ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: TaskMetrics.cardRadius).strokeBorder(palette.hair, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }

    /// 列里原地摊开、收回；手机的行另出一页（`listsEarlier`）。
    private func toggleEarlier() {
        #if os(iOS)
        if row { listsEarlier = true; return }
        #endif
        withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { earlier.wrappedValue.toggle() }
    }

    /// 摊开后留在那一叠原来的位置：点它收回去。
    private var earlierToggle: some View {
        HStack(spacing: Spacing.group) {
            Button(action: toggleEarlier) {
                HStack(spacing: Spacing.tight) {
                    Text("更早做完的 \(board.earlier.count)").monospacedDigit()
                    Chevron(.forward).rotationEffect(.degrees(earlier.wrappedValue ? 90 : 0))
                }
                .frame(minHeight: TaskMetrics.chipTarget).contentShape(.rect)
            }
            .buttonStyle(PressStyle())
            .accessibilityValue(earlier.wrappedValue ? "已展开" : "已折叠")
            Spacer(minLength: 0)
        }
        .font(Typography.meta).foregroundStyle(palette.ink3)
        .padding(.horizontal, Spacing.tight)
    }

    #if os(iOS)
    private var earlierList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: BoardCardMetrics.gap) {
                Text("更早做完的 \(board.earlier.count)").font(Typography.bodyStrong).monospacedDigit()
                    .padding(.vertical, Spacing.item)
                ForEach(board.earlier) { card($0) }
            }
            .padding(Spacing.inset)
        }
        .background(palette.desk)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
    #endif
}

private struct ShotPresenter: ViewModifier {
    let column: TaskBoard.Column
    @Binding var opened: PreviewOpening?

    func body(content: Content) -> some View {
        if column == .done { content.previewPresenter($opened, reply: .cue) } else { content }
    }
}

private enum AdvancingSlot: Identifiable {
    case gap(pinned: Bool, BoardPulse.Tier)
    case work(TaskBoard.Work, moves: Bool)

    var id: String {
        switch self {
        case .gap(let pinned, let tier): "gap/\(pinned)/\(tier)"
        case .work(let work, _): work.id
        }
    }

    static func slots(_ groups: [Workspace.Attention], gaps: Bool) -> [AdvancingSlot] {
        groups.enumerated().flatMap { offset, group -> [AdvancingSlot] in
            let gap = gaps && offset > 0 && !(group.pinned && groups[offset - 1].pinned)
            let cards = group.work.enumerated().map { AdvancingSlot.work($1.work, moves: $1.running && $0 < BoardNow.maxMoving) }
            return (gap ? [.gap(pinned: group.pinned, group.tier)] : []) + cards
        }
    }
}

/// 收着的"更早做完的"：一叠卡，面上写着有几件，下面露出两层边；点一下摊开。
/// 否决过：一行小灰字——今天没做完时这一列只剩一个虚线空框加这行字，读成这一列是空的。
private struct BoardPile: View {
    let count: Int
    let action: () -> Void
    @Environment(\.boardRow) private var row
    @Environment(\.palette) private var palette

    /// 下面每一层比上一层矮下去、窄进去多少。
    private static let step = Spacing.glyph
    private static let inset = Spacing.group

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.item) {
                Text("更早做完的 \(count)").monospacedDigit().lineLimit(1)
                Spacer(minLength: 0)
                Chevron(.forward)
            }
            .font(TaskMetrics.lineFont).fontWeight(TaskBoard.Column.done.titleWeight).foregroundStyle(TaskBoard.Column.done.titleInk(palette))
            .padding(.vertical, BoardCardMetrics.compactPad)
            .boardCard(.done)
            .background {
                ForEach([2, 1], id: \.self) { depth in
                    RoundedRectangle(cornerRadius: TaskMetrics.cardRadius).fill(palette.paperFill).opacity(depth == 1 ? 0.7 : 0.4)
                        .padding(.horizontal, CGFloat(depth) * Self.inset).offset(y: CGFloat(depth) * Self.step)
                }
            }
            // 手机的行里面上那张占满一格，两层边露到格子下面（横滑区不裁内容）：格子只有一行高
            .padding(.bottom, row ? 0 : 2 * Self.step)
        }
        .buttonStyle(PressStyle(.card))
        .accessibilityValue("已折叠")
    }
}
