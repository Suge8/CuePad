#if os(macOS)
import AppKit
import CueEditor
import CueStore
import SwiftUI

nonisolated private struct EditorData: Sendable, Equatable {
    var card: Card
    var project: Project?
}

/// 打开的散放灵感（任务与它的正文在任务浮窗里看、改，见 `TaskSheet`）：编辑页铺满内容区、与页面同底色（纸感留在墙上的卡片与底色上，
/// 这里不再画纸）；字限在 `textWidth` 一列里居中，编辑区本身铺满，两侧空白处也能滚。打开、收起都是原地淡入淡出，不动几何：
/// 前台每帧几何变化会让 AppKit 重算整窗的鼠标跟踪区。
/// 重活先在看不见时做完——挂上编辑器与底栏、让编辑器接过键盘，各占一帧——再淡入；这几帧里墙上那张卡保持按下（`CardPresence.opening`）。
/// 编辑页底下的项目页保持挂载，关掉后回到原来的滚动位置。
struct CardEditorPage: View {
    let cardID: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var data: EditorData?
    @State private var editing: CardEditing?
    /// 编辑器与底栏已挂上（不可见，见 `prepare`）。
    @State private var mounted = false
    /// 编辑页看得见（淡入、淡出的终点）。
    @State private var shown = false
    /// 淡入走完了。
    @State private var settled = false
    /// 收起的淡出走完了（之后才卸下）。
    @State private var gone = false

    /// 一行字最宽：苹方 15.5pt 约 44 个字，再宽读到行尾回头找下一行就费劲。
    fileprivate static let textWidth: CGFloat = 680
    /// 字离编辑区左右边的最小距离（窗口窄时）。
    fileprivate static let inset: CGFloat = 24
    private static let barClearance: CGFloat = 84
    /// 编辑区下沿淡出的那一段（内容自己的透明度，不往上画颜色）。
    private static let bottomFade: CGFloat = 28

    private var isOpen: Bool { workspace.openCard == cardID }

    var body: some View {
        ZStack(alignment: .top) {
            if mounted, let data, let editing {
                VStack(spacing: 10) {
                    meta(data, editing)
                    editor(data.card, editing)
                }
                .padding(.top, Spacing.pageTop)
                .padding(.bottom, Self.barClearance)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.desk.ignoresSafeArea())
        .overlay(alignment: .bottom) {
            // 底栏挂在页面之上、与编辑器同时挂好，随编辑页一起淡入淡出
            if mounted, let data, let editing {
                EditorBar(card: data.card, editing: editing)
                    .column()
                    .padding(.bottom, 16)
                    .disabled(!shown)
                    .accessibilityHidden(!shown)
            }
        }
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .debugSettling(isOpen ? !settled : !gone)
        // 卡没了（并进了草稿、接进了会话的回复框）就收起，不当成出错
        .observing(services.store, id: cardID, into: $data, onError: { [workspace] error in
            if case CueStoreError.notFound = error { workspace.openCard = nil } else { workspace.fail(error) }
        }) { [cardID] store in
            guard let card = try store.card(cardID) else { throw CueStoreError.notFound }
            return EditorData(card: card, project: try store.project(card.projectID))
        }
        .onChange(of: data?.card.id, initial: true) {
            guard editing == nil, let card = data?.card else { return }
            editing = CardEditing(card, workspace: workspace)
            if isOpen, !mounted { prepare() }
        }
        .onChange(of: data?.card.deletedAt) { if data?.card.deletedAt != nil { workspace.openCard = nil } }
        // 编辑页只给散放的灵感：在"⋯"里设为任务、挂到了任务下，这页收起，接着在任务浮窗里看
        .onChange(of: data.map { $0.card.isTask || $0.card.parentID != nil }) { _, moved in
            guard moved == true, let card = data?.card else { return }
            workspace.openCard = nil
            workspace.open(card)
        }
        .onChange(of: isOpen) { if !isOpen { collapse() } }
        .onDisappear { editing?.leave() }
    }

    /// 看不见时先把重活做完，每步一帧：挂上编辑器与底栏（一帧：分成两帧只是多一次掉帧）、让编辑器接过键盘
    /// （要激活输入法上下文，与输入法进程同步往返），最后放开墙上那张卡、淡入。淡入的每一帧只剩改透明度。
    private func prepare() {
        Task {
            // 每一步之前都看一眼：准备途中已经关了就停下（关闭由 collapse 收尾）
            await NextFrame.wait()
            guard isOpen else { return }
            mounted = true
            await NextFrame.wait()
            guard isOpen else { return }
            editing?.handle.focus()
            await NextFrame.wait()
            guard isOpen else { return }
            workspace.presses.opened(cardID)
            withAnimation(Motion.quick) { shown = true } completion: { settled = true }
        }
    }

    /// 原地淡出，淡完卸下。
    private func collapse() {
        withAnimation(Motion.quick) {
            shown = false
        } completion: {
            gone = true
            workspace.finishClosingCard()
        }
    }

    private func meta(_ data: EditorData, _ editing: CardEditing) -> some View {
        HStack(spacing: 8) {
            ProjectGlyph(project: data.project, size: 12)
            Text(data.project?.name ?? "").foregroundStyle(palette.ink)
            Dot()
            Text(DateLabel.short(data.card.modifiedAt))
            SaveStatus(editing: editing)
            if data.card.isPinned { Label("资料", icon: .resource) }
            Spacer(minLength: 0)
            Menu("更多", icon: .more) {
                CardActions(card: data.card, more: true)
            }
            .labelStyle(.iconOnly).menuStyle(.button).menuIndicator(.hidden).buttonStyle(.borderless).fixedSize()
        }
        .font(Typography.meta)
        .foregroundStyle(palette.ink3)
        .column()
    }

    private func editor(_ card: Card, _ editing: CardEditing) -> some View {
        editing.field(card, theme: .editor(palette, horizontalInset: Self.inset, maxTextWidth: Self.textWidth))
            .mask {
                VStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: Self.bottomFade)
                }
            }
    }
}

private extension View {
    /// 编辑页里与正文同一列：最宽 `textWidth`、居中，窗口窄时离边至少 `inset`（编辑器自己按同样的数居中，见 `CueEditorTheme.maxTextWidth`）。
    func column() -> some View {
        frame(maxWidth: CardEditorPage.textWidth, alignment: .leading)
            .padding(.horizontal, CardEditorPage.inset)
            .frame(maxWidth: .infinity)
    }
}
#endif
