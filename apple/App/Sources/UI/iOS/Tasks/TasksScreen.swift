#if os(iOS)
import CueStore
import SwiftUI

/// 任务页：流水看板（`TaskBoard`），待办 → 推进中 → 等你 → 已完成（今天）。只看项目范围里的（`Workspace.scopedProject`，同会话页那一份；
/// 选了项目以后卡上不画项目小图形、列头的数也只数这个项目），页里不另设筛选；项目范围在顶栏中间（`ProjectScope`）。
/// 宽屏（iPad）同 Mac 四列并排（`BoardColumns`）；窄屏是四行竖排、每行横划的竖版看板（`PhoneBoard`），四行一打开都在眼前，不另设落点。
/// 右上角"+"去待办、顶上浮出添加那一行（`NewTaskLine`，落在范围里的项目或当前项目，可换），失焦且没写字时收回。
struct TasksScreen: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var board: TaskBoard?
    @State private var adding = false

    var body: some View {
        let shown = (board ?? .empty).only(workspace.scopedProject)
        Group {
            if sizeClass == .regular {
                BoardColumns(board: shown, adding: $adding, newTaskProject: newTaskProject).padding(.horizontal, 12)
            } else {
                PhoneBoard(board: shown, adding: $adding, newTaskProject: newTaskProject)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 顶上不写页名（侧栏、底部那一排的选中格已经说了在哪一页），中间是项目范围
        .floatingHeader("任务", center: { ProjectScope().headerPiece() }) {
            Button("添加任务", icon: .add) { add() }
        }
        .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion), value: adding)
        .onChange(of: workspace.scopedProject) { adding = false }
        .observingBoard(into: $board, store: services.store, onError: workspace.fail)
    }

    private var newTaskProject: UUID? { workspace.scopedProject ?? workspace.currentProject }

    /// 待办顶上浮出添加那一行（手机看板先把待办那一行滑到行首，`BoardRowLane`）。
    private func add() { adding = true }
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
            if let projects {
                Menu {
                    ForEach(projects) { item in Button(item.name) { chosen = item.id } }
                } label: {
                    DestinationChip(project: current).frame(minHeight: 44).contentShape(.rect).menuLabel("记到 \(current?.name ?? "")")
                }
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
