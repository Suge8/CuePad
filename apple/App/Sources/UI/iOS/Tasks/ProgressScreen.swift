#if os(iOS)
import CueStore
import SwiftUI

/// 进展页（iPhone 底部那一排与 iPad 侧栏的"进展"）：看板与会话两段，看哪一段只有 `Workspace.progressPane` 一份
/// （项目页"⋯"的"看这个项目的会话"经 `showSessions` 换到会话段）。两段只看项目范围里的（`Workspace.scopedProject`）。
/// 顶栏中间一块玻璃（`ProgressHeader`）：两段的分段、项目范围、额度环；右上角随段是"添加任务"或"新会话"。
/// 看板一段是流水看板（`TaskBoard`），待办 → 推进中 → 等你 → 已完成（今天）；选了项目以后卡上不画项目小图形、列头的数也只数这个项目。
/// 宽屏（iPad）同 Mac 四列并排（`BoardColumns`）；窄屏是四行竖排、每行横划的竖版看板（`PhoneBoard`），四行一打开都在眼前，不另设落点。
/// "添加任务"去待办、顶上浮出添加那一行（`NewTaskLine`，落在范围里的项目或当前项目，可换），失焦且没写字时收回。
/// 会话一段是全部会话（`SessionList`）：在线的在上、历史在下；搜会话在搜索页，这里不另放搜索框。
struct ProgressScreen: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var board: TaskBoard?
    @State private var adding = false
    @State private var sessions = AgentListModel()
    /// 去过的段：一直挂着，换段只换哪一段看得见（同 Mac 的 `ProgressPage`），不重建整块看板或会话列表。
    @State private var mounted: Set<ProgressPane> = []
    @Environment(\.pageActive) private var active

    var body: some View {
        let pane = workspace.progressPane
        ZStack(alignment: .top) {
            if mounted.contains(.board) || pane == .board { shown(.board, pane) { boardView } }
            if mounted.contains(.sessions) || pane == .sessions {
                shown(.sessions, pane) { SessionList(model: sessions, filter: workspace.scopedProject) }
            }
        }
        .onChange(of: pane, initial: true) { mounted.insert(pane) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 顶上不写页名（侧栏、底部那一排的选中格已经说了在哪一页）
        .floatingHeader("进展", center: { ProgressHeader() }) {
            if workspace.progressPane == .sessions {
                NewSessionButton(project: workspace.scopedProject)
            } else {
                Button("添加任务", icon: .add) { add() }
            }
        }
        .refreshesQuota()
        .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion), value: adding)
        .onChange(of: workspace.scopedProject) { adding = false }
        .observingBoard(into: $board, store: services.store, onError: workspace.fail)
    }

    @ViewBuilder private var boardView: some View {
        let shown = (board ?? .empty).only(workspace.scopedProject)
        if sizeClass == .regular {
            BoardColumns(board: shown, adding: $adding, newTaskProject: newTaskProject).padding(.horizontal, 12)
        } else {
            PhoneBoard(board: shown, adding: $adding, newTaskProject: newTaskProject)
        }
    }

    /// 看不见的那段：点不到、屏读跳过，暂停订阅（`pageActive`）。
    private func shown(_ pane: ProgressPane, _ current: ProgressPane, @ViewBuilder content: () -> some View) -> some View {
        let on = pane == current
        return content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .opacity(on ? 1 : 0)
            .allowsHitTesting(on)
            .accessibilityHidden(!on)
            .environment(\.pageActive, active && on)
    }

    private var newTaskProject: UUID? { workspace.scopedProject ?? workspace.currentProject }

    /// 待办顶上浮出添加那一行（手机看板先把待办那一行滑到行首，`BoardRowLane`）。
    private func add() { adding = true }
}

/// 进展页顶栏中间那一块玻璃：左边看板｜会话两颗图标（`ProgressPanes`），中间项目范围，右边额度环；点环从这一块长出额度明细（`GrowPanel`）。
/// 三样并成一块：各占一块玻璃时 iPhone 两侧圆钮之间挤不下，也读成三件事；它们说的都是"这一页看什么"。
private struct ProgressHeader: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var open = DebugHooks.preset.quotaOpen
    private static let pane: CGFloat = 38

    var body: some View {
        GrowPanel(open: $open, radius: FloatingHeaderLayout.height / 2) {
            HStack(spacing: 0) {
                ProgressPanes(size: Self.pane).padding(.leading, 3)
                ProjectScope()
                QuotaRings(open: open, height: FloatingHeaderLayout.height) { $open.grow(reduceMotion: reduceMotion) }
            }
        } panel: {
            QuotaDetail().padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 18)
        }
    }
}

/// 一行新建任务：↩ 添加并保持焦点，便于连续输入。给了 `projects` 时尾部可选挂到哪个项目。
/// 给了 `dismiss`（进展页右上角"+"浮出的那一行）：出现即聚焦，失焦时没写字就收回。
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
