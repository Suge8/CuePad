#if os(iOS)
import CueStore
import SwiftUI

/// 进展页（窄屏侧栏与宽屏主区的"进展"）：只有看板，只看项目范围里的（`Workspace.scopedProject`）。会话不在这里：在跑、等你的在会话条上，
/// 已结束的在"更早"（窄屏 Cue 页会话条底下那一格推入，宽屏会话条里展开）。
/// 窄屏那一排是侧栏的（`NarrowSidebarBar`：左边项目范围，右边额度）；宽屏页顶中间一块玻璃（`ProgressHeader`）：项目范围与额度环。
/// 添加任务是待办头上的"+"、新会话是推进中头上的"+"（`LaneAdd`：竖版看板的行头、四列的列头），页顶不另放新会话。
/// 看板是流水看板（`TaskBoard`），待办 → 推进中 → 等你 → 已完成（今天）；选了项目以后卡上不画项目小图形、列头的数也只数这个项目。
/// 宽屏（iPad）主栏放得下看板最窄宽（`WideMetrics.board`，`boardFits`）与 iPhone 横屏同 Mac 四列并排（`BoardColumns`）；放不下的主栏（iPad 竖屏、
/// 11 寸横屏旁边开着 Cue 或会话）与窄屏竖着拿是四行竖排、每行横划的竖版看板（`PhoneBoard`），四行一打开都在眼前，不另设落点：
/// 四列压到最窄的 160 时，iPad 的字号下卡上一行只剩两三个字。
/// 横屏的屏高减去顶栏只剩两百多点，四行连各自的最矮都叠不下；横过来的宽正好排四列。
/// 添加任务去待办、顶上浮出添加那一行（`NewTaskLine`，落在范围里的项目或当前项目，可换），失焦且没写字时收回。
struct ProgressScreen: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.boardFits) private var boardFits
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var board: TaskBoard?
    @State private var adding = false
    @State private var quotaOpen = DebugHooks.preset.quotaOpen

    var body: some View {
        boardView
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .floatingHeader("进展", center: { ProgressHeader(open: $quotaOpen) }) { EmptyView() }
            .refreshesQuota()
            .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: adding)
            .onChange(of: workspace.scopedProject) { adding = false }
            .observingBoard(into: $board, store: services.store, onError: workspace.fail)
    }

    private var boardView: some View {
        let scope = workspace.scopedProject
        let shown = (board ?? .empty).only(scope)
        return Group {
            if verticalSizeClass == .compact || (sizeClass == .regular && boardFits) {
                BoardColumns(board: shown, adding: $adding, newTaskProject: newTaskProject, margin: 12)
            } else {
                PhoneBoard(board: shown, adding: $adding, newTaskProject: newTaskProject)
            }
        }
        .environment(\.laneAddsTask, add)
        .environment(\.laneAddsSession, { workspace.openNewSession(in: scope) })
        // 换范围不带里层的挪位与数字动画，理由同 Mac 的 `TaskBoardPage`
        .transaction(value: scope) { $0.disablesAnimations = true }
    }

    private var newTaskProject: UUID? { workspace.scopedProject ?? workspace.currentProject }

    /// 待办顶上浮出添加那一行（手机看板先把待办那一行滑到行首，`BoardRowLane`）。
    private func add() { adding = true }
}

/// 宽屏进展页顶栏中间那一块玻璃：项目范围、额度环；点环从这一块长出额度明细（`GrowPanel`）。两样并成一块：说的都是"这一页看什么"。
/// 窄屏不用它：那一排是侧栏的（`NarrowSidebarBar`），项目范围与额度各是一颗圆钮。
struct ProgressHeader: View {
    @Binding var open: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GrowPanel(open: $open, radius: FloatingHeaderLayout.height / 2) {
            HStack(spacing: 0) {
                ProjectScope()
                QuotaRings(open: open, height: FloatingHeaderLayout.height) { $open.grow(reduceMotion: reduceMotion) }
            }
        } panel: {
            QuotaDetail().padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 18).refreshesQuota()
        }
    }
}

/// 一行新建任务：↩ 添加并保持焦点，便于连续输入。给了 `projects` 时尾部可选挂到哪个项目。
/// 给了 `dismiss`（看板待办头上"+"浮出的那一行）：出现即聚焦，失焦时没写字就收回。
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
            TextField(String(localized: "添加任务"), text: $text, palette: palette)
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
                    ForEach(projects) { item in Button(item.shownName) { chosen = item.id } }
                } label: {
                    DestinationChip(project: current).frame(minHeight: 44).contentShape(.rect).menuLabel("记到 \(current?.shownName ?? "")")
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
