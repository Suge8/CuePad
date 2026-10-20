#if os(iOS)
import CueStore
import SwiftUI

/// 任务页（iPhone 底部一排的"任务"、宽屏侧栏的"任务"）：流水看板（`TaskBoard`），待办 → 在管 → 等你 → 做完（今天）。
/// 宽屏（iPad）同 Mac 四列并排（`BoardColumns`），顶上不写页名，第一排是按项目筛的胶囊（`Header`）。窄屏一屏一列：顶上一排带数的分段（`BoardSegments`），左右滑换列（分页滚动），
/// 点分段滑过去；打开时有等你就落在等你。分段下面一行"全部项目"菜单按项目筛（筛了以后分段的数也只数这个项目）。
/// 右上角"+"去待办、顶上浮出添加那一行（`NewTaskLine`，落在筛的项目或当前项目，可换），失焦且没写字时收回。
struct TasksScreen: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var board: TaskBoard?
    @State private var project: UUID?
    @State private var adding = false
    /// 窄屏此刻看的那一列（分页滚动的位置）。
    @State private var column: TaskBoard.Column?

    var body: some View {
        let whole = board ?? .empty
        let shown = whole.only(project)
        Group {
            if sizeClass == .regular {
                VStack(alignment: .leading, spacing: 14) {
                    BoardProjectChips(projects: whole.projects(in: workspace.catalog), selected: $project).padding(.horizontal, 16)
                    BoardColumns(board: shown, adding: $adding, newTaskProject: newTaskProject).padding(.horizontal, 12)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    BoardSegments(board: shown, selected: $column).padding(.horizontal, 16)
                    filterMenu(whole).padding(.horizontal, 16)
                    pages(shown)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .modifier(Header(wide: sizeClass == .regular) {
            Button("添加任务", icon: .add) { add() }
        })
        .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion), value: adding)
        .onChange(of: project) { adding = false }
        .onAppear { if let board { land(board) } }
        .onChange(of: board == nil) { if let board { land(board) } }
        .observingBoard(into: $board, store: services.store, onError: workspace.fail)
    }

    private var newTaskProject: UUID? { project ?? navigation.currentProject }

    /// 一屏一列，左右滑换列：列的宽就是可见宽（`containerRelativeFrame`），按页停。
    private func pages(_ board: TaskBoard) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 0) {
                ForEach(TaskBoard.Column.allCases) { column in
                    BoardColumn(column: column, board: board, adding: $adding, newTaskProject: newTaskProject)
                        .padding(.horizontal, 12)
                        .containerRelativeFrame(.horizontal)
                        .id(column)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $column)
        .scrollIndicators(.never)
    }

    /// "全部项目"：按项目筛，只列看板上有事的项目。
    private func filterMenu(_ whole: TaskBoard) -> some View {
        let current = workspace.catalog?.project(project)
        return Menu {
            Picker("按项目看", selection: $project) {
                Label("全部项目", icon: .all).tag(UUID?.none)
                ForEach(whole.projects(in: workspace.catalog)) { item in
                    Label { Text(item.name) } icon: { ProjectGlyph(project: item) }.tag(Optional(item.id))
                }
            }
        } label: {
            HStack(spacing: 5) {
                if let current { ProjectGlyph(project: current, size: 13) }
                Text(current?.name ?? "全部项目").lineLimit(1)
                Image(.expand).font(.caption.weight(.semibold)).accessibilityHidden(true)
            }
            .font(.subheadline).foregroundStyle(palette.ink2)
            .padding(.horizontal, 12).frame(minHeight: 36)
            .background(palette.fill, in: .capsule)
            .contentShape(.capsule)
        }
        .accessibilityLabel(current.map { "按项目看：\($0.name)" } ?? "按项目看")
    }

    /// 打开时落在哪一列：有等你就是等你（要你拍板的事在那里就能处理），否则在管、再否则待办。
    private func land(_ board: TaskBoard) {
        column = !board.waiting.isEmpty ? .waiting : !board.managing.isEmpty ? .managing : .todo
    }

    /// 先滑到待办、停稳了再浮出添加那一行：滑动途中插进来的输入框接不住焦点（实测会空着不聚焦）。
    private func add() {
        guard column != .todo else { return adding = true }
        withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { column = .todo } completion: { adding = true }
    }
}

