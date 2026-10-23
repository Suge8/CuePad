#if os(macOS)
import SwiftUI

/// 进展页（侧栏"进展"、⌘⇧T）：看板（`TaskBoardPage`）与会话（`SessionsPane`）两段，看哪一段只有 `Workspace.progressPane` 一份。
/// 页里不另起一排，控件都在工具栏那一排：左边项目范围（`ScopeSlot`，两段共用），正中两段的分段（`PageTitleSlot` 里的 `ProgressSegments`），
/// 右边额度环（`QuotaSlot`）与随段换成"新任务"或"新会话"的主操作（`PageActionSlot`）。
/// 被否决的：分段与额度环另起一排浮在内容上——看板的列头整体下移一截，列头的玻璃与那一排的玻璃叠成两层。
/// 新会话的表单挂在这一页（`NewSessionPanel`，⌥⌘N 先来这一段再弹它）。
struct ProgressPage: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Group {
            switch workspace.progressPane {
            case .board: TaskBoardPage()
            case .sessions: SessionsPane()
            }
        }
        .refreshesQuota()
        .modifier(NewSessionPanel())
    }
}

/// 工具栏正中：看板｜会话。选中的那段垫选中底、墨色加粗，底在两段间滑过去。
struct ProgressSegments: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var space

    private static let inset: CGFloat = 3

    var body: some View {
        HStack(spacing: 2) {
            segment(.board, "看板", icon: .task)
            segment(.sessions, "会话", icon: .session)
        }
        .padding(Self.inset)
        .glass(in: .capsule)
    }

    private func segment(_ pane: ProgressPane, _ title: String, icon: Icon) -> some View {
        let on = workspace.progressPane == pane
        return Button {
            withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { workspace.progressPane = pane }
        } label: {
            Label { Text(title) } icon: { Image(icon) }
                .labelStyle(.titleAndIcon)
                .font(Typography.secondary.weight(on ? .semibold : .medium))
                .foregroundStyle(on ? palette.ink : palette.ink2)
                .padding(.horizontal, 16).frame(height: Spacing.toolbarControl - Self.inset * 2)
                .background {
                    if on { Capsule().fill(palette.selection).matchedGeometryEffect(id: "on", in: space) }
                }
                .contentShape(.capsule)
        }
        .buttonStyle(PressStyle())
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
#endif
