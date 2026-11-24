import CueStore
import SwiftUI

struct BoardColumn: View {
    let column: TaskBoard.Column
    let board: TaskBoard
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
    @State private var listsEarlier = false
    #endif

    var body: some View {
        lane
            #if os(iOS)
            .sheet(isPresented: $listsEarlier) { earlierList }
            #endif
            .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: column == .todo ? moves?.making : nil)
            // 量在垫底的一层上：直接挂在这一列上，手机的行交给 `BoardRows` 的排版值（`BoardRowFlex`）就传不出去（实测）
            .background { Color.clear.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(BoardMoves.space)) } action: { moves?.areas[column] = $0 } }
            // 一列只这一个落点：卡上不另挂（里外两层互相抢，底时有时无）。不接的卡（`accepts`）拖过来不亮，放下也不动
            .cardDrop(isEnabled: drags?.current.map(accepts) == true, hover: { point in
                if let point, let card = drags?.current, let flight = drags?.flight {
                    moves?.hover(card, flight: flight, at: point, in: column, on: board, row: isRow)
                } else {
                    moves?.leave(column)
                }
            }) { card, point in
                // 另一根手指正拎着一张时这一下不进拖动的状态，照样办：系统已经当它接下了，不能放下了没动静
                let drop = drags?.flight.flatMap { moves?.drop(card, flight: $0, at: point, in: column, on: board, row: isRow, face: face) }
                if let drop = drop ?? board.drop(card, into: column, at: nil) { workspace.drop(drop) }
            }
            #if os(iOS)
            .background { lift }
            #endif
            .modifier(ShotPresenter(column: column, opened: $opened))
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
            BoardRowLane(column: column, count: board.count(column), archives: archives, targeted: lit) { content }
        } else {
            columnLane
        }
        #else
        columnLane
        #endif
    }

    private var columnLane: some View {
        #if os(macOS)
        ScrollView { cards }
            .scrollBounceBehavior(.basedOnSize)
            .scrollClipDisabled()
            .modifier(LaneAnchor(column))
            .boardLane(column)
            .boardTopRow(column: column, count: board.count(column), archives: archives, targeted: lit)
        #else
        ScrollView { cards }
            .scrollBounceBehavior(.basedOnSize)
            .scrollClipDisabled()
            .modifier(LaneAnchor(column))
            .boardLane(column)
            .safeAreaPadding(.top, BoardColumnHeader.height + BoardCardMetrics.inset)
            .overlay(alignment: .top) {
                BoardColumnHeader(column: column, count: board.count(column), archives: archives)
                    .padding(.horizontal, TaskMetrics.cardPadding)
                    .glass(in: .capsule)
                    .padding([.horizontal, .top], BoardCardMetrics.inset)
            }
            .background { BoardLane(targeted: lit) }
        #endif
    }

    private var archives: Bool { column == .done && !(board.done.isEmpty && board.earlier.isEmpty) }

    private var lit: Bool { moves?.over == column }

    private func accepts(_ card: DraggedCard) -> Bool { board.drop(card, into: column, at: nil) != nil }

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
            ForEach(todoCells) { cell in
                switch cell {
                case .card(let item): card(item).boardDraggable(.task(item.id), flight: item.flight, session: item.agent?.state.sessionID)
                case .well(let height): BoardWell().frame(height: isRow ? nil : height).boardFlight(.well)
                }
            }
            if board.todo.isEmpty { empty("没有待办") }
        case .advancing:
            // 一个 ForEach 排完各档：卡换档是同一串里换位（让位），不是这一档删一张、那一档添一张（同一个飞行身份一删一添会从栈顶飞过来）
            ForEach(AdvancingSlot.slots(workspace.byAttention(board.advancing), gaps: !isRow)) { slot in
                switch slot {
                case .gap:
                    Color.clear.frame(height: 0)
                case .work(let work, let moves):
                    if let item = work.item {
                        card(item, flight: work.id, moves: moves).boardDraggable(.task(item.id), flight: work.id, session: item.agent?.state.sessionID)
                    } else if let agent = work.loose {
                        let session = agent.state.sessionID
                        sessionFace(agent, of: work, moves: moves).boardDraggable(.session(session), flight: work.id, session: session).boardFlight(work.id).benchSpot(work.id)
                    }
                }
            }
            if board.advancing.isEmpty { empty("拖一件待办到这里开始") }
        case .waiting:
            ForEach(board.held) { held in
                let session = held.session.sessionID
                waitFace(held).boardFlight(held.id).benchSpot(held.id)
                    .boardDraggable(held.item.map { .task($0.id) } ?? .session(session), flight: held.id, session: session)
            }
            if board.count(.waiting) == 0 { empty("没有等你的事") }
        case .done:
            ForEach(board.done) { card($0) }
            if board.done.isEmpty && board.earlier.isEmpty { empty("今天还没做完的") }
            if !board.earlier.isEmpty {
                if earlier.wrappedValue { earlierToggle } else { BoardPile(count: board.earlier.count, action: toggleEarlier) }
            }
            if earlier.wrappedValue { ForEach(board.earlier) { card($0) } }
        }
    }

    private func card(_ item: TaskBoard.Item, flight: TaskBoard.Flight? = nil, moves: Bool = false) -> some View {
        taskFace(item, in: column, moves: moves).boardFlight(flight ?? item.flight).benchSpot(item.id)
    }

    private func taskFace(_ item: TaskBoard.Item, in column: TaskBoard.Column, moves: Bool) -> some View {
        BoardTaskCard(item: item, column: column, project: glyph(item.project), moves: moves) { opened = $0 }.boardDim(project: item.task.projectID)
    }

    private func sessionFace(_ agent: SessionListItem, of work: TaskBoard.Work, moves: Bool) -> some View {
        BoardSessionCard(agent: agent, project: glyph(workspace.catalog?.project(work.project)), moves: moves).boardDim(project: work.project)
    }

    private func waitFace(_ held: TaskBoard.Held) -> some View {
        BoardWaitCard(held: held, project: glyph(workspace.catalog?.project(held.project)))
    }

    private func face(_ flight: TaskBoard.Flight) -> AnyView? {
        if let item = board.todo.first(where: { $0.flight == flight }) { return AnyView(taskFace(item, in: .todo, moves: false)) }
        if let work = board.advancing.first(where: { $0.id == flight }) {
            return work.item.map { AnyView(taskFace($0, in: .advancing, moves: false)) } ?? work.loose.map { AnyView(sessionFace($0, of: work, moves: false)) }
        }
        return board.held.first { $0.id == flight }.map { AnyView(waitFace($0)) }
    }

    private func glyph(_ project: Project?) -> Project? { workspace.scopedProject == nil ? project : nil }

    @ViewBuilder private func empty(_ text: LocalizedStringResource) -> some View {
        if !isRow, let add = LaneAdd.of(column, in: workspace) {
            Button(action: add.action) {
                vacancy(text) { Label(add.title, icon: .add).font(Typography.secondaryBold).foregroundStyle(palette.ink2) }
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
            .background(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(palette.hair, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }

    private func toggleEarlier() {
        #if os(iOS)
        if row { listsEarlier = true; return }
        #endif
        withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { earlier.wrappedValue.toggle() }
    }

    private var earlierToggle: some View {
        HStack(spacing: Spacing.group) {
            Button(action: toggleEarlier) {
                HStack(spacing: Spacing.tight) {
                    Text("更早做完的 \(board.earlier.count)")
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
                Text("更早做完的 \(board.earlier.count)").font(Typography.bodyStrong)
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

    enum Key: Hashable {
        case gap(pinned: Bool, BoardPulse.Tier)
        case work(TaskBoard.Flight)
    }

    var id: Key {
        switch self {
        case .gap(let pinned, let tier): .gap(pinned: pinned, tier)
        case .work(let work, _): .work(work.id)
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

private struct BoardPile: View {
    let count: Int
    let action: () -> Void
    @Environment(\.boardRow) private var row
    @Environment(\.palette) private var palette

    private static let step = Spacing.glyph
    private static let inset = Spacing.group

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.item) {
                Text("更早做完的 \(count)").lineLimit(1)
                Spacer(minLength: 0)
                Chevron(.forward)
            }
            .font(TaskMetrics.lineFont).emphasis(TaskBoard.Column.done.titleWeight).foregroundStyle(TaskBoard.Column.done.titleInk(palette))
            .padding(.vertical, BoardCardMetrics.compactPad)
            .boardCard(.done)
            .background {
                ForEach([2, 1], id: \.self) { depth in
                    RoundedRectangle(cornerRadius: Radius.card).fill(palette.paperFill).opacity(depth == 1 ? 0.7 : 0.4)
                        .padding(.horizontal, CGFloat(depth) * Self.inset).offset(y: CGFloat(depth) * Self.step)
                }
            }
            .padding(.bottom, row ? 0 : 2 * Self.step)
        }
        .buttonStyle(PressStyle(.card))
        .accessibilityValue("已折叠")
    }
}