/// 任务页顶上那一排，不写页名（侧栏、底部那一排的选中格已经说了在哪一页）：窄屏同另两页的根（`floatingHeader`）；
/// 宽屏导航栏里只有侧栏开关与右边的"+"，按项目筛的胶囊是内容的第一排。胶囊不进导航栏：横滑的一排放进工具栏项量不出宽，只剩第一颗。
private struct Header<Add: View>: ViewModifier {
    let wide: Bool
    @ViewBuilder let add: Add

    func body(content: Content) -> some View {
        if wide {
            content
                .navigationTitle("任务")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(removing: .title)
                .toolbar { ToolbarItem(placement: .primaryAction) { add } }
        } else {
            content.floatingHeader("任务") { add }
        }
    }
}

/// 窄屏任务页顶上的分段：四列各一格，写状态图形、列名与数；选中的那格是靛青浅底（`selection`）。点了滑到那一列。
private struct BoardSegments: View {
    let board: TaskBoard
    @Binding var selected: TaskBoard.Column?
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TaskBoard.Column.allCases) { column in
                let on = selected == column
                Button {
                    withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { selected = column }
                } label: {
                    HStack(spacing: 4) {
                        if column == .waiting, board.count(column) > 0 { BoardColumnGlyph(column: column, size: 12) }
                        Text(column.title).fontWeight(on ? .semibold : .regular)
                        Text("\(board.count(column))").monospacedDigit().foregroundStyle(palette.ink3)
                    }
                    .font(.subheadline).foregroundStyle(on ? palette.ink : palette.ink2)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(on ? palette.selection : .clear, in: .capsule)
                    .contentShape(.capsule)
                }
                .buttonStyle(PressStyle())
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .glass(in: .capsule)
    }
}

/// 一行新建任务：↩ 添加并保持焦点，便于连续输入。给了 `projects` 时尾部可选挂到哪个项目。
/// 给了 `dismiss`（任务页右上角"+"浮出的那一行）：出现即聚焦，失焦时没写字就收回。
struct NewTaskLine: View {
    let project: UUID?
    var projects: [Project]?
    var dismiss: (() -> Void)?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var text = ""
    @State private var chosen: UUID?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 2) {
            // 入口不用系统占位灰：那样看起来像不能点
            Image(.add).foregroundStyle(palette.ink2).frame(width: 44).accessibilityHidden(true)
            TextField("添加任务", text: $text, palette: palette)
                .accessibilityLabel("添加任务")
                .frame(minHeight: 44)
                .contentShape(.rect)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(add)
                .onAppear { if dismiss != nil { focused = true } }
                .onChange(of: focused) { if !focused, text.trimmingCharacters(in: .whitespaces).isEmpty { dismiss?() } }
            if let projects, !projects.isEmpty {
                Menu {
                    ForEach(projects) { item in Button(item.name) { chosen = item.id } }
                } label: {
                    DestinationChip(project: current).frame(minHeight: 44).contentShape(.rect)
                }
                .accessibilityLabel("记到 \(current?.name ?? "")")
            }
        }
    }

    /// 落到哪个项目：换过的，没换过是给的项目，都没有（不在项目里）是默认项目。
    private var target: UUID { chosen ?? project ?? Project.defaultID }
    private var current: Project? { projects?.first { $0.id == target } }

    private func add() {
        let content = text.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return }
        text = ""
        focused = true
        let project = target
        workspace.attempt { _ = try await workspace.createTask(content, in: project) }
    }
}
#endif
