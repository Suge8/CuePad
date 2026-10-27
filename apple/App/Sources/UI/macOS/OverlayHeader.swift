#if os(macOS)
import SwiftUI

/// 盖在页上的编辑页（灵感的编辑页、技能与规则的文件页，`Workspace.overlay`）是哪一份：标题与下面一行次要信息，在工具栏中间的标题位（`PageTitleSlot`），
/// 同手机推入页页顶中间那块玻璃；页里不另写这一行。工具栏项在主窗口里常驻，编辑页只把算好的值交到这里（同 `SessionHeader`），收起时清掉自己的。
@Observable
final class OverlayHeader {
    struct Content: Equatable {
        var page: Workspace.Overlay
        var title: String
        var detail: Dotted
        /// 次要那一行说的是没存上：着出错的色
        var failed = false
        /// 悬停在标题上看的（文件的完整路径）
        var help: String?
        /// 次要一行最宽的样子（换上最长的那个状态词）：玻璃按它留宽，状态换字时不伸缩
        var widest: Dotted
    }

    private(set) var content: Content?

    func set(_ content: Content) {
        if self.content != content { self.content = content }
    }

    /// 收起的页只清自己的：换一份打开时新页的值可能已经先到了。
    func clear(_ page: Workspace.Overlay) {
        if content?.page == page { content = nil }
    }
}

extension View {
    /// 编辑页把自己的标题与次要一行交给工具栏（`OverlayHeader`），值变了就再交，离开时清掉。
    func overlayHeader(_ content: OverlayHeader.Content, in workspace: Workspace) -> some View {
        onChange(of: content, initial: true) { _, content in workspace.overlayHeader.set(content) }
            .onDisappear { workspace.overlayHeader.clear(content.page) }
    }
}

/// 工具栏标题位里的那一块：两行，标题与次要一行（同手机的 `TitleStack`）。开着编辑页就占着这一位（值交到之前空着，不先露出下面那一页的）。
/// 玻璃按字收窄、居中（两行短字铺满标题位会两边空出一大截），放不下时字截断、玻璃不超过标题位；标题位自己的宽只随窗口变，工具栏不因它重排。
/// 宽按次要一行最宽的样子留（`Content.widest`）：存着、存好、没存上换字时玻璃不跟着伸缩。
struct OverlayTitle: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let content = workspace.overlayHeader.content.flatMap { $0.page == workspace.overlay ? $0 : nil }
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 1) {
                Text(verbatim: content?.title ?? "").font(Typography.toolbarTitlePaired).foregroundStyle(palette.ink)
                    .accessibilityAddTraits(.isHeader)
                ZStack {
                    // 只占宽：最宽的那一版次要一行
                    Text(content?.widest ?? Dotted()).hidden().accessibilityHidden(true)
                    Text(content?.detail ?? Dotted()).foregroundStyle(content?.failed == true ? palette.failure : palette.ink3)
                }
                .font(Typography.toolbarPath)
            }
            .lineLimit(1)
            .padding(.horizontal, 16)
            .frame(height: Spacing.toolbarControl)
            .glass(in: .capsule)
            .help(content?.help ?? "")
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
        }
        .modifier(PageTitleWidth())
    }
}
#endif
